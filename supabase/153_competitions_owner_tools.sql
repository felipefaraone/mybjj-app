-- ============================================================================
-- 153 — Competitions, PHASES C + E: owner tools for challenges
-- ============================================================================
--
-- 1. competition_save(p jsonb) -> uuid: create or edit an EVENT challenge in one
--    transaction (owners only, is_admin()). New rows are 'draft'. Fields:
--    id (null = new), name, starts_on, ends_on, finale_on (optional), places
--    (1-10, stored in prizes as 150 does: [{"place":1,"label":"1st"}, ...]),
--    rules [{rule_key, points, enabled}] (upsert; every catalog key present),
--    divisions [{unit_id, audience}] (the set is replaced; labels as 150:
--    '<Unit> Kids' / '<Unit> Adults'). A division that already has finalized
--    results cannot be removed (they would cascade away).
-- 2. competition_set_status(p_id, p_status) -> void: owners only, events only.
--    'active' is refused when another ACTIVE event overlaps the dates (through
--    the finale) and shares a unit; the message names the unit. 'draft' only
--    while starts_on is after today (Sydney). No other status.
-- 3. competition_award_add_many(p_students uuid[], p_key text, p_date date)
--    -> table(student_id uuid, result text): the bulk form of
--    competition_award_add for date awards (social posts). Same authorization
--    (_competition_award_allowed) and checks; one row per student: 'added',
--    'already' (a live award for that student, key and date exists: never a
--    duplicate, never an error) or 'not_allowed' (no such student).
-- 4. competition_rule_catalog: label / description become the members' "How to
--    score" copy, so the app and the TV read one source.
--
-- Requires 148-152. No table or column changes.
-- Rollback: 153_competitions_owner_tools_rollback.sql. Checks: _verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. competition_save
-- ---------------------------------------------------------------------------
create or replace function public.competition_save(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  v_name   text := btrim(coalesce(p->>'name', ''));
  v_start  date := nullif(btrim(coalesce(p->>'starts_on', '')), '')::date;
  v_end    date := nullif(btrim(coalesce(p->>'ends_on', '')), '')::date;
  v_finale date := nullif(btrim(coalesce(p->>'finale_on', '')), '')::date;
  v_places integer := coalesce(nullif(btrim(coalesce(p->>'places', '')), '')::integer, 3);
  v_rules  jsonb := coalesce(p->'rules', '[]'::jsonb);
  v_divs   jsonb := coalesce(p->'divisions', '[]'::jsonb);
  v_prizes jsonb;
  v_missing text;
  v_n integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v_name = '' then
    raise exception 'Add a name' using errcode = 'invalid_parameter_value';
  end if;
  if v_start is null or v_end is null then
    raise exception 'Add the start and end dates' using errcode = 'invalid_parameter_value';
  end if;
  if v_end < v_start then
    raise exception 'The end can''t be before the start' using errcode = 'invalid_parameter_value';
  end if;
  if v_finale is not null and v_finale < v_end then
    raise exception 'Prizes can''t be before the end' using errcode = 'invalid_parameter_value';
  end if;
  if v_places < 1 or v_places > 10 then
    raise exception 'Top places must be 1 to 10' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(v_rules) <> 'array' or jsonb_typeof(v_divs) <> 'array' then
    raise exception 'rules and divisions must be arrays' using errcode = 'invalid_parameter_value';
  end if;

  -- divisions: at least one, every unit real, audience adult / kids
  if jsonb_array_length(v_divs) = 0 then
    raise exception 'Pick at least one group' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_array_elements(v_divs) d
              where coalesce(d->>'audience', '') not in ('adult', 'kids')
                 or not exists (select 1 from public.units u where u.id::text = d->>'unit_id')) then
    raise exception 'Unknown group' using errcode = 'invalid_parameter_value';
  end if;

  -- rules: every catalog key present, known keys only, enabled points > 0
  select string_agg(c.key, ', ' order by c.sort) into v_missing
    from public.competition_rule_catalog c
   where not exists (select 1 from jsonb_array_elements(v_rules) r where r->>'rule_key' = c.key);
  if v_missing is not null then
    raise exception 'Missing rules: %', v_missing using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_array_elements(v_rules) r
              where not exists (select 1 from public.competition_rule_catalog c where c.key = r->>'rule_key')) then
    raise exception 'Unknown rule' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_array_elements(v_rules) r
              where coalesce((r->>'enabled')::boolean, false)
                and coalesce(nullif(r->>'points', '')::numeric, 0) <= 0) then
    raise exception 'Points must be more than 0' using errcode = 'invalid_parameter_value';
  end if;

  -- prizes in 150's format
  select jsonb_agg(jsonb_build_object('place', g, 'label',
           g::text || case when g % 100 in (11, 12, 13) then 'th'
                           when g % 10 = 1 then 'st' when g % 10 = 2 then 'nd' when g % 10 = 3 then 'rd'
                           else 'th' end) order by g)
    into v_prizes
    from generate_series(1, v_places) g;

  if v_id is null then
    insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values (v_name, 'event', v_start, v_end, v_finale, 'draft', v_prizes)
    returning id into v_id;
  else
    update public.competitions
       set name = v_name, starts_on = v_start, ends_on = v_end, finale_on = v_finale, prizes = v_prizes
     where id = v_id and kind = 'event';
    if not found then
      raise exception 'challenge % not found', v_id using errcode = 'no_data_found';
    end if;
  end if;

  -- rules: upsert points / enabled (params untouched; the catalog supplies defaults)
  insert into public.competition_rules (competition_id, rule_key, points, enabled)
  select v_id, r->>'rule_key', coalesce(nullif(r->>'points', '')::numeric, 0), coalesce((r->>'enabled')::boolean, false)
    from jsonb_array_elements(v_rules) r
  on conflict (competition_id, rule_key) do update
     set points = excluded.points, enabled = excluded.enabled;

  -- divisions: replace the set. A division with finalized results is never removed.
  if exists (select 1 from public.competition_divisions d
              join public.competition_results cr on cr.division_id = d.id
             where d.competition_id = v_id
               and not exists (select 1 from jsonb_array_elements(v_divs) x
                                where x->>'unit_id' = d.unit_id::text and x->>'audience' = d.audience)) then
    raise exception 'A group with final results can''t be removed' using errcode = 'invalid_parameter_value';
  end if;
  delete from public.competition_divisions d
   where d.competition_id = v_id
     and not exists (select 1 from jsonb_array_elements(v_divs) x
                      where x->>'unit_id' = d.unit_id::text and x->>'audience' = d.audience);
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
  select v_id, u.id, x.audience,
         u.name || case when x.audience = 'kids' then ' Kids' else ' Adults' end,
         (row_number() over (order by u.name, (x.audience = 'adult')))::integer
    from (select distinct (e->>'unit_id')::uuid as unit_id, e->>'audience' as audience
            from jsonb_array_elements(v_divs) e) x
    join public.units u on u.id = x.unit_id
  on conflict (competition_id, unit_id, audience) do nothing;
  -- keep the 150 sort order (unit name, kids before adults) for the whole set
  update public.competition_divisions d
     set sort = s.rn
    from (select d2.id, (row_number() over (order by u.name, (d2.audience = 'adult')))::integer as rn
            from public.competition_divisions d2 join public.units u on u.id = d2.unit_id
           where d2.competition_id = v_id) s
   where d.id = s.id and d.sort is distinct from s.rn;

  select count(*) into v_n from public.competition_divisions where competition_id = v_id;
  if v_n = 0 then
    raise exception 'Pick at least one group' using errcode = 'invalid_parameter_value';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. competition_set_status
