-- ============================================================================
-- 148 — Competitions (points boards), PHASE A1: schema
-- ============================================================================
--
-- A reusable competition engine: events (Christmas Cup 2026) and a permanent
-- monthly race. CORE PRINCIPLE: points are CALCULATED, never stored per
-- competition. One internal source function (149: _competition_scores) computes
-- scores from attendance, awards and referrals; every surface reads from it.
-- Manual awards are stored here as FACTS (who, what, when), not as points.
-- competition_results is only a frozen snapshot for history (149:
-- competition_finalize).
--
-- Additive only, fully backward compatible:
--   new tables  competition_rule_catalog, competitions, competition_divisions,
--               competition_rules, competition_awards, competition_results
--   students    + leaderboard_hidden boolean not null default false
--               + prize_eligible     boolean not null default true
--   trial_bookings + referrer_name, referred_by_student_id, referred_by_set_by,
--               referred_by_set_at (appended; no view selects trial_bookings)
-- No existing function, policy, view or row changes.
--
-- RLS on every new table:
--   catalog: SELECT when approved. competitions: SELECT when approved and
--     (is_admin() or status active / archived); divisions / rules: the same,
--     through their competition. INSERT/UPDATE/DELETE on these four: is_admin().
--   competition_results: SELECT only is_staff() OR is_admin(); no write policy
--     (written only by the 149 RPC). Members read history through functions.
--   competition_awards: SELECT for is_staff() OR is_admin() OR the student's
--     own account OR a guardian (guardian_student_ids()); NO write policy:
--     writes only through the 149 RPCs.
--   anon: no access. authenticated: no TRUNCATE (not subject to RLS).
--
-- Rollback: 148_competitions_schema_rollback.sql (after 150's and 149's).
-- Checks:   148_competitions_schema_verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Rule catalog: what can score, and how
-- ---------------------------------------------------------------------------
create table if not exists public.competition_rule_catalog (
  key            text primary key,
  label          text not null,
  description    text,
  how_to_score   text,                     -- template with a {points} placeholder
  source         text not null check (source in ('attendance','award','referral')),
  default_points numeric not null default 0,
  default_params jsonb not null default '{}'::jsonb,
  sort           integer not null default 0
);
comment on table public.competition_rule_catalog is
  'What can score in a competition (148). source attendance / award / referral. Per competition: competition_rules.';

insert into public.competition_rule_catalog (key, label, description, how_to_score, source, default_points, default_params, sort) values
  ('class_attended', 'Classes attended',
   'Every class marked present counts. Two classes on the same day both count. A private lesson counts at most private_cap.',
   'Train: {points} per class', 'attendance', 1, '{"mode":"class_value","private_cap":1}'::jsonb, 10),
  ('social_post', 'Social post',
   'Post about your training on social media and tag the academy. One per day.',
   'Post and tag us: {points} per day', 'award', 2, '{}'::jsonb, 20),
  ('class_challenge', 'Class challenge',
   'Win the challenge set in a class.',
   'Win a class challenge: {points}', 'award', 3, '{}'::jsonb, 30),
  ('best_attitude', 'Best attitude',
   'Chosen by the instructor for the best attitude in a class.',
   'Best attitude in class: {points}', 'award', 0, '{}'::jsonb, 40),
  ('referral_trial', 'Friend tries a class',
   'A friend you referred attends their first trial class.',
   'Bring a friend to a trial: {points}', 'referral', 3, '{}'::jsonb, 50),
  ('referral_conversion', 'Friend joins',
   'A friend you referred becomes a member.',
   'Your friend joins: {points}', 'referral', 5, '{}'::jsonb, 60)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Competitions
--    event:   both dates, starts_on <= ends_on (inclusive)
--    monthly: no dates (the period is supplied at query time)
-- ---------------------------------------------------------------------------
create table if not exists public.competitions (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  kind       text not null check (kind in ('event','monthly')),
  starts_on  date null,
  ends_on    date null,
  finale_on  date null,
  status     text not null default 'draft' check (status in ('draft','active','archived')),
  prizes     jsonb not null default '[]'::jsonb,
  theme      jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint competitions_period_by_kind check (
    (kind = 'event'   and starts_on is not null and ends_on is not null and starts_on <= ends_on)
    or (kind = 'monthly' and starts_on is null and ends_on is null)
  )
);
comment on table public.competitions is
  'A points competition (148): an event with dates, or the permanent monthly race. Scores are calculated (149), never stored here.';

