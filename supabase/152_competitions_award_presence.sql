-- ============================================================================
-- 152 — Competitions: a class award counts only with a present attendance
-- ============================================================================
--
-- Bug: staff awarded "Challenge +3" to a present student, then marked them
-- absent (or removed the attendance). The roster hid the toggle, but the award
-- row still counted in _competition_scores.
--
-- Fix: CREATE OR REPLACE public._competition_scores with the SAME signature,
-- return columns and column order as 149; only the "aw" CTE gains one condition
-- (marked "152"): an award with a class_date counts only while a matching
-- attendance row exists with status 'present' for the same student and date,
-- and the same class_id (or both NULL: a one-off class). Awards are facts and
-- are never voided or edited by this rule. Social posts (class_date NULL) are
-- unchanged.
--
-- Matches how the app writes: attendance upserts on (student_id, class_id,
-- class_date) with class_id = the class row's id (NULL for a one-off), and
-- compToggleClassAward passes the same class id (NULL for a one-off) and the
-- class date.
--
-- Rollback: 152_competitions_award_presence_rollback.sql (149's exact text).
-- Checks:   152_competitions_award_presence_verify.sql.
-- ============================================================================

begin;

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
       -- 152: an award tied to a class counts only while that student has a
       -- PRESENT attendance for that class occurrence (same class_id, or both
       -- NULL for a one-off class, on the same class_date). The award row is
       -- never touched: marked absent or removed, it stops counting; present
       -- again, it counts again. Awards without a class (social_post) unchanged.
       and (w.class_date is null
            or exists (select 1 from public.attendance a
                        where a.student_id = w.student_id
                          and a.status = 'present'
                          and a.class_date = w.class_date
                          and ((w.class_id is not null and a.class_id = w.class_id)
                               or (w.class_id is null and a.class_id is null))))
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

revoke all on function public._competition_scores(uuid, date, date) from public, anon, authenticated;

commit;
