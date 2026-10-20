-- ============================================================================
-- 163 — Competitions: a bonus for checking yourself in on the app
-- ============================================================================
--
-- John (head instructor): a bonus point when a member checks themselves in with
-- the app ("I'm going"), to push members into the app. The bonus is paid once
-- the coach marks the row present.
--
-- 1. attendance.created_by uuid null: who inserted the row. No existing column
--    records it (confirmed_by is the staff member who confirmed,
--    confirmed_by_instructor_id is unused, checked_in_at is a time only), so it
--    is added. A BEFORE INSERT trigger sets it to auth.uid() whatever the client
--    sends; a BEFORE UPDATE trigger keeps the old value, so an update (staff
--    marking present, "Move attendees to another class", an upsert that hits an
--    existing row) never changes it. No backfill: existing rows stay null and
--    never earn the bonus. Service role and SQL inserts have no auth.uid(): null.
-- 2. _attendance_is_self(created_by, student): the row was inserted by the
--    student's own login (students.user_id) or by a guardian of that student
--    (133's rule: an active guardianships row for that user; or the legacy
--    students.parent_user_id). Internal.
-- 3. Catalog rule self_checkin ('attendance', 1 point), sorted between
--    class_attended and social_post.
-- 4. _competition_scores: 156's text, changes marked "163": a flat bonus of the
--    rule's points per present row that _attendance_is_self, in the period, for
--    the population class_attended counts; a private lesson never earns it. Only
--    into points (class, gi and no-gi columns unchanged). Same signature, so
--    standings, ranking, the battle, review / publish and the TV follow.
-- 5. The Christmas Cup (672e130e-ef51-42d4-916d-61593f88515c) gets the rule,
--    1 point, enabled. The monthly race does not.
--
-- Rollback: 163_self_checkin_bonus_rollback.sql (156's _competition_scores
-- exactly). Checks: 163_self_checkin_bonus_verify.sql.
-- ============================================================================

begin;

do $$
declare
  v_src text;
  v_bad text;
begin
  -- 161 applied (closure columns), and _competition_scores is 156's text (or 163's)
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'competitions' and column_name = 'published_at') then
    raise exception '163 preflight: apply 161 first';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public._competition_scores(uuid, date, date)');
  if v_src is null then
    raise exception '163 preflight: public._competition_scores(uuid, date, date) not found';
  end if;
  if md5(v_src) <> '97874f87c2a7deadf84c27205f058753' and position('163: self_checkin' in v_src) = 0 then
    raise exception '163 preflight: _competition_scores is neither 156''s nor 163''s text; stop and compare';
  end if;
  -- every column this file reads, checked by name
  select string_agg(x.t || '.' || x.c, ', ') into v_bad
    from (values ('attendance', 'id'), ('attendance', 'student_id'), ('attendance', 'status'),
                 ('attendance', 'class_date'), ('attendance', 'class_type'),
                 ('students', 'id'), ('students', 'user_id'), ('students', 'parent_user_id'),
                 ('guardianships', 'student_id'), ('guardianships', 'guardian_user_id'), ('guardianships', 'status'),
                 ('competition_rule_catalog', 'key'), ('competition_rule_catalog', 'label'),
                 ('competition_rule_catalog', 'description'), ('competition_rule_catalog', 'how_to_score'),
                 ('competition_rule_catalog', 'source'), ('competition_rule_catalog', 'default_points'),
                 ('competition_rule_catalog', 'default_params'), ('competition_rule_catalog', 'sort'),
                 ('competition_rules', 'competition_id'), ('competition_rules', 'rule_key'),
                 ('competition_rules', 'points'), ('competition_rules', 'enabled')) x(t, c)
   where not exists (select 1 from information_schema.columns i
                      where i.table_schema = 'public' and i.table_name = x.t and i.column_name = x.c);
  if v_bad is not null then
    raise exception '163 preflight: missing columns: %', v_bad;
  end if;
  -- created_by: absent (added below) or already uuid (a re-run)
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'attendance' and column_name = 'created_by'
                and data_type <> 'uuid') then
    raise exception '163 preflight: attendance.created_by exists and is not uuid; stop';
  end if;
  -- the catalog sorts we place the new rule between
  if (select count(*) from public.competition_rule_catalog where key in ('class_attended', 'social_post')) <> 2 then
    raise exception '163 preflight: class_attended / social_post missing from the catalog';
  end if;
  if not exists (select 1 from public.competitions where id = '672e130e-ef51-42d4-916d-61593f88515c') then
    raise exception '163 preflight: the Christmas Cup (672e130e-...) is not there; stop';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. attendance.created_by, set by the database
-- ---------------------------------------------------------------------------
alter table public.attendance add column if not exists created_by uuid null;

comment on column public.attendance.created_by is
  '163: the user who inserted the row (auth.uid(), set by trg_attendance_created_by; null before 163 and for service role / SQL inserts). Never changed by an update.';