create or replace function public.competitions_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.competitions_touch_updated_at() from public, anon, authenticated;

drop trigger if exists trg_competitions_touch on public.competitions;
create trigger trg_competitions_touch
  before update on public.competitions
  for each row execute function public.competitions_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Divisions: one unit + audience per board
-- ---------------------------------------------------------------------------
create table if not exists public.competition_divisions (
  id             uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id) on delete cascade,
  unit_id        uuid not null references public.units(id),
  audience       text not null check (audience in ('adult','kids')),
  label          text not null,
  sort           integer not null default 0,
  constraint competition_divisions_once unique (competition_id, unit_id, audience)
);

-- ---------------------------------------------------------------------------
-- 4. Rules of one competition (points and params per catalog key)
-- ---------------------------------------------------------------------------
create table if not exists public.competition_rules (
  competition_id uuid not null references public.competitions(id) on delete cascade,
  rule_key       text not null references public.competition_rule_catalog(key),
  points         numeric not null,
  params         jsonb not null default '{}'::jsonb,
  enabled        boolean not null default true,
  primary key (competition_id, rule_key)
);

-- ---------------------------------------------------------------------------
-- 5. Awards: FACTS (who, what, when), never points. Written only by the 149
--    RPCs; voided, never deleted.
-- ---------------------------------------------------------------------------
create table if not exists public.competition_awards (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id) on delete cascade,
  award_key   text not null references public.competition_rule_catalog(key),
  award_date  date not null,
  class_id    uuid null,
  class_date  date null,
  unit_id     uuid null,
  note        text null,
  awarded_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  voided_at   timestamptz null,
  voided_by   uuid null
);

-- Only catalog keys whose source is 'award' (a FK cannot express it).
create or replace function public.competition_awards_key_is_award()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not exists (select 1 from public.competition_rule_catalog c
                  where c.key = new.award_key and c.source = 'award') then
    raise exception 'competition_awards: % is not an award rule', new.award_key
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke all on function public.competition_awards_key_is_award() from public, anon, authenticated;

drop trigger if exists trg_competition_awards_key on public.competition_awards;
create trigger trg_competition_awards_key
  before insert or update of award_key on public.competition_awards
  for each row execute function public.competition_awards_key_is_award();

-- One social post per student per day; one challenge / attitude award per
-- student per class occurrence (class_date, plus class_id when there is one: a
-- one-off class from class_exceptions has none). Voided rows free the slot.
create unique index if not exists competition_awards_social_once
  on public.competition_awards (student_id, award_date)
  where voided_at is null and award_key = 'social_post';
