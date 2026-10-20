-- ============================================================================
-- 163 — Competitions: a bonus for checking yourself in on the app
-- ============================================================================
--
-- John (head instructor): a bonus point when a member checks themselves in with
-- the app ("I'm going"), to push members into the app. The bonus is paid once
-- the coach marks the row present, on a class that counts.
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
--    rule's points per present row that _attendance_is_self, on a class that
--    counts (class_value > 0), in the period, for the population class_attended
--    counts; a private lesson never earns it. It is in points and, so the parts
--    add up, in a new last column checkin_points (class, gi and no-gi columns
--    unchanged).
-- 5. checkin_points carried, appended at the end, by every function that passes
--    the parts through: _competition_ranked (156), _competition_close_rows (161),
--    competition_standings (161; a snapshot made before 163 reads 0). Their
--    return types change, so all four are dropped and recreated with the exact
--    grants they had (159's acl_copy).
-- 6. The snapshots store it: competition_finalize (149) and competition_publish
--    (161) add 'checkin_points' to the payload. The TV's Cup "bonus points"
--    number counts check ins too (_tv_payload, 161's text). Same signatures.
-- 7. The Christmas Cup (672e130e-ef51-42d4-916d-61593f88515c) gets the rule,
--    1 point, enabled. The monthly race does not.
--
-- Rollback: 163_self_checkin_bonus_rollback.sql (every function's pre-163 text
-- and grants exactly). Checks: 163_self_checkin_bonus_verify.sql.
-- ============================================================================

begin;

do $$
declare
  v_bad text;
  r     record;
  v_src text;
begin
  -- 161 applied (closure columns)
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'competitions' and column_name = 'published_at') then
    raise exception '163 preflight: apply 161 first';
  end if;
  -- every function 163 replaces is the text 163 was written against (or 163's own: a re-run)
  for r in select * from (values
    ('public._competition_scores(uuid,date,date)', '97874f87c2a7deadf84c27205f058753'),
    ('public._competition_ranked(uuid,date,date)', 'be3d5c3a8f485282ee0fac6657f9e827'),
    ('public.competition_standings(uuid,date,date)', '4d273681f1517a6422b20115a6a84177'),
    ('public._competition_close_rows(uuid)', 'bc71118885a4975c40585939b94ccd86'),
    ('public.competition_publish(uuid,jsonb)', '13f72aef867a6d4ffe68fe681961a7b1'),
    ('public.competition_finalize(uuid,date,date)', 'dff032bc28b313b8e92739edf6c7d920'),
    ('public._tv_payload(uuid,date,time)', '401a19f144f0011668cef852bf322b19')
  ) t(sig, pre_md5) loop
    select prosrc into v_src from pg_proc where oid = to_regprocedure(r.sig);
    if v_src is null then
      raise exception '163 preflight: % not found', r.sig;
    end if;
    if md5(v_src) <> r.pre_md5 and position('-- 163' in v_src) = 0 then
      raise exception '163 preflight: % is not the text 163 expects; stop and compare', r.sig;
    end if;
  end loop;
  -- every column this file reads, checked by name
  select string_agg(x.t || '.' || x.c, ', ') into v_bad
    from (values ('attendance', 'id'), ('attendance', 'student_id'), ('attendance', 'status'),
                 ('attendance', 'class_date'), ('attendance', 'class_type'), ('attendance', 'class_value'),
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

-- grants copied entry for entry onto a recreated function (159's helpers)
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
select 'self_checkin', 'Check in on the app',
       'Tap I''m going before class. The bonus counts once your coach marks you present.',
       'Check in on the app: {points} bonus per class', 'attendance', 1, '{}'::jsonb,
       (select (a.sort + b.sort) / 2 from public.competition_rule_catalog a, public.competition_rule_catalog b
         where a.key = 'class_attended' and b.key = 'social_post')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. and 5. _competition_scores and the functions that pass its parts through
--    (return types change: drop, recreate, same grants)
-- ---------------------------------------------------------------------------
create temp table acl163 on commit drop as
  select x.sig, (select proacl from pg_proc where oid = to_regprocedure(x.sig)) as acl
    from (values ('public._competition_scores(uuid,date,date)'), ('public._competition_ranked(uuid,date,date)'), ('public._competition_close_rows(uuid)'), ('public.competition_standings(uuid,date,date)')) x(sig);

drop function if exists public.competition_standings(uuid, date, date);
drop function if exists public._competition_close_rows(uuid);
drop function if exists public._competition_ranked(uuid, date, date);
drop function if exists public._competition_scores(uuid, date, date);

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
  minor              boolean,          -- 156: shown as a child (prog kids), whichever board
  checkin_points     numeric           -- 163: the self_checkin bonus (already in points)
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
    -- member checked in themselves (or a guardian did, _attendance_is_self), on a
    -- class that counts (class_value > 0), in the period, for the population
    -- class_attended counts; a private lesson never earns it. In points and in
    -- checkin_points; class, gi and no-gi stay as they are.
    select a.student_id, a.class_date, r.points as pts
      from public.attendance a
      join rules r on r.rule_key = 'self_checkin'
     cross join per
     where a.status = 'present'
       and a.class_value > 0
       and a.class_date between per.f and per.t
       and a.student_id in (select pop.student_id from pop)
       and a.class_type is distinct from 'private'
       and public._attendance_is_self(a.created_by, a.student_id)
  ),
  sc_sum as (
    select x.student_id, sum(x.pts) as checkin_points, max(x.class_date) filter (where x.pts > 0) as last_d
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
          + coalesce(b.checkin_points, 0))::numeric,                   -- 163
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
         p.minor,
         coalesce(b.checkin_points, 0)::numeric                       -- 163
    from pop p
   cross join per
    join names n on n.student_id = p.student_id
    left join att_sum a on a.student_id = p.student_id
    left join aw_sum  w on w.student_id = p.student_id
    left join rf_sum  r on r.student_id = p.student_id
    left join sc_sum  b on b.student_id = p.student_id                -- 163
$$;

-- 156's text; 163 appends checkin_points.
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
  degree             integer,
  minor              boolean,
  checkin_points     numeric             -- 163
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
         s.belt, s.degree, s.minor, s.checkin_points                 -- 163
    from public._competition_scores(p_competition, p_from, p_to) s
$$;

-- 161's text; 163 appends checkin_points.
create or replace function public._competition_close_rows(p_competition uuid)
returns table (
  division_id        uuid,
  division_label     text,
  division_sort      integer,
  unit_id            uuid,
  audience           text,
  student_id         uuid,
  display_name       text,
  real_name          text,
  photo_url          text,
  belt               text,
  degree             integer,
  minor              boolean,
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
  places             integer,
  tie_size           integer,
  tie_unresolved     boolean,
  checkin_points     numeric             -- 163
)
language sql
stable
security definer
set search_path = public
as $$
  with c as (
    select x.id, x.starts_on, x.ends_on,
           case when jsonb_typeof(x.prizes) = 'array' then jsonb_array_length(x.prizes) else 0 end as places
      from public.competitions x
     where x.id = p_competition and x.kind = 'event'
  ),
  r as (
    select r.* from c cross join lateral public._competition_ranked(c.id, c.starts_on, c.ends_on) r
  ),
  g as (
    select r.division_id, r.prize_rank, count(*)::integer as n
      from r where r.prize_rank is not null and r.points > 0          -- a prize needs points
     group by r.division_id, r.prize_rank
  )
  select r.division_id, d.label::text, d.sort, r.unit_id, r.audience, r.student_id, r.display_name,
         coalesce(nullif(btrim(coalesce(s.first_name::text, '') || ' ' || coalesce(s.last_name::text, '')), ''), s.full_name::text),
         r.photo_url, r.belt, r.degree, r.minor, r.points, r.class_points, r.gi_points, r.nogi_points,
         r.award_points, r.referral_points, r.classes_count, r.last_scored_on, r.prize_eligible, r.leaderboard_hidden,
         r.rank, r.prize_rank, c.places,
         coalesce(g.n, 1),
         coalesce(r.points > 0 and g.n > 1 and r.prize_rank <= c.places and r.prize_rank + g.n - 1 > c.places, false),
         r.checkin_points                                             -- 163
    from r
   cross join c
    join public.competition_divisions d on d.id = r.division_id
    join public.students s on s.id = r.student_id
    left join g on g.division_id = r.division_id and g.prize_rank = r.prize_rank
$$;

-- 161's text; 163 appends checkin_points (the frozen branch reads it from the payload).
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
  degree             integer,
  minor              boolean,
  checkin_points     numeric             -- 163
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff boolean := coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false);
  v_mine  uuid[];   -- the caller's own students rows and their guardian kids
  v_c     public.competitions;   -- 161
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
  select x.* into v_c from public.competitions x where x.id = p_competition;
  -- 161: a published event over its own period is the frozen snapshot (same
  -- columns and visibility; a hidden prize winner shows as Anonymous to others)
  if v_c.kind = 'event' and v_c.published_at is not null
     and coalesce(p_from, v_c.starts_on) <= v_c.starts_on and coalesce(p_to, v_c.ends_on) >= v_c.ends_on then
    return query
      select cr.division_id,
             (cr.payload ->> 'unit_id')::uuid,
             (cr.payload ->> 'audience')::text,
             case when z.anon then null::uuid else cr.student_id end,
             (case when z.anon then 'Anonymous' else cr.payload ->> 'display_name' end)::text,
             (case when z.anon then null else cr.payload ->> 'photo_url' end)::text,
             cr.points,
             (cr.payload ->> 'class_points')::numeric,
             (cr.payload ->> 'gi_points')::numeric,
             (cr.payload ->> 'nogi_points')::numeric,
             (cr.payload ->> 'award_points')::numeric,
             (cr.payload ->> 'referral_points')::numeric,
             (cr.payload ->> 'classes_count')::integer,
             (cr.payload ->> 'last_scored_on')::date,
             (cr.payload ->> 'prize_eligible')::boolean,
             (cr.payload ->> 'leaderboard_hidden')::boolean,
             cr.rank,
             cr.prize_rank,
             (case when z.anon then null else cr.payload ->> 'belt' end)::text,
             (case when z.anon then null else (cr.payload ->> 'degree')::integer end)::integer,
             (cr.payload ->> 'minor')::boolean,
             coalesce((cr.payload ->> 'checkin_points')::numeric, 0)   -- 163: 0 in a snapshot made before 163
        from public.competition_results cr
       cross join lateral (select
               coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false)
               and not (v_staff or cr.student_id = any (v_mine)) as anon,
               cr.points > 0 and cr.prize_rank is not null and cr.prize_rank <= coalesce((cr.payload ->> 'places')::integer, 0) as winner) z
       where cr.competition_id = p_competition
         and cr.period_from = v_c.starts_on and cr.period_to = v_c.ends_on
         and (cr.payload ->> 'audience' = 'adult'
              or v_staff
              or exists (select 1 from public.students k
                          where k.id = any (v_mine)
                            and k.unit_id = (cr.payload ->> 'unit_id')::uuid
                            and public._competition_audience(k.prog::text, k.belt::text) = 'kids'))
         and (not coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false)
              or v_staff or cr.student_id = any (v_mine) or z.winner)
       order by 3, 2, cr.rank, 5, 4;
    return;
  end if;
  -- 161: ended and not published yet (provisional): no positions for members
  if v_c.kind = 'event' and v_c.ends_on < (now() at time zone 'Australia/Sydney')::date
     and v_c.published_at is null and not v_staff then
    return;
  end if;
  return query
    select r.*
      from public._competition_ranked(p_competition, p_from, p_to) r
     where (r.audience = 'adult'
            or v_staff
            or exists (select 1 from public.students k
                        where k.id = any (v_mine)
                          and k.unit_id = r.unit_id
                          and public._competition_audience(k.prog::text, k.belt::text) = 'kids'))
       and (r.leaderboard_hidden is not true
            or v_staff
            or r.student_id = any (v_mine))
     order by r.audience, r.unit_id, r.rank, r.display_name, r.student_id;