create or replace function public._attendance_created_by()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();              -- whatever the client sent
  else
    new.created_by := old.created_by;          -- an update never changes it
  end if;
  return new;
end;
$$;

revoke all on function public._attendance_created_by() from public, anon, authenticated;

drop trigger if exists trg_attendance_created_by on public.attendance;
create trigger trg_attendance_created_by
  before insert or update on public.attendance
  for each row execute function public._attendance_created_by();

-- ---------------------------------------------------------------------------
-- 2. One source: did the member (or their guardian) insert this row?
-- ---------------------------------------------------------------------------
create or replace function public._attendance_is_self(p_created_by uuid, p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_created_by is not null
     and exists (
       select 1 from public.students s
        where s.id = p_student_id
          and (s.user_id = p_created_by
               or s.parent_user_id = p_created_by                     -- legacy guardian
               or exists (select 1 from public.guardianships g        -- 133's rule
                           where g.student_id = s.id
                             and g.guardian_user_id = p_created_by
                             and g.status = 'active'))
     )
$$;

revoke all on function public._attendance_is_self(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The catalog rule
-- ---------------------------------------------------------------------------
insert into public.competition_rule_catalog (key, label, description, how_to_score, source, default_points, default_params, sort)
select 'self_checkin', 'Self check in',
       'Check yourself in on the app and get a bonus point once your coach marks you present.',
       'Check in on the app: {points} bonus per class', 'attendance', 1, '{}'::jsonb,
       (select (a.sort + b.sort) / 2 from public.competition_rule_catalog a, public.competition_rule_catalog b
         where a.key = 'class_attended' and b.key = 'social_post')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. _competition_scores
-- ---------------------------------------------------------------------------
-- 156's text; 163 changes marked.
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
  degree             integer,
  minor              boolean           -- 156: shown as a child (prog kids), whichever board
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
           s.belt::text as belt, s.degree::integer as degree,
           public._competition_minor(s.prog::text) as minor
      from public.competition_divisions d
      join public.students s
        on s.unit_id = d.unit_id
       and public._competition_audience(s.prog::text, s.belt::text) = d.audience   -- 156: adult belts board with adults
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
  sc as (
    -- 163: self_checkin. A flat bonus of the rule's points per present row the
    -- member checked in themselves (or a guardian did, _attendance_is_self), in
    -- the period, for the same population class_attended counts; a private
    -- lesson never earns it. Only into points: class, gi and no-gi stay as they are.
    select a.student_id, a.class_date, r.points as pts
      from public.attendance a
      join rules r on r.rule_key = 'self_checkin'
     cross join per
     where a.status = 'present'
       and a.class_date between per.f and per.t
       and a.student_id in (select pop.student_id from pop)
       and a.class_type is distinct from 'private'
       and public._attendance_is_self(a.created_by, a.student_id)
  ),
  sc_sum as (
    select x.student_id, sum(x.pts) as self_points, max(x.class_date) filter (where x.pts > 0) as last_d
      from sc x group by x.student_id
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
         (case when p.minor                                   -- 156: privacy follows minor, not the board
               then coalesce(n.fn, '') || coalesce(' ' || upper(left(n.ln, 1)) || '.', '')
               else coalesce(nullif(btrim(p.first_name), '') || ' ' || nullif(btrim(p.last_name), ''),
                             btrim(p.full_name))
          end)::text,
         (case when p.minor then null else p.photo_url end)::text,
         (coalesce(a.class_points, 0) + coalesce(w.award_points, 0) + coalesce(r.referral_points, 0)
          + coalesce(b.self_points, 0))::numeric,                      -- 163
         coalesce(a.class_points, 0)::numeric,
         coalesce(a.gi_points, 0)::numeric,
         coalesce(a.nogi_points, 0)::numeric,
         coalesce(w.award_points, 0)::numeric,
         coalesce(r.referral_points, 0)::numeric,
         public.training_count(p.student_id, per.f, per.t)::integer,
         greatest(a.last_d, w.last_d, r.last_d, b.last_d)::date,       -- 163
         p.prize_eligible,
         p.leaderboard_hidden,
         p.belt,
         p.degree,
         p.minor
    from pop p
   cross join per
    join names n on n.student_id = p.student_id
    left join att_sum a on a.student_id = p.student_id
    left join aw_sum  w on w.student_id = p.student_id
    left join rf_sum  r on r.student_id = p.student_id
    left join sc_sum  b on b.student_id = p.student_id                -- 163
$$;
revoke all on function public._competition_scores(uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The Christmas Cup gets the rule (not the monthly race). Idempotent: a
--    re-run never re-enables it after an owner switched it off.
-- ---------------------------------------------------------------------------
insert into public.competition_rules (competition_id, rule_key, points, enabled)
values ('672e130e-ef51-42d4-916d-61593f88515c', 'self_checkin', 1, true)
on conflict (competition_id, rule_key) do nothing;

commit;