-- ---------------------------------------------------------------------------
create or replace function public.competition_set_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.competitions;
  v_today date := (now() at time zone 'Australia/Sydney')::date;
  v_clash record;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into c from public.competitions where id = p_id for update;
  if not found or c.kind <> 'event' then
    raise exception 'challenge % not found', p_id using errcode = 'no_data_found';
  end if;
  if p_status = 'active' then
    select o.name as comp_name, u.name as unit_name into v_clash
      from public.competitions o
      join public.competition_divisions od on od.competition_id = o.id
      join public.competition_divisions md on md.competition_id = c.id and md.unit_id = od.unit_id
      join public.units u on u.id = od.unit_id
     where o.id <> c.id and o.status = 'active' and o.kind = 'event'
       and o.starts_on <= coalesce(c.finale_on, c.ends_on)
       and c.starts_on <= coalesce(o.finale_on, o.ends_on)
     order by o.starts_on, u.name
     limit 1;
    if found then
      raise exception '% already runs at % on those dates', v_clash.comp_name, v_clash.unit_name
        using errcode = 'invalid_parameter_value';
    end if;
    update public.competitions set status = 'active' where id = c.id;
  elsif p_status = 'draft' then
    if c.starts_on <= v_today then
      raise exception 'It has already started: it can''t go back to draft' using errcode = 'invalid_parameter_value';
    end if;
    update public.competitions set status = 'draft' where id = c.id;
  else
    raise exception 'status must be active or draft' using errcode = 'invalid_parameter_value';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. competition_award_add_many