end;
$$;

select pg_temp.acl_copy((select acl from acl163 where sig = 'public._competition_scores(uuid,date,date)'), 'public._competition_scores(uuid,date,date)');
select pg_temp.acl_copy((select acl from acl163 where sig = 'public._competition_ranked(uuid,date,date)'), 'public._competition_ranked(uuid,date,date)');
select pg_temp.acl_copy((select acl from acl163 where sig = 'public._competition_close_rows(uuid)'), 'public._competition_close_rows(uuid)');
select pg_temp.acl_copy((select acl from acl163 where sig = 'public.competition_standings(uuid,date,date)'), 'public.competition_standings(uuid,date,date)');

-- ---------------------------------------------------------------------------
-- 6. The snapshots keep checkin_points; the TV's Cup bonus counts it
-- ---------------------------------------------------------------------------
-- 149's text; 163 adds checkin_points to the payload.
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
           'checkin_points', r.checkin_points,                                    -- 163
           'classes_count', r.classes_count, 'last_scored_on', r.last_scored_on,
           'prize_eligible', r.prize_eligible, 'leaderboard_hidden', r.leaderboard_hidden),
         now(), auth.uid()
    from public._competition_ranked(p_competition, v_from, v_to) r;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- 161's text; 163 adds checkin_points to the payload.
