-- ============================================================================
-- 149 — Competitions (points boards), PHASE A2: functions
-- ============================================================================
--
-- ONE source of truth for scores: _competition_scores (internal, no client
-- access). Every surface reads it through competition_standings (ranks and
-- visibility), competition_unit_battle (per unit and audience) and
-- competition_finalize (history snapshot). Points are never stored per
-- competition; awards are facts (148: competition_awards).
--
-- Internal (EXECUTE revoked from public, anon, authenticated):
--   _competition_eligible(active, standing, membership_level)  ONE eligibility rule
--   _competition_audience(prog)                                kids / adult
--   trial_first_attended_on(booking)                           ONE answer to "first attended trial day"
--   _competition_period(competition, from, to)                 the period, clamped
--   _competition_scores(competition, from, to)                 THE scores
--   _competition_ranked(competition, from, to)                 scores + rank + prize_rank
-- For authenticated (SECURITY DEFINER, explicit role checks):
--   competition_standings, competition_unit_battle, competition_for_date,
--   competition_award_add, competition_award_void, set_leaderboard_hidden,
--   set_prize_eligible, trial_set_referrer, competition_finalize
--
-- Requires 148. Reuses is_admin(), is_staff(), current_status(),
-- guardian_student_ids(), is_guardian_of(uuid, text), training_count(uuid, date, date).
-- No existing function, policy or view changes.
--
-- Rollback: 149_competitions_functions_rollback.sql (after 150's).
-- Checks:   149_competitions_functions_verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Shared helpers
-- ---------------------------------------------------------------------------

-- WHO CAN SCORE: active, standing 'ok', not a visitor or casual tier (NULL
-- membership_level = full member). NULL safe: every input is coalesced, so a
-- NULL never turns the whole predicate NULL (and silently drops the row).
create or replace function public._competition_eligible(p_active boolean, p_standing text, p_membership text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select coalesce(p_active, false)
     and coalesce(p_standing, '') = 'ok'
     and coalesce(p_membership, '') not like 'visitor\_%'
     and coalesce(p_membership, '') not like 'casual\_%'
$$;

-- Division audience from students.prog: 'kids' only for prog = 'kids'; NULL and
-- everything else is 'adult'.
create or replace function public._competition_audience(p_prog text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when p_prog = 'kids' then 'kids' else 'adult' end
$$;

-- The day a trial booking was first attended. Sessions are the source of truth
-- when the booking has ANY: the earliest attended session (NULL if none was
-- attended). Only a booking with no sessions falls back to attended_at (Sydney
-- date). The two paths are never mixed.
create or replace function public.trial_first_attended_on(p_booking uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select case
           when exists (select 1 from public.trial_sessions ts where ts.trial_booking_id = p_booking)
             then (select min(ts.class_date) from public.trial_sessions ts
                    where ts.trial_booking_id = p_booking and ts.attended is true)
           else (select (tb.attended_at at time zone 'Australia/Sydney')::date
                   from public.trial_bookings tb where tb.id = p_booking)
         end
$$;

-- The scoring period. event: defaults to starts_on..ends_on and any p_from /
-- p_to is clamped inside it. monthly: p_from and p_to are required.
create or replace function public._competition_period(p_competition uuid, p_from date, p_to date)
returns table (period_from date, period_to date)
language plpgsql
stable
security definer
set search_path = public
as $$
declare c public.competitions;
begin
  select * into c from public.competitions where id = p_competition;
  if not found then
    raise exception 'competition % not found', p_competition using errcode = 'no_data_found';
  end if;
  if c.kind = 'event' then
    period_from := greatest(coalesce(p_from, c.starts_on), c.starts_on);
    period_to   := least(coalesce(p_to, c.ends_on), c.ends_on);
  else
    if p_from is null or p_to is null then
      raise exception 'monthly competition: p_from and p_to are required' using errcode = 'invalid_parameter_value';
    end if;
    period_from := p_from;
    period_to   := p_to;
  end if;
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. THE source: _competition_scores
--    One row per eligible student per division (0 points included).
-- ---------------------------------------------------------------------------
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

-- Scores + rank (standard competition ranking 1, 1, 3: rank(), per division,
-- over ALL eligible students, hidden ones included) + prize_rank (same order,
-- prize_eligible only; NULL otherwise).
-- Order: points desc, classes_count desc, last_scored_on asc (earlier reached
-- first; no score last).
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

-- ---------------------------------------------------------------------------
-- 3. competition_standings — what the app and the TV read
--    Visibility (ranks are computed BEFORE filtering, never renumbered):
--      * caller must be approved;
--      * a hidden student's row only for themselves, their guardians, staff/admin;
--      * a kids division only for staff/admin, guardians of a kid in it, and kids
--        themselves; everyone else gets the adult divisions.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 4. competition_unit_battle — per unit and audience (adults vs adults, kids
--    vs kids). Same eligibility as the boards: it aggregates _competition_scores.
--    active_students = eligible with at least one present class in the period.
-- ---------------------------------------------------------------------------
create or replace function public.competition_unit_battle(p_competition uuid, p_from date default null, p_to date default null)
returns table (
  unit_id         uuid,
  unit_name       text,
  audience        text,
  active_students integer,
  total_classes   integer,
  avg_classes     numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_status(), '') <> 'approved' then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query
    select s.unit_id,
           u.name::text,
           s.audience,
           (count(*) filter (where s.classes_count > 0))::integer,
           coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0)::integer,
           case when count(*) filter (where s.classes_count > 0) = 0 then 0::numeric
                else (coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0))::numeric
                     / (count(*) filter (where s.classes_count > 0))::numeric
           end
      from public._competition_scores(p_competition, p_from, p_to) s
      left join public.units u on u.id = s.unit_id
     group by s.unit_id, u.name, s.audience
     order by s.audience, u.name, s.unit_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. competition_for_date — which competition a unit shows on a day: an active
--    event covering the day (through its finale) with a division for the unit,
--    otherwise the active monthly race.
-- ---------------------------------------------------------------------------
create or replace function public.competition_for_date(p_unit uuid, p_date date)
returns table (
  id        uuid,
  name      text,
  kind      text,
  starts_on date,
  ends_on   date,
  finale_on date,
  prizes    jsonb,
  theme     jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_status(), '') <> 'approved' then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query
    select c.id, c.name::text, c.kind::text, c.starts_on, c.ends_on, c.finale_on, c.prizes, c.theme
      from public.competitions c
     where c.status = 'active' and c.kind = 'event'
       and p_date between c.starts_on and greatest(c.ends_on, coalesce(c.finale_on, c.ends_on))
       and exists (select 1 from public.competition_divisions d
                    where d.competition_id = c.id and d.unit_id = p_unit)
     order by c.starts_on desc, c.created_at desc
     limit 1;
  if found then return; end if;
  return query
    select c.id, c.name::text, c.kind::text, c.starts_on, c.ends_on, c.finale_on, c.prizes, c.theme
      from public.competitions c
     where c.status = 'active' and c.kind = 'monthly'
     order by c.created_at desc
     limit 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. RPCs (writes). SECURITY DEFINER with explicit role checks.
-- ---------------------------------------------------------------------------

-- Who may give / void an award of this key: social_post the owner (is_admin);
-- every other award key staff or admin.
create or replace function public._competition_award_allowed(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case when p_key = 'social_post' then coalesce(public.is_admin(), false)
              else coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false) end
$$;

create or replace function public.competition_award_add(
  p_student    uuid,
  p_key        text,
  p_date       date,
  p_class_id   uuid default null,
  p_class_date date default null,
  p_note       text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text;
  v_unit   uuid;
  v_id     uuid;
begin
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
  -- class_date is required; class_id is optional (a one-off class from
  -- class_exceptions has none).
  if p_key in ('class_challenge', 'best_attitude') and p_class_date is null then
    raise exception '% needs the class date', p_key using errcode = 'invalid_parameter_value';
  end if;
  select s.unit_id into v_unit from public.students s where s.id = p_student;
  if not found then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date, unit_id, note, awarded_by)
  values (p_student, p_key, p_date, p_class_id, p_class_date, v_unit, nullif(btrim(p_note), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.competition_award_void(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare a public.competition_awards;
begin
  select * into a from public.competition_awards where id = p_id for update;
  if not found then
    raise exception 'award % not found', p_id using errcode = 'no_data_found';
  end if;
  if not public._competition_award_allowed(a.award_key) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if a.voided_at is not null then
    raise exception 'award % is already voided', p_id using errcode = 'invalid_parameter_value';
  end if;
  update public.competition_awards set voided_at = now(), voided_by = auth.uid() where id = p_id;
end;
$$;

create or replace function public.set_leaderboard_hidden(p_student uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_hidden is null then
    raise exception 'p_hidden required' using errcode = 'invalid_parameter_value';
  end if;
  if not (exists (select 1 from public.students s where s.id = p_student and s.user_id = auth.uid())
          or coalesce(public.is_guardian_of(p_student, 'manage'), false)
          or coalesce(public.is_admin(), false)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  update public.students set leaderboard_hidden = p_hidden where id = p_student;
  if not found then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
end;
$$;

create or replace function public.set_prize_eligible(p_student uuid, p_eligible boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_eligible is null then
    raise exception 'p_eligible required' using errcode = 'invalid_parameter_value';
  end if;
  update public.students set prize_eligible = p_eligible where id = p_student;
  if not found then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
end;
$$;

create or replace function public.trial_set_referrer(p_booking uuid, p_student uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_student is not null and not exists (select 1 from public.students s where s.id = p_student) then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
  update public.trial_bookings
     set referred_by_student_id = p_student,       -- NULL clears it
         referred_by_set_by     = auth.uid(),
         referred_by_set_at     = now()
   where id = p_booking;
  if not found then
    raise exception 'trial booking % not found', p_booking using errcode = 'no_data_found';
  end if;
end;
$$;

-- Freeze the current standings (the full rank list, hidden included) into
-- competition_results for the resolved period. REPLACES that period's snapshot
-- in one call (delete, then insert): a student who is no longer ranked loses
-- their row. Returns the number of rows written.
create or replace function public.competition_finalize(p_competition uuid, p_from date, p_to date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from date; v_to date; v_n integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select p.period_from, p.period_to into v_from, v_to
    from public._competition_period(p_competition, p_from, p_to) p;
  delete from public.competition_results
   where competition_id = p_competition and period_from = v_from and period_to = v_to;
  insert into public.competition_results
    (competition_id, period_from, period_to, division_id, student_id, points, rank, prize_rank, payload, finalized_at, finalized_by)
  select p_competition, v_from, v_to, r.division_id, r.student_id, r.points, r.rank, r.prize_rank,
         jsonb_build_object(
           'display_name', r.display_name, 'audience', r.audience, 'unit_id', r.unit_id,
           'class_points', r.class_points, 'gi_points', r.gi_points, 'nogi_points', r.nogi_points,
           'award_points', r.award_points, 'referral_points', r.referral_points,
           'classes_count', r.classes_count, 'last_scored_on', r.last_scored_on,
           'prize_eligible', r.prize_eligible, 'leaderboard_hidden', r.leaderboard_hidden),
         now(), auth.uid()
    from public._competition_ranked(p_competition, v_from, v_to) r;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------------
revoke all on function public._competition_eligible(boolean, text, text)           from public, anon, authenticated;
revoke all on function public._competition_audience(text)                          from public, anon, authenticated;
revoke all on function public.trial_first_attended_on(uuid)                        from public, anon, authenticated;
revoke all on function public._competition_period(uuid, date, date)                from public, anon, authenticated;
revoke all on function public._competition_scores(uuid, date, date)                from public, anon, authenticated;
revoke all on function public._competition_ranked(uuid, date, date)                from public, anon, authenticated;
revoke all on function public._competition_award_allowed(text)                     from public, anon, authenticated;

revoke all on function public.competition_standings(uuid, date, date)              from public, anon;
revoke all on function public.competition_unit_battle(uuid, date, date)            from public, anon;
revoke all on function public.competition_for_date(uuid, date)                    from public, anon;
revoke all on function public.competition_award_add(uuid, text, date, uuid, date, text) from public, anon;
revoke all on function public.competition_award_void(uuid)                         from public, anon;
revoke all on function public.set_leaderboard_hidden(uuid, boolean)                from public, anon;
revoke all on function public.set_prize_eligible(uuid, boolean)                    from public, anon;
revoke all on function public.trial_set_referrer(uuid, uuid)                       from public, anon;
revoke all on function public.competition_finalize(uuid, date, date)               from public, anon;

grant execute on function public.competition_standings(uuid, date, date)           to authenticated;
grant execute on function public.competition_unit_battle(uuid, date, date)         to authenticated;
grant execute on function public.competition_for_date(uuid, date)                  to authenticated;
grant execute on function public.competition_award_add(uuid, text, date, uuid, date, text) to authenticated;
grant execute on function public.competition_award_void(uuid)                      to authenticated;
grant execute on function public.set_leaderboard_hidden(uuid, boolean)             to authenticated;
grant execute on function public.set_prize_eligible(uuid, boolean)                 to authenticated;
grant execute on function public.trial_set_referrer(uuid, uuid)                    to authenticated;
grant execute on function public.competition_finalize(uuid, date, date)            to authenticated;

commit;