-- ---------------------------------------------------------------------------
create or replace function public.competition_award_add_many(p_students uuid[], p_key text, p_date date)
returns table (student_id uuid, result text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text;
  v_sid uuid;
  v_unit uuid;
begin
  -- the same checks as competition_award_add
  select c.source into v_source from public.competition_rule_catalog c where c.key = p_key;
  if v_source is null then
    raise exception 'unknown award %', p_key using errcode = 'invalid_parameter_value';
  end if;
  if v_source <> 'award' then
    raise exception '% is not an award', p_key using errcode = 'invalid_parameter_value';
  end if;
  if not public._competition_award_allowed(p_key) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null then
    raise exception 'award date required' using errcode = 'invalid_parameter_value';
  end if;
  if p_key in ('class_challenge', 'best_attitude') then
    -- class awards need the class (competition_award_add)
    raise exception '% needs the class date' , p_key using errcode = 'invalid_parameter_value';
  end if;

  foreach v_sid in array (select array(select distinct x from unnest(coalesce(p_students, array[]::uuid[])) x where x is not null)) loop
    student_id := v_sid;
    select s.unit_id into v_unit from public.students s where s.id = v_sid;
    if not found then
      result := 'not_allowed';
      return next;
      continue;
    end if;
    if exists (select 1 from public.competition_awards w
                where w.student_id = v_sid and w.award_key = p_key and w.award_date = p_date and w.voided_at is null) then
      result := 'already';
      return next;
      continue;
    end if;
    begin
      insert into public.competition_awards (student_id, award_key, award_date, unit_id, awarded_by)
      values (v_sid, p_key, p_date, v_unit, auth.uid());
      result := 'added';
    exception when unique_violation then
      result := 'already';
    end;
    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. "How to score" copy in the catalog (one source for the app and the TV)
-- ---------------------------------------------------------------------------
update public.competition_rule_catalog set label = 'Train a class',
       description = 'Part classes count as marked (½ or ¼). A private counts as 1.' where key = 'class_attended';
update public.competition_rule_catalog set label = 'Win the class challenge',          description = null where key = 'class_challenge';
update public.competition_rule_catalog set label = 'Best attitude in class',           description = 'Picked by the coach' where key = 'best_attitude';
update public.competition_rule_catalog set label = 'Post, story or reel about myBJJ',  description = 'Once a day counts' where key = 'social_post';
update public.competition_rule_catalog set label = 'Bring a friend to a trial',        description = null where key = 'referral_trial';
update public.competition_rule_catalog set label = 'Your friend signs up',             description = 'On top of the trial points' where key = 'referral_conversion';

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
revoke all on function public.competition_save(jsonb)                              from public, anon;
revoke all on function public.competition_set_status(uuid, text)                   from public, anon;
revoke all on function public.competition_award_add_many(uuid[], text, date)       from public, anon;
grant execute on function public.competition_save(jsonb)                           to authenticated;
grant execute on function public.competition_set_status(uuid, text)                to authenticated;
grant execute on function public.competition_award_add_many(uuid[], text, date)    to authenticated;

commit;