create or replace function public.competition_publish(p_competition uuid, p_ties jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c        public.competitions;
  v_ties   jsonb := coalesce(p_ties, '[]'::jsonb);
  v_miss   text;
  v_rows   integer;
  v_sent   integer := 0;
  v_until  date;
  r        record;
  rc       record;
  v_first  text;
  v_title  text;
  v_body   text;
  v_prize  boolean;
  v_pts    text;
begin
  c := public._competition_close_check(p_competition);
  perform 1 from public.competitions where id = p_competition for update;
  if jsonb_typeof(v_ties) <> 'array' then
    raise exception 'p_ties must be a JSON array' using errcode = 'invalid_parameter_value';
  end if;

  -- every unresolved tie needs a decision (both, or a winner from the group)
  select string_agg(format('%s %s', g.division_label, public._competition_ord(g.prize_rank)), ', ') into v_miss
    from (select distinct x.division_id, x.division_label, x.prize_rank
            from public._competition_close_rows(c.id) x where x.tie_unresolved) g
   where not exists (
     select 1 from jsonb_array_elements(v_ties) t
      where t ->> 'division_id' = g.division_id::text
        and (t ->> 'prize_rank')::integer = g.prize_rank
        and (coalesce((t ->> 'both')::boolean, false)
             or exists (select 1 from public._competition_close_rows(c.id) y
                         where y.division_id = g.division_id and y.prize_rank = g.prize_rank
                           and y.tie_unresolved and y.student_id::text = t ->> 'winner')));
  if v_miss is not null then
    raise exception 'unresolved tie: %', v_miss using errcode = 'invalid_parameter_value',
      hint = 'pass a decision in p_ties: {"division_id", "prize_rank", "winner"} or {"division_id", "prize_rank", "both": true}';
  end if;

  -- the snapshot (competition_finalize's shape, with what the frozen board,
  -- the champions and the TV need in the payload)
  delete from public.competition_results
   where competition_id = c.id and period_from = c.starts_on and period_to = c.ends_on;
  insert into public.competition_results
    (competition_id, period_from, period_to, division_id, student_id, points, rank, prize_rank, payload, finalized_at, finalized_by)
  select c.id, c.starts_on, c.ends_on, x.division_id, x.student_id, x.points, x.rank,
         case when x.tie_unresolved and not coalesce((t.d ->> 'both')::boolean, false)
                   and t.d ->> 'winner' is distinct from x.student_id::text
              then x.prize_rank + 1
              else x.prize_rank end,
         jsonb_build_object(
           'display_name', x.display_name, 'audience', x.audience, 'unit_id', x.unit_id,
           'division_label', x.division_label, 'places', x.places,
           'photo_url', x.photo_url, 'belt', x.belt, 'degree', x.degree, 'minor', x.minor,
           'class_points', x.class_points, 'gi_points', x.gi_points, 'nogi_points', x.nogi_points,
           'award_points', x.award_points, 'referral_points', x.referral_points,
           'checkin_points', x.checkin_points,                                    -- 163
           'classes_count', x.classes_count, 'last_scored_on', x.last_scored_on,
           'prize_eligible', x.prize_eligible, 'leaderboard_hidden', x.leaderboard_hidden,
           'tie', case when x.tie_unresolved then t.d end),
         now(), auth.uid()
    from public._competition_close_rows(c.id) x
    left join lateral (select d from jsonb_array_elements(v_ties) d
                        where d ->> 'division_id' = x.division_id::text and (d ->> 'prize_rank')::integer = x.prize_rank
                        limit 1) t on x.tie_unresolved;
  get diagnostics v_rows = row_count;

  v_until := coalesce(c.results_until, (date_trunc('month', c.ends_on) + interval '2 months' - interval '1 day')::date);
  update public.competitions
     set published_at = now(), published_by = auth.uid(), results_until = v_until
   where id = c.id;

  -- notifications: everyone with points (staff none); a kid's go to the kid's
  -- guardians (154's routing). They never block the publish (154's guard).
  begin
    for r in
      select cr.student_id, cr.points, cr.rank, cr.prize_rank,
             cr.payload ->> 'division_label' as label,
             coalesce((cr.payload ->> 'places')::integer, 0) as places,
             coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) as hidden
        from public.competition_results cr
       where cr.competition_id = c.id and cr.period_from = c.starts_on and cr.period_to = c.ends_on
         and cr.points > 0 and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
    loop
      v_prize := r.prize_rank is not null and r.prize_rank <= r.places;
      v_pts   := public._competition_pts(r.points) || case when r.points = 1 then ' point' else ' points' end;
      v_first := public._competition_first_name(r.student_id);
      for rc in select * from public._competition_notify_recipients(r.student_id) loop
        if rc.is_guardian then
          if v_prize then
            v_title := v_first || ' won ' || public._competition_ord(r.prize_rank) || ' prize in the ' || c.name;
          else
            v_title := v_first || ' finished ' || public._competition_ord(r.rank) || ' in the ' || c.name;
          end if;
          v_body := r.label || ', ' || v_pts || '. Well done ' || v_first || '!'
                    || case when r.hidden then ' ' || v_first || ' is hidden on the board, so they show as Anonymous.' else '' end;
        else
          if v_prize then
            v_title := 'You won ' || public._competition_ord(r.prize_rank) || ' prize in the ' || c.name;
            v_body  := r.label || ', ' || v_pts || '. Congratulations, the team will be in touch about your prize.';
          else
            v_title := c.name || ' results';
            v_body  := 'You finished ' || public._competition_ord(r.rank) || ' in ' || r.label || ' with ' || v_pts || '. Thanks for training!';
          end if;
          v_body := v_body || case when r.hidden then ' You''re hidden on the board, so you show as Anonymous.' else '' end;
        end if;
        perform public.create_notification(
          p_user_id             := rc.user_id,
          p_type                := 'competition_result',
          p_title               := v_title,
          p_body                := v_body,
          p_related_entity_type := 'competition_result',
          p_related_entity_id   := r.student_id,
          p_metadata            := jsonb_build_object('competition_id', c.id, 'student_id', r.student_id,
                                                      'rank', r.rank, 'prize_rank', case when v_prize then r.prize_rank end),
          p_check_prefs         := true
        );
        v_sent := v_sent + 1;
      end loop;
    end loop;
  exception when others then
    raise warning '161 publish notify skipped: % (%)', sqlerrm, sqlstate;
  end;

  return jsonb_build_object('rows', v_rows, 'notifications', v_sent, 'results_until', v_until);