create unique index if not exists competition_awards_class_once
  on public.competition_awards (student_id, award_key, class_date,
                                coalesce(class_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where voided_at is null and award_key in ('class_challenge','best_attitude');
create index if not exists competition_awards_date_idx
  on public.competition_awards (award_date) where voided_at is null;

drop trigger if exists trg_audit_competition_awards on public.competition_awards;
create trigger trg_audit_competition_awards
  after insert or update or delete on public.competition_awards
  for each row execute function public.audit_row();

-- ---------------------------------------------------------------------------
-- 6. Results: a frozen snapshot for history (149: competition_finalize)
-- ---------------------------------------------------------------------------
create table if not exists public.competition_results (
  id             uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id) on delete cascade,
  period_from    date not null,
  period_to      date not null,
  division_id    uuid references public.competition_divisions(id) on delete cascade,
  student_id     uuid not null references public.students(id) on delete cascade,
  points         numeric not null,
  rank           integer,
  prize_rank     integer,
  payload        jsonb not null default '{}'::jsonb,
  finalized_at   timestamptz not null default now(),
  finalized_by   uuid default auth.uid(),
  constraint competition_results_once unique (competition_id, period_from, period_to, student_id)
);

-- ---------------------------------------------------------------------------
-- 7. students: two flags (appended)
-- ---------------------------------------------------------------------------
alter table public.students add column if not exists leaderboard_hidden boolean not null default false;
alter table public.students add column if not exists prize_eligible     boolean not null default true;
comment on column public.students.leaderboard_hidden is
  'Hide from other members on competition boards (148). Still ranked; visible to self, guardians and staff.';
comment on column public.students.prize_eligible is
  'Can win a competition prize (148). false: still ranked, skipped by prize_rank.';

-- ---------------------------------------------------------------------------
-- 8. trial_bookings: who referred this trial (appended)
-- ---------------------------------------------------------------------------
alter table public.trial_bookings add column if not exists referrer_name          text null;
alter table public.trial_bookings add column if not exists referred_by_student_id uuid null
  references public.students(id) on delete set null;
alter table public.trial_bookings add column if not exists referred_by_set_by     uuid null;
alter table public.trial_bookings add column if not exists referred_by_set_at     timestamptz null;
create index if not exists trial_bookings_referred_by_idx
  on public.trial_bookings (referred_by_student_id) where referred_by_student_id is not null;

-- ---------------------------------------------------------------------------
-- 9. RLS and privileges
-- ---------------------------------------------------------------------------
alter table public.competition_rule_catalog enable row level security;
alter table public.competitions             enable row level security;
alter table public.competition_divisions    enable row level security;
alter table public.competition_rules        enable row level security;
alter table public.competition_awards       enable row level security;
alter table public.competition_results      enable row level security;

revoke all on public.competition_rule_catalog, public.competitions, public.competition_divisions,
              public.competition_rules, public.competition_awards, public.competition_results from anon;
revoke truncate, references, trigger on public.competition_rule_catalog, public.competitions,
              public.competition_divisions, public.competition_rules, public.competition_awards,
              public.competition_results from authenticated;
-- Writes to awards and results go only through the 149 RPCs (SECURITY DEFINER).
revoke insert, update, delete on public.competition_awards, public.competition_results from authenticated;
grant select on public.competition_rule_catalog, public.competitions, public.competition_divisions,
              public.competition_rules, public.competition_awards, public.competition_results to authenticated;
grant insert, update, delete on public.competition_rule_catalog, public.competitions,
              public.competition_divisions, public.competition_rules to authenticated;

-- catalog / competitions / divisions / rules: write when admin (read below)
do $$
declare t text;
begin
  foreach t in array array['competition_rule_catalog','competitions','competition_divisions','competition_rules'] loop
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', t || '_delete', t);
  end loop;
end $$;

-- read: the catalog when approved; competitions when approved AND (admin, or
-- status active / archived: a draft is the admin's alone); divisions and rules
-- through their competition, with the same rule.
drop policy if exists competition_rule_catalog_select on public.competition_rule_catalog;
create policy competition_rule_catalog_select on public.competition_rule_catalog
  for select to authenticated
  using (public.current_status() = 'approved');

drop policy if exists competitions_select on public.competitions;
create policy competitions_select on public.competitions
  for select to authenticated
  using (public.current_status() = 'approved'
         and (public.is_admin() or competitions.status in ('active', 'archived')));

drop policy if exists competition_divisions_select on public.competition_divisions;
create policy competition_divisions_select on public.competition_divisions
  for select to authenticated
  using (public.current_status() = 'approved'
         and exists (select 1 from public.competitions c
                      where c.id = competition_divisions.competition_id
                        and (public.is_admin() or c.status in ('active', 'archived'))));

drop policy if exists competition_rules_select on public.competition_rules;
create policy competition_rules_select on public.competition_rules
  for select to authenticated
  using (public.current_status() = 'approved'
         and exists (select 1 from public.competitions c
                      where c.id = competition_rules.competition_id
                        and (public.is_admin() or c.status in ('active', 'archived'))));

-- awards: staff, admin, the student's own account, or a guardian. No write policy.
drop policy if exists competition_awards_select on public.competition_awards;
create policy competition_awards_select on public.competition_awards
  for select to authenticated
  using (
    public.is_staff() or public.is_admin()
    or exists (select 1 from public.students s where s.id = competition_awards.student_id and s.user_id = auth.uid())
    or competition_awards.student_id = any (public.guardian_student_ids())
  );

-- results: staff and admin only. Members read history through the standings
-- functions, never this table. No write policy (149: competition_finalize).
drop policy if exists competition_results_select on public.competition_results;
create policy competition_results_select on public.competition_results
  for select to authenticated
  using (public.is_staff() or public.is_admin());

commit;
