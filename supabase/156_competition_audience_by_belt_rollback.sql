-- 156_competition_audience_by_belt_rollback.sql
--
-- Undo 156, back to 155's state exactly: the 1-argument _competition_audience
-- (149's text), _competition_scores (155's text), _competition_ranked (149's),
-- competition_standings (151's), 154's rule helper and award trigger (154's
-- text) and _tv_payload (155's), each with the grants it had; then the two 156
-- helpers are dropped once nothing calls them.

begin;

-- ACL helpers (session only): a dropped and recreated function gets exactly the
-- grants its predecessor had, entry for entry (owner entries untouched).
create function pg_temp.acl_set(p_acl aclitem[], p_owner oid) returns text language sql stable as $f$
  select coalesce(string_agg(case when a.grantee = 0 then 'PUBLIC' else r.rolname::text end || ':' || a.privilege_type, ','
                             order by 1), '')
    from aclexplode(coalesce(p_acl, acldefault('f', p_owner))) a
    left join pg_roles r on r.oid = a.grantee
   where a.grantee <> p_owner
$f$;
create function pg_temp.acl_copy(p_acl aclitem[], p_sig text) returns void language plpgsql as $f$
declare
  v_oid oid := p_sig::regprocedure;
  v_owner oid := (select p.proowner from pg_proc p where p.oid = v_oid);
  x record;
begin
  execute format('revoke all on function %s from public', p_sig);
  for x in select distinct r.rolname from pg_proc p, aclexplode(p.proacl) a join pg_roles r on r.oid = a.grantee
            where p.oid = v_oid and a.grantee <> v_owner loop
    execute format('revoke all on function %s from %I', p_sig, x.rolname);
  end loop;
  for x in select a.grantee, a.privilege_type from aclexplode(coalesce(p_acl, acldefault('f', v_owner))) a
            where a.grantee <> v_owner loop
    execute format('grant %s on function %s to %s', x.privilege_type, p_sig,
                   case when x.grantee = 0 then 'public' else quote_ident((select rolname from pg_roles where oid = x.grantee)) end);
  end loop;
  if pg_temp.acl_set((select proacl from pg_proc where oid = v_oid), v_owner) <> pg_temp.acl_set(p_acl, v_owner) then
    raise exception 'ACL copy failed for %', p_sig;
  end if;
end $f$;

create temp table acl156 on commit drop as
  select 'scores'::text as k, (select proacl from pg_proc where oid = to_regprocedure('public._competition_scores(uuid, date, date)')) as acl
  union all select 'ranked', (select proacl from pg_proc where oid = to_regprocedure('public._competition_ranked(uuid, date, date)'))
  union all select 'standings', (select proacl from pg_proc where oid = to_regprocedure('public.competition_standings(uuid, date, date)'))
  union all select 'audience', coalesce((select proacl from pg_proc where oid = to_regprocedure('public._competition_audience(text, text)')),
                                        (select proacl from pg_proc where oid = to_regprocedure('public._competition_audience(text)')));

-- 149's text, verbatim
create or replace function public._competition_audience(p_prog text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when p_prog = 'kids' then 'kids' else 'adult' end
$$;

drop function if exists public.competition_standings(uuid, date, date);
drop function if exists public._competition_ranked(uuid, date, date);
drop function if exists public._competition_scores(uuid, date, date);

-- 155's text, verbatim
create or replace function public._competition_scores(p_competition uuid, p_from date, p_to date)
returns table (
  division_id        uuid,
  unit_id            uuid,
  audience           text,
  student_id         uuid,
  display_name       text,
  photo_url          text,
  points             numeric,
  class_points       numeric,
  gi_points          numeric,
  nogi_points        numeric,
  award_points       numeric,
  referral_points    numeric,
  classes_count      integer,
  last_scored_on     date,
  prize_eligible     boolean,
  leaderboard_hidden boolean,
  belt               text,
  degree             integer
)
language sql
stable
security definer
set search_path = public
as $$
  with per as (
    select p.period_from as f, p.period_to as t
      from public._competition_period(p_competition, p_from, p_to) p
  ),
  rules as (
    -- enabled rules of THIS competition; params = catalog defaults overlaid
    select r.rule_key, r.points, c.source,
           coalesce(c.default_params, '{}'::jsonb) || coalesce(r.params, '{}'::jsonb) as params
      from public.competition_rules r
      join public.competition_rule_catalog c on c.key = r.rule_key
     where r.competition_id = p_competition
       and r.enabled is true
  ),
  ca as (
    select r.points,
           coalesce(r.params ->> 'mode', 'class_value') as mode,
           coalesce((r.params ->> 'private_cap')::numeric, 1) as private_cap
      from rules r where r.rule_key = 'class_attended'
  ),
  pop as (
    -- division = home unit + audience; ONE eligibility rule
    select d.id as division_id, d.unit_id, d.audience, s.id as student_id,
           s.first_name::text as first_name, s.last_name::text as last_name, s.full_name::text as full_name,
           s.photo_url::text as photo_url, s.prize_eligible, s.leaderboard_hidden,
           s.belt::text as belt, s.degree::integer as degree
      from public.competition_divisions d
      join public.students s
        on s.unit_id = d.unit_id
       and public._competition_audience(s.prog::text) = d.audience
     where d.competition_id = p_competition
       and public._competition_eligible(s.active, s.standing::text, s.membership_level::text)
  ),
  att as (
    -- class_attended: present rows in the period. class_value mode: the row's
    -- class_value, a private lesson capped at private_cap; flat mode: 1 per row.
    -- Two classes on the same day both count.
    select a.student_id, a.class_date, a.modality::text as modality,
           (case when ca.mode = 'flat' then 1::numeric
                 when a.class_type = 'private' then least(a.class_value, ca.private_cap)
                 else a.class_value end) * ca.points as pts
      from public.attendance a
     cross join ca
     cross join per
     where a.status = 'present'
       and a.class_date between per.f and per.t
       and a.student_id in (select pop.student_id from pop)
  ),
  att_sum as (
    select x.student_id,
           sum(x.pts) as class_points,
           coalesce(sum(x.pts) filter (where x.modality = 'gi'), 0)   as gi_points,
           coalesce(sum(x.pts) filter (where x.modality = 'nogi'), 0) as nogi_points,
           max(x.class_date) filter (where x.pts > 0) as last_d
      from att x group by x.student_id
  ),
  aw as (
    -- award rules: non-voided awards in the period whose rule is enabled here
    select w.student_id, w.award_date as d, r.points as pts
      from public.competition_awards w
      join rules r on r.rule_key = w.award_key and r.source = 'award'
     cross join per
     where w.voided_at is null
       and w.award_date between per.f and per.t
       and w.student_id in (select pop.student_id from pop)
       -- 152 condition, 155: one source for "does this award count"
       and public._competition_award_counts(w.student_id, w.class_id, w.class_date)
  ),
  aw_sum as (
    select x.student_id, sum(x.pts) as award_points, max(x.d) filter (where x.pts > 0) as last_d
      from aw x group by x.student_id
  ),
  rf as (
    -- referral rules: the referee's first attended trial day / conversion day.
    -- A booking converted into the referrer themself never counts.
    select tb.referred_by_student_id as student_id, x.d, r.points as pts
      from public.trial_bookings tb
     cross join per
     cross join lateral (values
       ('referral_trial',      public.trial_first_attended_on(tb.id)),
       ('referral_conversion', (tb.converted_at at time zone 'Australia/Sydney')::date)
     ) as x(rule_key, d)
      join rules r on r.rule_key = x.rule_key and r.source = 'referral'
     where tb.referred_by_student_id is not null
       and tb.converted_student_id is distinct from tb.referred_by_student_id
       and x.d between per.f and per.t
       and tb.referred_by_student_id in (select pop.student_id from pop)
  ),
  rf_sum as (
    select x.student_id, sum(x.pts) as referral_points, max(x.d) filter (where x.pts > 0) as last_d
      from rf x group by x.student_id
  ),
  names as (
    select p.student_id,
           coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), '')) as fn,
           coalesce(nullif(btrim(p.last_name), ''),
                    case when position(' ' in btrim(coalesce(p.full_name, ''))) > 0
                         then regexp_replace(btrim(p.full_name), '^.*\s', '') end) as ln
      from pop p
  )
  select p.division_id,
         p.unit_id,
         p.audience,
         p.student_id,
         (case when p.audience = 'kids'
               then coalesce(n.fn, '') || coalesce(' ' || upper(left(n.ln, 1)) || '.', '')
               else coalesce(nullif(btrim(p.first_name), '') || ' ' || nullif(btrim(p.last_name), ''),
                             btrim(p.full_name))
          end)::text,
         (case when p.audience = 'kids' then null else p.photo_url end)::text,
         (coalesce(a.class_points, 0) + coalesce(w.award_points, 0) + coalesce(r.referral_points, 0))::numeric,
         coalesce(a.class_points, 0)::numeric,
         coalesce(a.gi_points, 0)::numeric,
         coalesce(a.nogi_points, 0)::numeric,
         coalesce(w.award_points, 0)::numeric,
         coalesce(r.referral_points, 0)::numeric,
         public.training_count(p.student_id, per.f, per.t)::integer,
         greatest(a.last_d, w.last_d, r.last_d)::date,
         p.prize_eligible,
         p.leaderboard_hidden,
         p.belt,
         p.degree
    from pop p
   cross join per
    join names n on n.student_id = p.student_id
    left join att_sum a on a.student_id = p.student_id
    left join aw_sum  w on w.student_id = p.student_id
    left join rf_sum  r on r.student_id = p.student_id
$$;

-- 149's text, verbatim
create or replace function public._competition_ranked(p_competition uuid, p_from date, p_to date)
returns table (
  division_id        uuid,
  unit_id            uuid,
  audience           text,
  student_id         uuid,
  display_name       text,
  photo_url          text,
  points             numeric,
  class_points       numeric,
  gi_points          numeric,
  nogi_points        numeric,
  award_points       numeric,
  referral_points    numeric,
  classes_count      integer,
  last_scored_on     date,
  prize_eligible     boolean,
  leaderboard_hidden boolean,
  rank               integer,
  prize_rank         integer,
  belt               text,
  degree             integer
)
language sql
stable
security definer
set search_path = public
as $$
  select s.division_id, s.unit_id, s.audience, s.student_id, s.display_name, s.photo_url,
         s.points, s.class_points, s.gi_points, s.nogi_points, s.award_points, s.referral_points,
         s.classes_count, s.last_scored_on, s.prize_eligible, s.leaderboard_hidden,
         (rank() over (partition by s.division_id
                       order by s.points desc, s.classes_count desc, s.last_scored_on asc nulls last))::integer,
         (case when s.prize_eligible is true then
            rank() over (partition by s.division_id, (s.prize_eligible is true)
                         order by s.points desc, s.classes_count desc, s.last_scored_on asc nulls last)
          end)::integer,
         s.belt, s.degree
    from public._competition_scores(p_competition, p_from, p_to) s
$$;

-- 151's text, verbatim
create or replace function public.competition_standings(p_competition uuid, p_from date default null, p_to date default null)
returns table (
  division_id        uuid,
  unit_id            uuid,
  audience           text,
  student_id         uuid,
  display_name       text,
  photo_url          text,
  points             numeric,
  class_points       numeric,
  gi_points          numeric,
  nogi_points        numeric,
  award_points       numeric,
  referral_points    numeric,
  classes_count      integer,
  last_scored_on     date,
  prize_eligible     boolean,
  leaderboard_hidden boolean,
  rank               integer,
  prize_rank         integer,
  belt               text,
  degree             integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff boolean := coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false);
  v_mine  uuid[];   -- the caller's own students rows and their guardian kids
begin
  if coalesce(public.current_status(), '') <> 'approved' then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  -- 151: a draft competition is the admin's alone (no rows for anyone else)
  if not coalesce(public.is_admin(), false)
     and exists (select 1 from public.competitions c where c.id = p_competition and c.status = 'draft') then
    return;
  end if;
  v_mine := array(select s.id from public.students s where s.user_id = auth.uid())
            || coalesce(public.guardian_student_ids(), array[]::uuid[]);
  return query
    select r.*
      from public._competition_ranked(p_competition, p_from, p_to) r
     where (r.audience = 'adult'
            or v_staff
            or exists (select 1 from public.students k
                        where k.id = any (v_mine)
                          and k.unit_id = r.unit_id
                          and public._competition_audience(k.prog::text) = 'kids'))
       and (r.leaderboard_hidden is not true
            or v_staff
            or r.student_id = any (v_mine))
     order by r.audience, r.unit_id, r.rank, r.display_name, r.student_id;
end;
$$;

-- 154's text, verbatim
create or replace function public._competition_notify_rule(p_student uuid, p_date date, p_key text)
returns table (competition_id uuid, competition_name text, points numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.students;
  v_aud text;
  v_comp uuid;
begin
  if p_student is null or p_date is null then return; end if;
  select * into s from public.students where id = p_student;
  if not found or s.unit_id is null
     or not public._competition_eligible(s.active, s.standing::text, s.membership_level::text) then
    return;
  end if;
  v_aud := public._competition_audience(s.prog::text);
  -- an active challenge scoring on that date, with this student's division
  select c.id into v_comp
    from public.competitions c
   where c.status = 'active' and c.kind = 'event'
     and p_date between c.starts_on and c.ends_on
     and exists (select 1 from public.competition_divisions d
                  where d.competition_id = c.id and d.unit_id = s.unit_id and d.audience = v_aud)
   order by c.starts_on desc, c.created_at desc
   limit 1;
  if v_comp is null then
    -- else the active monthly board (the one competition_for_date shows)
    select c.id into v_comp
      from public.competitions c
     where c.status = 'active' and c.kind = 'monthly'
       and exists (select 1 from public.competition_divisions d
                    where d.competition_id = c.id and d.unit_id = s.unit_id and d.audience = v_aud)
     order by c.created_at desc
     limit 1;
  end if;
  if v_comp is null then return; end if;
  return query
    select c.id, c.name::text, r.points
      from public.competitions c
      join public.competition_rules r on r.competition_id = c.id
     where c.id = v_comp and r.rule_key = p_key and r.enabled is true and r.points > 0;
end;
$$;

create or replace function public.competition_awards_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule record;
  v_first text;
  v_pts text;
  v_day text;
  v_title text;
  v_body text;
  r record;
begin
  -- All notification work (create and dismiss) sits in this block: a failure
  -- here is a WARNING and rolls back only the notification work, never the
  -- staff write that fired the trigger. Every path returns NEW.
  begin
    -- void: remove this award's notifications (existing removal pattern)
    if TG_OP = 'UPDATE' then
      if OLD.voided_at is null and NEW.voided_at is not null then
        update public.notifications n
           set dismissed_at = coalesce(n.dismissed_at, now())
         where n.related_entity_type = 'competition_award'
           and n.related_entity_id = NEW.id
           and n.dismissed_at is null;
      end if;
      return NEW;
    end if;

    if NEW.voided_at is not null
       or NEW.award_key not in ('class_challenge', 'best_attitude', 'social_post') then
      return NEW;
    end if;
    -- a class award counts only with a present attendance (152)
    if NEW.class_date is not null and not exists (
         select 1 from public.attendance a
          where a.student_id = NEW.student_id and a.status = 'present' and a.class_date = NEW.class_date
            and ((NEW.class_id is not null and a.class_id = NEW.class_id)
                 or (NEW.class_id is null and a.class_id is null))) then
      return NEW;
    end if;
    select * into v_rule from public._competition_notify_rule(NEW.student_id, NEW.award_date, NEW.award_key) limit 1;
    if v_rule.competition_id is null then
      return NEW;
    end if;

    v_first := public._competition_first_name(NEW.student_id);
    v_pts   := public._competition_pts(v_rule.points);
    v_day   := to_char(NEW.award_date, 'Dy FMDD Mon');

    for r in select * from public._competition_notify_recipients(NEW.student_id) loop
      if NEW.award_key = 'class_challenge' then
        v_title := case when r.is_guardian then v_first || ' won the class challenge · +' || v_pts
                        else 'Challenge win · +' || v_pts end;
        v_body  := v_rule.competition_name || ' · ' || v_day;
      elsif NEW.award_key = 'best_attitude' then
        v_title := case when r.is_guardian then v_first || ' got best attitude · +' || v_pts
                        else 'Best attitude · +' || v_pts end;
        v_body  := v_rule.competition_name || ' · ' || v_day;
      else
        v_title := case when r.is_guardian then v_first || '''s social post logged · +' || v_pts
                        else 'Social post logged · +' || v_pts end;
        v_body  := 'Thanks for sharing myBJJ. ' || v_rule.competition_name;
      end if;
      perform public.create_notification(
        p_user_id             := r.user_id,
        p_type                := 'competition_points',
        p_title               := v_title,
        p_body                := v_body,
        p_related_entity_type := 'competition_award',
        p_related_entity_id   := NEW.id,
        p_metadata            := jsonb_build_object('student_id', NEW.student_id, 'award_key', NEW.award_key,
                                                    'competition_id', v_rule.competition_id),
        p_check_prefs         := true
      );
    end loop;
  exception when others then
    raise warning '154 notify skipped: % (%)', sqlerrm, sqlstate;
  end;
  return NEW;
end;
$$;

-- 155's text, verbatim
create or replace function public._tv_payload(p_screen uuid, p_today date, p_now time)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c          public.competitions;
  v_unit     uuid;
  v_unit_nm  text;
  v_phase    text;
  v_from     date;
  v_to       date;
  v_places   integer := 0;
  v_week     jsonb;
  v_all      jsonb;     -- this unit's ranked rows, hidden members removed (sid internal)
  v_battle   jsonb;
  v_boards   jsonb := '{}'::jsonb;
  v_chase    jsonb := '{}'::jsonb;
  v_rules    jsonb;
  v_feed     jsonb;
  v_feed7    integer := 0;
  v_gi       jsonb;
  v_last     jsonb;
  v_next     jsonb;
  v_play     jsonb := '[]'::jsonb;
  v_list     jsonb;
  v_el       jsonb;
  v_a        jsonb;
  v_b        jsonb;
  v_gap      numeric;
  v_p        integer;
  v_aud      text;
  v_pf       date;
  v_pt       date;
  v_exc      jsonb;
  v_cls      record;
  v_going    jsonb;
  v_screens  text[] := '{}';
  v_weights  numeric[] := '{}';
  v_sum      numeric;
  v_secs     integer[];
  v_left     integer;
  i          integer;
begin
  select s.unit_id, u.name::text into v_unit, v_unit_nm
    from public.tv_screens s join public.units u on u.id = s.unit_id
   where s.id = p_screen;
  if v_unit is null then
    return null;
  end if;

  -- The board in force (competition_for_date's choice; drafts never).
  select x.* into c
    from public.competitions x
   where x.status = 'active' and x.kind = 'event'
     and p_today between x.starts_on and greatest(x.ends_on, coalesce(x.finale_on, x.ends_on))
     and exists (select 1 from public.competition_divisions d where d.competition_id = x.id and d.unit_id = v_unit)
   order by x.starts_on desc, x.created_at desc
   limit 1;
  if c.id is null then
    select x.* into c
      from public.competitions x
     where x.status = 'active' and x.kind = 'monthly'
     order by x.created_at desc
     limit 1;
  end if;
  if c.id is null then
    return jsonb_build_object('generated_at', now(), 'today', p_today,
      'unit', jsonb_build_object('name', v_unit_nm), 'theme', null, 'competition', null,
      'playlist', '[]'::jsonb);
  end if;

  if c.kind = 'event' then
    v_from   := c.starts_on;
    v_to     := c.ends_on;
    v_phase  := case when p_today > c.ends_on then 'final' else 'live' end;
    v_places := case when jsonb_typeof(c.prizes) = 'array' then jsonb_array_length(c.prizes) else 0 end;
  else
    v_from  := date_trunc('month', p_today)::date;
    v_to    := (date_trunc('month', p_today) + interval '1 month - 1 day')::date;
    v_phase := 'live';
  end if;

  -- Points in the last 7 days (the tale of the tape), same engine.
  select coalesce(jsonb_object_agg(w.student_id::text, w.points), '{}'::jsonb) into v_week
    from public._competition_scores(c.id, greatest(v_from, p_today - 6), least(v_to, p_today)) w
   where w.unit_id = v_unit and w.points > 0;

  -- One scoring run: this unit's rows and the battle of both units.
  with r as materialized (
    select * from public._competition_ranked(c.id, v_from, v_to)
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
              'sid', r.student_id, 'audience', r.audience, 'rank', r.rank, 'prize_rank', r.prize_rank,
              'name', r.display_name,
              'photo_path', case when r.audience = 'kids' then null else nullif(r.photo_url, '') end,
              'belt', r.belt, 'degree', coalesce(r.degree, 0),
              'points', r.points, 'classes', r.classes_count,
              'gi', r.gi_points, 'nogi', r.nogi_points,
              'week', coalesce((v_week ->> r.student_id::text)::numeric, 0),
              'staff', r.prize_eligible is false)
            order by r.audience, r.rank, r.display_name), '[]'::jsonb)
       from r
      where r.unit_id = v_unit and r.leaderboard_hidden is not true),
    (select jsonb_build_object(
              'adult', coalesce(jsonb_agg(b.o order by b.nm) filter (where b.audience = 'adult'), '[]'::jsonb),
              'kids',  coalesce(jsonb_agg(b.o order by b.nm) filter (where b.audience = 'kids'),  '[]'::jsonb))
       from (select r.audience, u.name::text as nm,
                    jsonb_build_object('unit', u.name, 'here', r.unit_id = v_unit,
                      'active', (count(*) filter (where r.classes_count > 0))::integer,
                      'classes', coalesce(sum(r.classes_count) filter (where r.classes_count > 0), 0)::integer,
                      'avg', case when count(*) filter (where r.classes_count > 0) = 0 then 0::numeric
                                  else round(sum(r.classes_count) filter (where r.classes_count > 0)::numeric
                                             / (count(*) filter (where r.classes_count > 0)), 2) end) as o
               from r join public.units u on u.id = r.unit_id
              group by r.audience, r.unit_id, u.name) b)
    into v_all, v_battle;

  -- Boards (top 10 with points) and the chase, per audience.
  foreach v_aud in array array['adult', 'kids'] loop
    select coalesce(jsonb_agg(e order by (e ->> 'rank')::integer, e ->> 'name'), '[]'::jsonb) into v_list
      from jsonb_array_elements(v_all) e
     where e ->> 'audience' = v_aud and (e ->> 'points')::numeric > 0;
    v_boards := v_boards || jsonb_build_object(v_aud, jsonb_build_object(
      'count', jsonb_array_length(v_list),
      'rows', coalesce((select jsonb_agg(x - 'sid' order by n)
                          from jsonb_array_elements(v_list) with ordinality t(x, n) where n <= 10), '[]'::jsonb)));

    v_el := null;
    if v_phase = 'live' and jsonb_array_length(v_list) >= 2 then
      v_a := v_list -> 0;
      v_b := v_list -> 1;
      v_gap := (v_a ->> 'points')::numeric - (v_b ->> 'points')::numeric;
      if v_gap <= greatest(3, (v_a ->> 'points')::numeric * 0.15) then
        -- place = the leader's real rank (a hidden member above keeps 1st)
        v_el := jsonb_build_object('kind', 'first', 'place', (v_a ->> 'rank')::integer,
                  'a', v_a - 'sid', 'b', v_b - 'sid', 'gap', v_gap);
      else
        -- the fight for the last prize place (prize places skip staff); with no
        -- prizes (the monthly race), the fight for 3rd on the board
        if v_places > 0 then
          v_p := v_places;
          select coalesce(jsonb_agg(e order by (e ->> 'prize_rank')::integer, e ->> 'name'), '[]'::jsonb) into v_b
            from jsonb_array_elements(v_list) e where (e ->> 'staff')::boolean is false and e ->> 'prize_rank' is not null;
          v_a := v_b -> (v_p - 1);
          v_b := v_b -> v_p;
        else
          v_p := 3;
          v_a := v_list -> (v_p - 1);
          v_b := v_list -> v_p;
        end if;
        if v_a is not null and v_b is not null then
          v_el := jsonb_build_object('kind', 'place', 'place', v_p, 'prize', v_places > 0,
                    'a', v_a - 'sid', 'b', v_b - 'sid',
                    'gap', (v_a ->> 'points')::numeric - (v_b ->> 'points')::numeric, 'lead_gap', v_gap);
        end if;
      end if;
    end if;
    v_chase := v_chase || jsonb_build_object(v_aud, v_el);
  end loop;

  -- How to score: the enabled rules that give points.
  select coalesce(jsonb_agg(jsonb_build_object('key', r.rule_key, 'label', k.label,
                    'description', k.description, 'points', r.points) order by k.sort, r.rule_key), '[]'::jsonb)
    into v_rules
    from public.competition_rules r
    join public.competition_rule_catalog k on k.key = r.rule_key
   where r.competition_id = c.id and r.enabled is true and r.points > 0;

  -- Latest points: awards that count and referral points, in the period up to
  -- today, for this unit's visible members (the scoring rules, not re-derived).
  with vis as (
    select (e ->> 'sid')::uuid as sid, e from jsonb_array_elements(v_all) e
  ),
  rl as (
    select r.rule_key, r.points, k.label, k.source
      from public.competition_rules r
      join public.competition_rule_catalog k on k.key = r.rule_key
     where r.competition_id = c.id and r.enabled is true and r.points > 0
  ),
  ev as (
    select w.student_id as sid, w.award_key as key, w.award_date as d, w.created_at as ts, rl.points, rl.label
      from public.competition_awards w
      join rl on rl.rule_key = w.award_key and rl.source = 'award'
     where w.voided_at is null
       and w.award_date between v_from and least(v_to, p_today)
       and w.student_id in (select vis.sid from vis)
       and public._competition_award_counts(w.student_id, w.class_id, w.class_date)
    union all
    select tb.referred_by_student_id, x.key, x.d, x.ts, rl.points, rl.label
      from public.trial_bookings tb
     cross join lateral (values
       ('referral_trial',      public.trial_first_attended_on(tb.id), null::timestamptz),
       ('referral_conversion', (tb.converted_at at time zone 'Australia/Sydney')::date, tb.converted_at)
     ) as x(key, d, ts)
      join rl on rl.rule_key = x.key and rl.source = 'referral'
     where tb.referred_by_student_id in (select vis.sid from vis)
       and tb.converted_student_id is distinct from tb.referred_by_student_id
       and x.d between v_from and least(v_to, p_today)
  )
  select coalesce((select jsonb_agg(jsonb_build_object(
                     'name', v.e ->> 'name', 'audience', v.e ->> 'audience', 'photo_path', v.e -> 'photo_path',
                     'key', z.key, 'label', z.label, 'points', z.points, 'date', z.d)
                     order by z.d desc, z.ts desc nulls last, z.key)
                    from (select * from ev order by ev.d desc, ev.ts desc nulls last, ev.key limit 10) z
                    join vis v on v.sid = z.sid), '[]'::jsonb),
         (select count(*) from ev where ev.d >= p_today - 6)::integer
    into v_feed, v_feed7;

  -- Top in Gi and No-Gi (adults).
  select jsonb_build_object(
           'gi',   coalesce((select jsonb_agg(x - 'sid' order by n) from (
                      select e as x, row_number() over (order by (e ->> 'gi')::numeric desc, e ->> 'name') as n
                        from jsonb_array_elements(v_all) e
                       where e ->> 'audience' = 'adult' and (e ->> 'gi')::numeric > 0) q where n <= 3), '[]'::jsonb),
           'nogi', coalesce((select jsonb_agg(x - 'sid' order by n) from (
                      select e as x, row_number() over (order by (e ->> 'nogi')::numeric desc, e ->> 'name') as n
                        from jsonb_array_elements(v_all) e
                       where e ->> 'audience' = 'adult' and (e ->> 'nogi')::numeric > 0) q where n <= 3), '[]'::jsonb))
    into v_gi;
  if v_gi -> 'gi' = '[]'::jsonb and v_gi -> 'nogi' = '[]'::jsonb then
    v_gi := null;
  end if;

  -- Last month's top 3 (monthly race, first 7 days of a month).
  if c.kind = 'monthly' and extract(day from p_today) <= 7 then
    v_pf := (date_trunc('month', p_today) - interval '1 month')::date;
    v_pt := (date_trunc('month', p_today) - interval '1 day')::date;
    select case when count(*) = 0 then null else jsonb_build_object('month_start', v_pf,
             'adult', coalesce(jsonb_agg(q.o order by q.rank, q.nm) filter (where q.audience = 'adult'), '[]'::jsonb),
             'kids',  coalesce(jsonb_agg(q.o order by q.rank, q.nm) filter (where q.audience = 'kids'),  '[]'::jsonb)) end
      into v_last
      from (select r.audience, r.rank, r.display_name as nm,
                   jsonb_build_object('rank', r.rank, 'name', r.display_name,
                     'photo_path', case when r.audience = 'kids' then null else nullif(r.photo_url, '') end,
                     'belt', r.belt, 'degree', coalesce(r.degree, 0), 'points', r.points,
                     'staff', r.prize_eligible is false) as o,
                   row_number() over (partition by r.audience order by r.rank, r.display_name) as n
              from public._competition_ranked(c.id, v_pf, v_pt) r
             where r.unit_id = v_unit and r.leaderboard_hidden is not true and r.points > 0) q
     where q.n <= 3;
  end if;

  -- The next class today at this unit (the one on now, until it ends) and who is
  -- going. uniform / level / class_exceptions live outside the repo's migrations:
  -- read defensively, and a failure here drops only next_class.
  begin
    v_exc := '[]'::jsonb;
    if to_regclass('public.class_exceptions') is not null then
      execute 'select coalesce(jsonb_agg(to_jsonb(e)), ''[]''::jsonb) from public.class_exceptions e
                where e.unit_id = $1 and e.exception_date = $2'
         into v_exc using v_unit, p_today;
    end if;
    select q.* into v_cls from (
      select k.id as class_id, k.time as t, coalesce(k.duration_minutes, 60) as dur,
             nullif(to_jsonb(k) ->> 'uniform', '') as uni, nullif(to_jsonb(k) ->> 'level', '') as lvl,
             k.type::text as typ, coalesce(nullif(k.audience, ''), 'Adults') as aud
        from public.classes k
       where k.unit_id = v_unit
         and k.day_of_week = extract(dow from p_today)::integer
         and k.active is not false
         and not exists (select 1 from jsonb_array_elements(v_exc) x where x ->> 'kind' = 'closed')
         and not exists (select 1 from jsonb_array_elements(v_exc) x
                          where x ->> 'kind' = 'cancelled' and x ->> 'class_id' = k.id::text)
      union all
      select null, (x ->> 'oneoff_time')::time, coalesce((x ->> 'oneoff_duration_minutes')::integer, 60),
             nullif(x ->> 'oneoff_uniform', ''), nullif(x ->> 'oneoff_level', ''), null,
             coalesce(nullif(x ->> 'oneoff_audience', ''), 'Adults')
        from jsonb_array_elements(v_exc) x
       where x ->> 'kind' = 'oneoff' and nullif(x ->> 'oneoff_time', '') is not null
    ) q
     where extract(epoch from q.t) / 60 + q.dur > extract(epoch from p_now) / 60
     order by q.t, q.aud
     limit 1;
    if v_cls.t is not null then
      select coalesce(jsonb_agg(jsonb_build_object(
               'name', public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                               public._competition_audience(s.prog::text) = 'kids'),
               'kid', public._competition_audience(s.prog::text) = 'kids',
               'photo_path', case when public._competition_audience(s.prog::text) = 'kids' then null
                                  else nullif(s.photo_url::text, '') end,
               'belt', s.belt::text, 'degree', coalesce(s.degree::integer, 0),
               'here', a.status = 'present')
             order by a.attended_at desc, s.id), '[]'::jsonb)
        into v_going
        from public.attendance a
        join public.students s on s.id = a.student_id
       where a.class_date = p_today
         and a.status in ('going', 'present')
         and s.leaderboard_hidden is not true
         and ((v_cls.class_id is not null and a.class_id = v_cls.class_id)
              or (v_cls.class_id is null and a.class_id is null and a.unit_id = v_unit
                  and left(a.class_time::text, 5) = to_char(v_cls.t, 'HH24:MI')));
      v_next := jsonb_build_object(
        'time', to_char(v_cls.t, 'HH24:MI'), 'duration', v_cls.dur,
        'label', public._tv_class_label(v_cls.uni, v_cls.lvl, v_cls.typ),
        'uniform', coalesce(v_cls.uni, case when v_cls.typ in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'Gi'
                                            else 'No-Gi' end),
        'audience', v_cls.aud,
        'going', v_going);
    end if;
  exception when others then
    raise warning '155 tv next_class skipped: % (%)', sqlerrm, sqlstate;
    v_next := null;
  end;

  -- Playlist: 90 seconds, by importance. The races always; then last month's
  -- winners, the chases, how to score (live only), latest points (if any in the
  -- last 7 days), the battle (both units on the board, someone trained), gi /
  -- no-gi (if any).
  v_screens := array['race_adults', 'race_kids'];
  v_weights := array[1.5, 1.5];
  if v_last is not null then v_screens := v_screens || 'last_results'::text; v_weights := v_weights || 1.2; end if;
  if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
  if v_chase -> 'kids'  <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text;   v_weights := v_weights || 1.0; end if;
  if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
  if v_feed7 > 0 then v_screens := v_screens || 'feed'::text; v_weights := v_weights || 1.0; end if;
  if exists (select 1 from jsonb_each(v_battle) a
              where jsonb_array_length(a.value) >= 2
                and exists (select 1 from jsonb_array_elements(a.value) x where (x ->> 'active')::integer > 0)) then
    v_screens := v_screens || 'battle'::text; v_weights := v_weights || 1.0;
  end if;
  if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;

  select sum(w) into v_sum from unnest(v_weights) w;
  v_secs := array(select floor(90 * w / v_sum)::integer from unnest(v_weights) w);
  v_left := 90 - (select sum(s) from unnest(v_secs) s);
  i := 1;
  while v_left > 0 loop
    v_secs[i] := v_secs[i] + 1;
    v_left := v_left - 1;
    i := i % array_length(v_secs, 1) + 1;
  end loop;
  select jsonb_agg(jsonb_build_object('screen', v_screens[n], 'seconds', v_secs[n]) order by n)
    into v_play from generate_subscripts(v_screens, 1) n;

  return jsonb_build_object(
    'generated_at', now(),
    'today', p_today,
    'unit', jsonb_build_object('name', v_unit_nm),
    'theme', nullif(c.theme ->> 'style', ''),
    'competition', jsonb_build_object('name', c.name, 'kind', c.kind, 'starts_on', c.starts_on,
                     'ends_on', c.ends_on, 'finale_on', c.finale_on, 'places', v_places,
                     'prizes', case when v_places > 0 then c.prizes else '[]'::jsonb end,
                     'phase', v_phase, 'period_from', v_from, 'period_to', v_to),
    'boards', v_boards,
    'chase', v_chase,
    'battle', v_battle,
    'rules', v_rules,
    'feed', v_feed,
    'gi_nogi', v_gi,
    'last_results', v_last,
    'next_class', v_next,
    'playlist', v_play);
end;
$$;

select pg_temp.acl_copy((select acl from acl156 where k = 'scores'),    'public._competition_scores(uuid,date,date)');
select pg_temp.acl_copy((select acl from acl156 where k = 'ranked'),    'public._competition_ranked(uuid,date,date)');
select pg_temp.acl_copy((select acl from acl156 where k = 'standings'), 'public.competition_standings(uuid,date,date)');
select pg_temp.acl_copy((select acl from acl156 where k = 'audience'),  'public._competition_audience(text)');

do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ~ '_competition_minor\(|_competition_audience\(\s*(?:[^(),]|\([^()]*\))*,';
  if v is not null then
    raise exception '156 rollback: a 156 helper: still called by %', v;
  end if;
end $$;

drop function if exists public._competition_minor(text);
drop function if exists public._competition_audience(text, text);

commit;