end;
$$;

-- 161's text; 163 changes marked (the Cup's bonus number).
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
  v_feed7a   integer := 0;     -- 157: adult items only
  v_feed7k   integer := 0;     -- 160: kids items only
  v_show_bat boolean := false; -- 157: tv_screens.show_battle
  v_cands    jsonb;            -- 157: today's classes (the next class bar's rows)
  v_focus    text;             -- 157: 'kids' / 'adult' / null (everything)
  v_bat_a    boolean;
  v_bat_k    boolean;
  v_cupc     public.competitions;   -- 161: the event that just ended here
  v_cup      jsonb;                 -- 161: its block (provisional / published)
  v_cupscr   text[] := '{}';        -- 161: its screens for this focus
  v_cupw     numeric[] := '{}';
  v_nr       integer;               -- 161: how many race screens lead the playlist
  v_nowm     numeric;          -- 158: now, minutes since midnight
  v_run      jsonb;            -- 158: classes running now
  v_wt       time;             -- 158: the window classes' start (latest start in the window)
  v_win      jsonb;            -- 158: window classes, held ones removed
  v_upnext   jsonb := '[]'::jsonb;  -- 158: one block per audience of the window classes
  v_g        record;
  v_blk      jsonb;
  v_psql     text;             -- 158: who is on a class's list, and their status
  v_state    text;             -- 158: next_class.state
  v_nc       jsonb;            -- 158: the class next_class describes
  v_ncid     uuid;
  v_nct      time;
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
  select s.unit_id, u.name::text, coalesce(s.show_battle, false) into v_unit, v_unit_nm, v_show_bat
    from public.tv_screens s join public.units u on u.id = s.unit_id
   where s.id = p_screen;
  if v_unit is null then
    return null;
  end if;

  -- The board in force (competition_for_date's choice; drafts never).
  select x.* into c
    from public.competitions x
   where x.status = 'active' and x.kind = 'event'
     and p_today between x.starts_on and x.ends_on                  -- 161: the event drives the board only while it runs
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
    v_phase  := 'live';                                              -- 161: no automatic final phase
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

  -- One scoring run: this unit's rows. 159: the battle of both units comes from
  -- the one source, public._competition_battle (158's formula, same p_today).
  with r as materialized (
    select * from public._competition_ranked(c.id, v_from, v_to)
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
              'sid', r.student_id, 'audience', r.audience, 'minor', r.minor, 'rank', r.rank, 'prize_rank', r.prize_rank,
              'name', r.display_name,
              'photo_path', case when r.minor then null else nullif(r.photo_url, '') end,
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
       from (select x.audience, x.unit_name as nm,                                         -- 159
                    jsonb_build_object('unit', x.unit_name, 'here', x.unit_id = v_unit,
                      'active', x.active_students,
                      'classes', x.total_classes,
                      'avg', case when x.active_students = 0 then 0::numeric else round(x.avg_classes, 2) end,
                      'points', x.points,
                      'base', x.base,
                      'per_member', x.per_member) as o
               from public._competition_battle(c.id, v_from, v_to, p_today) x
              where x.unit_name is not null) b)
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
                     'name', v.e ->> 'name', 'audience', v.e ->> 'audience', 'minor', v.e -> 'minor', 'photo_path', v.e -> 'photo_path',
                     'belt', v.e -> 'belt', 'degree', v.e -> 'degree',                 -- 158
                     'key', z.key, 'label', z.label, 'points', z.points, 'date', z.d)
                     order by z.d desc, z.ts desc nulls last, z.key)
                    from (select * from ev order by ev.d desc, ev.ts desc nulls last, ev.key limit 10) z
                    join vis v on v.sid = z.sid), '[]'::jsonb),
         (select count(*) from ev where ev.d >= p_today - 6)::integer,
         (select count(*) from ev join vis v on v.sid = ev.sid
           where ev.d >= p_today - 6 and v.e ->> 'audience' = 'adult')::integer,
         (select count(*) from ev join vis v on v.sid = ev.sid                        -- 160
           where ev.d >= p_today - 6 and v.e ->> 'audience' = 'kids')::integer
    into v_feed, v_feed7, v_feed7a, v_feed7k;

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
                   jsonb_build_object('rank', r.rank, 'name', r.display_name, 'minor', r.minor,
                     'photo_path', case when r.minor then null else nullif(r.photo_url, '') end,
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
    select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) into v_cands from (
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
    ) q;
    -- 158: the class window. running: start <= now < start + duration.
    -- window: start - 30 min <= now < start + 15 min; the latest start wins (every
    -- class with that start). A window class is held while a DIFFERENT running
    -- class has the other audience (Kids vs Adults; All conflicts with nobody).
    v_nowm := extract(epoch from p_now) / 60;
    select coalesce(jsonb_agg(x order by (x ->> 't')::time desc, x ->> 'aud'), '[]'::jsonb) into v_run
      from jsonb_array_elements(v_cands) x
     where extract(epoch from (x ->> 't')::time) / 60 <= v_nowm
       and extract(epoch from (x ->> 't')::time) / 60 + (x ->> 'dur')::integer > v_nowm;
    select max((x ->> 't')::time) into v_wt
      from jsonb_array_elements(v_cands) x
     where extract(epoch from (x ->> 't')::time) / 60 - 30 <= v_nowm
       and extract(epoch from (x ->> 't')::time) / 60 + 15 > v_nowm;
    select coalesce(jsonb_agg(w order by case lower(w ->> 'aud') when 'adults' then 1 when 'kids' then 2 else 3 end,
                                          w ->> 'class_id'), '[]'::jsonb) into v_win
      from jsonb_array_elements(v_cands) w
     where (w ->> 't')::time = v_wt
       and not exists (select 1 from jsonb_array_elements(v_run) r
                        where (r ->> 't')::time <> v_wt
                          and lower(r ->> 'aud') in ('kids', 'adults') and lower(w ->> 'aud') in ('kids', 'adults')
                          and lower(r ->> 'aud') <> lower(w ->> 'aud'));
    -- 158: focus. The running class's audience wins until it ends (Kids -> kids,
    -- Adults -> adult, All or more than one -> everything); else the window
    -- classes'; else everything.
    select case when count(distinct lower(x ->> 'aud')) = 1 and min(lower(x ->> 'aud')) = 'kids'   then 'kids'
                when count(distinct lower(x ->> 'aud')) = 1 and min(lower(x ->> 'aud')) = 'adults' then 'adult' end
      into v_focus
      from jsonb_array_elements(case when jsonb_array_length(v_run) > 0 then v_run else v_win end) x;

    -- 158: who is on a class's list ($1 = its class rows), as the going list
    -- reads them, and their status: 'here' (present; or going and present today
    -- here in a class still running or ended at most 15 minutes before this one
    -- starts), else 'on_the_way'. Here first (latest arrival first), then by name;
    -- 60 at most. The counts are for the whole list.
    v_psql := $q$
      with cls as (
        select (x ->> 'class_id')::uuid as class_id, (x ->> 't')::time as t from jsonb_array_elements($1) x
      ), att as (
        select distinct on (a.student_id)
               a.student_id, a.status::text as status, a.attended_at, c.t as ct,
               public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                       public._competition_minor(s.prog::text)) as name,
               public._competition_minor(s.prog::text) as minor,
               nullif(s.photo_url::text, '') as photo, s.belt::text as belt, coalesce(s.degree::integer, 0) as degree
          from public.attendance a
          join cls c on ((c.class_id is not null and a.class_id = c.class_id)
                         or (c.class_id is null and a.class_id is null and a.unit_id = $3
                             and left(a.class_time::text, 5) = to_char(c.t, 'HH24:MI')))
          join public.students s on s.id = a.student_id
         where a.class_date = $2 and a.status in ('going', 'present') and s.leaderboard_hidden is not true
         order by a.student_id, (a.status = 'present') desc, a.attended_at desc
      ), ppl as (
        select t.*,
               case when t.status = 'present' then 'here'
                    when exists (
                      select 1
                        from public.attendance a2
                        left join public.classes k2 on k2.id = a2.class_id
                       where a2.student_id = t.student_id and a2.class_date = $2 and a2.status = 'present'
                         and a2.unit_id = $3 and a2.class_time::text ~ '^\d{1,2}:\d{2}'
                         and left(a2.class_time::text, 5)::time < t.ct
                         and (extract(epoch from left(a2.class_time::text, 5)::time) / 60
                              + coalesce(k2.duration_minutes,
                                         (select (x ->> 'dur')::integer from jsonb_array_elements($5) x
                                           where x ->> 'class_id' is null
                                             and to_char((x ->> 't')::time, 'HH24:MI') = to_char(left(a2.class_time::text, 5)::time, 'HH24:MI')
                                           limit 1),
                                         60))
                             > least(extract(epoch from $4) / 60, extract(epoch from t.ct) / 60 - 15) - 0.0001
                    ) then 'here'
                    else 'on_the_way' end as st
          from att t
      )
      select jsonb_build_object(
        'here', (select count(*) from ppl where st = 'here'),
        'on_the_way', (select count(*) from ppl where st <> 'here'),
        'people', coalesce((select jsonb_agg(z.o order by z.n) from (
            select jsonb_build_object('name', p.name, 'minor', p.minor,
                     'photo_path', case when p.minor then null else p.photo end,
                     'belt', p.belt, 'degree', p.degree, 'status', p.st) as o,
                   row_number() over (order by (p.st = 'here') desc,
                                               case when p.st = 'here' then p.attended_at end desc nulls last,
                                               p.name, p.student_id) as n
              from ppl p) z where z.n <= 60), '[]'::jsonb))
    $q$;

    -- 158: Up next, one block per audience of the (unheld) window classes
    for v_g in
      select lower(w ->> 'aud') as k, min(w ->> 'aud') as aud, jsonb_agg(w) as cls,
             string_agg(distinct public._tv_class_label(w ->> 'uni', w ->> 'lvl', w ->> 'typ'), ' + ') as label
        from jsonb_array_elements(v_win) w
       group by lower(w ->> 'aud')
       order by case lower(w ->> 'aud') when 'adults' then 1 when 'kids' then 2 else 3 end
    loop
      execute v_psql into v_blk using v_g.cls, p_today, v_unit, p_now, v_cands;
      v_upnext := v_upnext || jsonb_build_array(jsonb_build_object(
        'time', to_char(v_wt, 'HH24:MI'), 'label', v_g.label, 'audience', v_g.aud,
        'starts_at', to_char(v_wt, 'HH24:MI'),
        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way', 'people', v_blk -> 'people'));
    end loop;

    -- 158: the class next_class describes, and its state: 'window' (a window
    -- class), 'on' (a class running, no window class), 'far' (the next class
    -- today, outside its window); none left today: next_class null.
    v_nc := null;
    if jsonb_array_length(v_win) > 0 then
      v_state := 'window'; v_nc := v_win -> 0;
    elsif jsonb_array_length(v_run) > 0 then
      v_state := 'on'; v_nc := v_run -> 0;
    else
      select x into v_nc from jsonb_array_elements(v_cands) x
       where extract(epoch from (x ->> 't')::time) / 60 > v_nowm
       order by (x ->> 't')::time, x ->> 'aud'
       limit 1;
      v_state := 'far';
    end if;
    if v_nc is not null then
      v_ncid := (v_nc ->> 'class_id')::uuid;
      v_nct := (v_nc ->> 't')::time;
      execute v_psql into v_blk using jsonb_build_array(v_nc), p_today, v_unit, p_now, v_cands;
      -- going (the pre-158 key, read by tv.html before 158): only inside the
      -- window or while the class is on, never plans made from home hours ahead
      v_going := '[]'::jsonb;
      if v_state <> 'far' then
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                                 public._competition_minor(s.prog::text)),
                 'kid', public._competition_minor(s.prog::text),      -- 156: minor (tv.html before 156 reads 'kid')
                 'minor', public._competition_minor(s.prog::text),
                 'photo_path', case when public._competition_minor(s.prog::text) then null
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
           and ((v_ncid is not null and a.class_id = v_ncid)
                or (v_ncid is null and a.class_id is null and a.unit_id = v_unit
                    and left(a.class_time::text, 5) = to_char(v_nct, 'HH24:MI')));
      end if;
      v_next := jsonb_build_object(
        'time', to_char(v_nct, 'HH24:MI'), 'duration', (v_nc ->> 'dur')::integer,
        'label', public._tv_class_label(v_nc ->> 'uni', v_nc ->> 'lvl', v_nc ->> 'typ'),
        'uniform', coalesce(v_nc ->> 'uni', case when v_nc ->> 'typ' in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'Gi'
                                                 else 'No-Gi' end),
        'audience', v_nc ->> 'aud',
        'going', v_going,
        'state', v_state,                                                        -- 158
        'opens_at', to_char(v_nct - interval '30 minutes', 'HH24:MI'),           -- 158
        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way');           -- 158
    end if;
  exception when others then
    raise warning '155 tv next_class skipped: % (%)', sqlerrm, sqlstate;
    v_next := null;
    v_focus := null;
    v_upnext := '[]'::jsonb;                                                     -- 158
  end;

  -- 161: the Cup that ended here: provisional until an owner publishes it, then
  -- its champions until results_until (default the last day of the month after
  -- ends_on) or until another event starts here. Kids and adults apart.
  select x.* into v_cupc
    from public.competitions x
   where x.kind = 'event' and x.status <> 'draft' and x.ends_on < p_today
     and exists (select 1 from public.competition_divisions d where d.competition_id = x.id and d.unit_id = v_unit)
     and (x.published_at is null
          or p_today <= coalesce(x.results_until, (date_trunc('month', x.ends_on) + interval '2 months' - interval '1 day')::date))
     and not exists (select 1 from public.competitions y
                      where y.kind = 'event' and y.status <> 'draft' and y.id <> x.id
                        and y.starts_on > x.ends_on and y.starts_on <= p_today
                        and exists (select 1 from public.competition_divisions d2 where d2.competition_id = y.id and d2.unit_id = v_unit))
   order by x.ends_on desc, x.created_at desc
   limit 1;
  if v_cupc.id is not null then
    if v_cupc.published_at is not null then
      select jsonb_build_object(
               'name', v_cupc.name, 'phase', 'published', 'ends_on', v_cupc.ends_on,
               'results_until', coalesce(v_cupc.results_until, (date_trunc('month', v_cupc.ends_on) + interval '2 months' - interval '1 day')::date),
               'adult', jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'adult'))[1], '{}'::jsonb),
                                           'champions', coalesce((array_agg(q.champs) filter (where q.aud = 'adult'))[1], '[]'::jsonb)),
               'kids',  jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'kids'))[1], '{}'::jsonb),
                                           'champions', coalesce((array_agg(q.champs) filter (where q.aud = 'kids'))[1], '[]'::jsonb)))
        into v_cup
        from (select cr.payload ->> 'audience' as aud,
                     jsonb_build_object('classes', coalesce(sum((cr.payload ->> 'classes_count')::integer), 0),
                                        'members', count(*) filter (where cr.points > 0),
                                        'points', coalesce(sum(cr.points), 0),
                                        -- 163: check ins are bonus points too (0 in a snapshot made before 163)
                                        'bonus', coalesce(sum((cr.payload ->> 'award_points')::numeric + (cr.payload ->> 'referral_points')::numeric
                                                              + coalesce((cr.payload ->> 'checkin_points')::numeric, 0)), 0)) as nums,
                     coalesce(jsonb_agg(jsonb_build_object(
                       'place', cr.prize_rank,
                       'anonymous', coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false),
                       'name', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then 'Anonymous' else cr.payload ->> 'display_name' end,
                       'minor', coalesce((cr.payload ->> 'minor')::boolean, false),
                       'photo_path', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false)
                                            or coalesce((cr.payload ->> 'minor')::boolean, false)
                                            or cr.payload ->> 'audience' = 'kids' then null
                                          else nullif(cr.payload ->> 'photo_url', '') end,
                       'belt', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then null else cr.payload ->> 'belt' end,
                       'degree', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then null else (cr.payload ->> 'degree')::integer end,
                       'points', cr.points)
                       order by cr.prize_rank, cr.rank, cr.payload ->> 'display_name')
                       filter (where cr.points > 0 and cr.prize_rank is not null and cr.prize_rank <= coalesce((cr.payload ->> 'places')::integer, 0)), '[]'::jsonb) as champs
                from public.competition_results cr
               where cr.competition_id = v_cupc.id and cr.period_from = v_cupc.starts_on and cr.period_to = v_cupc.ends_on
                 and (cr.payload ->> 'unit_id')::uuid = v_unit
               group by cr.payload ->> 'audience') q;
    else
      select jsonb_build_object(
               'name', v_cupc.name, 'phase', 'provisional', 'ends_on', v_cupc.ends_on, 'results_until', null,
               'adult', jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'adult'))[1], '{}'::jsonb), 'champions', '[]'::jsonb),
               'kids',  jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'kids'))[1], '{}'::jsonb), 'champions', '[]'::jsonb))
        into v_cup
        from (select s.audience as aud,
                     jsonb_build_object('classes', coalesce(sum(s.classes_count), 0),
                                        'members', count(*) filter (where s.points > 0),
                                        'points', coalesce(sum(s.points), 0),
                                        'bonus', coalesce(sum(s.award_points + s.referral_points + s.checkin_points), 0)) as nums   -- 163
                from public._competition_scores(v_cupc.id, v_cupc.starts_on, v_cupc.ends_on) s
               where s.unit_id = v_unit
               group by s.audience) q;
    end if;
    -- its screens, one audience each, following the focus
    foreach v_aud in array array['adult', 'kids'] loop
      continue when (v_focus = 'kids' and v_aud <> 'kids') or (v_focus = 'adult' and v_aud <> 'adult');
      continue when coalesce((v_cup -> v_aud -> 'numbers' ->> 'members')::integer, 0) = 0;
      if v_cup ->> 'phase' = 'published' and jsonb_array_length(v_cup -> v_aud -> 'champions') > 0 then
        v_cupscr := v_cupscr || ('cup_champions_' || v_aud)::text; v_cupw := v_cupw || 1.2;
      end if;
      v_cupscr := v_cupscr || ('cup_over_' || v_aud)::text; v_cupw := v_cupw || 1.2;
    end loop;
  end if;

  -- Playlist: 90 seconds, by importance. The races always; then last month's
  -- winners, the chases, how to score (live only), latest points (if any in the
  -- last 7 days), the battle (both units on the board, someone trained), gi /
  -- no-gi (if any).
  -- 157: a Kids class on now shows only the kids screens (race, chase, how to
  -- score, the kids battle); an Adults class only the adult screens (race,
  -- chase, how to score, adult latest points, the adult battle, gi / no-gi). The
  -- battle only on a screen with show_battle. The seconds always sum to 90.
  -- 158: the battle only when both units have a base (members to divide by)
  v_bat_a := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'adult', '[]'::jsonb)) >= 2
             and not exists (select 1 from jsonb_array_elements(v_battle -> 'adult') x where coalesce((x ->> 'base')::integer, 0) <= 0);
  v_bat_k := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'kids', '[]'::jsonb)) >= 2
             and not exists (select 1 from jsonb_array_elements(v_battle -> 'kids') x where coalesce((x ->> 'base')::integer, 0) <= 0);
  if v_focus = 'kids' then
    v_screens := array['race_kids'];
    v_weights := array[1.5];
    if v_chase -> 'kids' <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text; v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_bat_k then v_screens := v_screens || 'battle_kids'::text; v_weights := v_weights || 1.0; end if;
  elsif v_focus = 'adult' then
    v_screens := array['race_adults'];
    v_weights := array[1.5];
    if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_feed7a > 0 then v_screens := v_screens || 'feed_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_bat_a then v_screens := v_screens || 'battle_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;
  else
    v_screens := array['race_adults', 'race_kids'];
    v_weights := array[1.5, 1.5];
    -- 160: one audience per screen (kids and adults never share one)
    if jsonb_array_length(coalesce(v_last -> 'adult', '[]'::jsonb)) > 0 then v_screens := v_screens || 'last_results_adult'::text; v_weights := v_weights || 1.2; end if;
    if jsonb_array_length(coalesce(v_last -> 'kids', '[]'::jsonb)) > 0 then v_screens := v_screens || 'last_results_kids'::text; v_weights := v_weights || 1.2; end if;
    if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_chase -> 'kids'  <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text;   v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_feed7a > 0 then v_screens := v_screens || 'feed_adults'::text; v_weights := v_weights || 1.0; end if;      -- 160
    if v_feed7k > 0 then v_screens := v_screens || 'feed_kids'::text; v_weights := v_weights || 1.0; end if;        -- 160
    if v_bat_a then v_screens := v_screens || 'battle_adults'::text; v_weights := v_weights || 1.0; end if;         -- 160
    if v_bat_k then v_screens := v_screens || 'battle_kids'::text; v_weights := v_weights || 1.0; end if;           -- 160
    if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;
  end if;

  -- 161: the Cup's screens right after the races
  if array_length(v_cupscr, 1) > 0 then
    v_nr := (select count(*) from unnest(v_screens) x where x like 'race\_%');
    v_screens := v_screens[1:v_nr] || v_cupscr || v_screens[v_nr + 1:];
    v_weights := v_weights[1:v_nr] || v_cupw || v_weights[v_nr + 1:];
  end if;

  -- 158: Up next first, one screen per block (weight 1.2)
  if jsonb_array_length(v_upnext) > 0 then
    v_screens := array(select 'up_next_' || case lower(b ->> 'audience') when 'kids' then 'kids' when 'all' then 'all' else 'adult' end
                         from jsonb_array_elements(v_upnext) with ordinality u(b, o) order by o) || v_screens;
    v_weights := array(select 1.2::numeric from jsonb_array_elements(v_upnext)) || v_weights;
  end if;

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
    'up_next', v_upnext,                                                         -- 158
    'cup', v_cup,                                                                -- 161
    'playlist', v_play);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The Christmas Cup gets the rule (not the monthly race). Idempotent: a
--    re-run never re-enables it after an owner switched it off.
-- ---------------------------------------------------------------------------
insert into public.competition_rules (competition_id, rule_key, points, enabled)
values ('672e130e-ef51-42d4-916d-61593f88515c', 'self_checkin', 1, true)
on conflict (competition_id, rule_key) do nothing;

commit;
