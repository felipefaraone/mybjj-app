-- ============================================================================
-- 143 — MIA emails: settle before sending, hold a unit whose cards are late,
--       one table for every MIA number
-- ============================================================================
--
-- WHY (measured in production, 12 Oct 2026)
-- Attendance is entered late. attendance.confirmed_at (when the card was entered;
-- attended_at / checked_in_at are not that, they can precede the class) against
-- class_date over 28 days: same day 75%, +1 day 17%, +2 days 5%, +3 to +5 days 3%.
-- Of 106 M1 emails sent, 28 went to members who HAD trained between their last
-- recorded class and the send date: their card was entered after the email.
-- 5 to 11 Oct has 401 present rows against a normal 500 to 530 (cards still
-- pending, the office manager on leave). And 142's "skip if more than 2 days
-- late" would drop any email a hold delays.
--
-- WHAT (public.mia_email_candidates keeps its signature and return table, so the
-- deployed mia-emails function keeps working unchanged)
--   1. public.mia_codes (code, days, seq): M1 10/1, M2 14/2, M3 21/3, M4 30/4,
--      T4 30/4 — the schedule, read by the function (no more VALUES list).
--      public.mia_settings (one row): settle_days 2, gate_lookback_days 3,
--      gate_min_ratio 0.5, gate_baseline_weeks 6, max_late_days 7.
--   2. a. codes come from mia_codes.
--      b. SETTLE: M/T codes are due at 15:00 Sydney on last class + days +
--         settle_days. The absence threshold is still `days`; the send waits so
--         late cards land first. A card that lands makes the episode
--         non-current, which cancels its emails by construction.
--      c. UNIT GATE (public.mia_unit_holds): a unit is HELD while, on any of
--         the last gate_lookback_days completed Sydney days, its present rows
--         (attendance.unit_id, status 'present') are below gate_min_ratio x the
--         median for that weekday over the previous gate_baseline_weeks weeks. A
--         weekday whose median is 0 never holds. While held: no M1-M4 / T4 for
--         students of that unit (students.unit_id). R is not gated.
--      d. LATENESS: an M/T row is returned while due_at <= now, it is at most
--         max_late_days late, and no code of the same episode with a higher seq
--         is due yet (T4 and M4 share seq 4 and go together). A held M1 still
--         goes after the hold if M2 is not due — never together with M2.
--      e. R: due at 15:00 on the later of (return class + 1) and the Sydney day
--         that return's card was entered (confirmed_at; NULL = return + 1).
--         Its 2-day window and "M1 actually sent" condition are unchanged.
--      f. everything else exactly as 142.
--
-- TUNING (no migration needed)
--   update public.mia_codes    set days = 12 where code = 'M1';
--   update public.mia_settings set settle_days = 3;
--   update public.mia_settings set gate_min_ratio = 0.6, gate_lookback_days = 4;
-- The Edge Function reads mia_codes for the team email's "Automated emails sent"
-- line, so the days stay right after a change.
--
-- Rollback: 143_mia_settle_and_gate_rollback.sql. Checks: 143_mia_settle_and_gate_verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Configuration: one source of truth for every MIA number
-- ---------------------------------------------------------------------------
create table if not exists public.mia_codes (
  code text primary key check (code in ('M1', 'M2', 'M3', 'M4', 'T4')),
  days integer not null check (days > 0),
  seq  integer not null
);
comment on table public.mia_codes is
  'MIA email schedule (143): days since the last class at which each code becomes due (plus mia_settings.settle_days), and its order. M4 and T4 share seq 4.';
insert into public.mia_codes (code, days, seq) values
  ('M1', 10, 1), ('M2', 14, 2), ('M3', 21, 3), ('M4', 30, 4), ('T4', 30, 4)
on conflict (code) do nothing;                                   -- a re-run never undoes tuning

create table if not exists public.mia_settings (
  id                  boolean primary key default true check (id),
  settle_days         integer not null default 2,
  gate_lookback_days  integer not null default 3,
  gate_min_ratio      numeric not null default 0.5,
  gate_baseline_weeks integer not null default 6,
  max_late_days       integer not null default 7
);
comment on table public.mia_settings is
  'MIA email settings (143), one row: settle_days, the unit gate (lookback days, minimum ratio to the weekday median, baseline weeks) and max_late_days.';
insert into public.mia_settings (id) values (true) on conflict (id) do nothing;

alter table public.mia_codes    enable row level security;
alter table public.mia_settings enable row level security;
-- No policies: clients have no access at all. The Edge Function reads
-- mia_codes with the service role.
revoke all on public.mia_codes, public.mia_settings from public, anon, authenticated;
grant select on public.mia_codes, public.mia_settings to service_role;

-- ---------------------------------------------------------------------------
-- 2c. The unit gate, as its own function so the verify dry run shows exactly
--     the rule the candidates use. One row per unit and lookback day:
--     present_rows that day, the weekday median over the baseline weeks
--     (missing days count as 0), whether that day holds, whether the unit is held.
-- ---------------------------------------------------------------------------
create or replace function public.mia_unit_holds(p_now timestamptz)
returns table (
  unit_id      uuid,
  unit_name    text,
  day          date,
  present_rows integer,
  baseline     numeric,
  day_holds    boolean,
  unit_held    boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with st as (
    select s.gate_lookback_days as lb, s.gate_min_ratio as ratio, s.gate_baseline_weeks as wk
      from public.mia_settings s where s.id
  ),
  days as (
    -- the last `lb` COMPLETED Sydney days: yesterday back
    select ((p_now at time zone 'Australia/Sydney')::date - g)::date as day
      from st cross join generate_series(1, st.lb) g
  ),
  counts as (
    select a.unit_id, a.class_date, count(*)::integer as n
      from public.attendance a
     where a.status = 'present'
       and a.unit_id is not null
       and a.class_date >= (select min(d.day) from days d) - 7 * (select st.wk from st)
       and a.class_date <= (select max(d.day) from days d)
     group by a.unit_id, a.class_date
  ),
  grid as (
    select u.id as unit_id, u.name::text as unit_name, d.day,
           coalesce((select c.n from counts c where c.unit_id = u.id and c.class_date = d.day), 0) as present_rows,
           (select percentile_cont(0.5) within group (order by coalesce(c2.n, 0))
              from st cross join generate_series(1, st.wk) k
              left join counts c2 on c2.unit_id = u.id and c2.class_date = d.day - 7 * k)::numeric as baseline
      from public.units u
     cross join days d
  )
  select g.unit_id, g.unit_name, g.day, g.present_rows, g.baseline,
         (g.baseline > 0 and g.present_rows < (select st.ratio from st) * g.baseline) as day_holds,
         bool_or(g.baseline > 0 and g.present_rows < (select st.ratio from st) * g.baseline)
           over (partition by g.unit_id) as unit_held
    from grid g
   order by g.unit_name, g.unit_id, g.day desc
$$;

revoke all on function public.mia_unit_holds(timestamptz) from public, anon, authenticated;
grant execute on function public.mia_unit_holds(timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 2. The candidates (same signature and return table as 140 / 142)
-- ---------------------------------------------------------------------------
create or replace function public.mia_email_candidates(p_now timestamptz)
returns table (
  student_id       uuid,
  code             text,          -- 'M1','M2','M3','M4','T4','R'
  due_at           timestamptz,
  period_key       text,          -- '<student_id>:<last class date>:<code>'
  recipient        text,          -- lowercased; 'info@mybjj.com.au' for T4
  recipient_name   text,          -- the guardian's or member's name when known
  is_kid           boolean,
  first_name       text,          -- the student's
  last_name        text,
  membership_level text,          -- students.membership_level as stored (NULL = full member)
  unit_name        text,
  unit_legacy_id   text,
  unit_address     text,
  unit_phone       text,
  last_class_date  date,          -- the episode's last class
  days_absent      integer,       -- Sydney days from that class to p_now
  parents          jsonb,         -- T4 for a kid: [{name,email,phone}], else NULL
  sent_codes       text[],        -- T4: the member emails (M1..M4) sent for this episode, else NULL
  member_reach     text,          -- T4: 'reachable' / 'opted_out' / 'no_address', else NULL
  attempt_status   text           -- 'failed' when a previous attempt failed, else NULL
)
language sql
stable
security definer
set search_path = public
as $$
  with rules as (
    -- The one switch for who is NOT chased. true: visitors and casual tiers
    -- (membership_level 'visitor_*' / 'casual_*') get no MIA emails, not even T4.
    select true as exclude_visitors_and_casual
  ),
  today as (
    select (p_now at time zone 'Australia/Sydney')::date as d
  ),
  settings as (
    -- every MIA number lives in public.mia_settings / public.mia_codes (143)
    select s.settle_days, s.max_late_days from public.mia_settings s where s.id
  ),
  held_units as (
    -- c. units whose recent attendance looks un-entered: no M1-M4 / T4 for
    -- their students while held. Same helper the verify dry run shows.
    select distinct h.unit_id from public.mia_unit_holds(p_now) h where h.unit_held
  ),
  staff_ids as (
    select u.id as user_id from public.users u where u.role::text in ('instructor', 'admin', 'owner')
    union select uo.user_id from public.unit_owners uo where uo.user_id is not null
    union select un.owner_user_id from public.units un where un.owner_user_id is not null
    union select st.user_id from public.staff st where st.user_id is not null and st.active is not false
  ),
  staff_emails as (
    select nullif(lower(btrim(st.email::text)), '') as email from public.staff st where st.active is not false
    union select nullif(lower(btrim(u.email::text)), '') from public.users u join staff_ids x on x.user_id = u.id
    union select nullif(lower(btrim(au.email::text)), '') from auth.users au join staff_ids x on x.user_id = au.id
  ),
  elig as (
    select s.id, coalesce(s.prog::text = 'kids', false) as is_kid, s.unit_id,
           coalesce(nullif(btrim(s.first_name::text), ''), split_part(btrim(coalesce(s.full_name::text, '')), ' ', 1)) as first_name,
           coalesce(nullif(btrim(s.last_name::text), ''),
                    nullif(btrim(substr(btrim(coalesce(s.full_name::text, '')),
                                        length(split_part(btrim(coalesce(s.full_name::text, '')), ' ', 1)) + 1)), '')) as last_name,
           nullif(btrim(s.membership_level::text), '') as membership_level,
           s.email::text as own_email, s.parent_email::text as parent_email, s.parent_phone::text as parent_phone,
           s.parent2_email::text as parent2_email, s.parent2_phone::text as parent2_phone
      from public.students s
     where s.active is true
       and s.standing is distinct from 'on_hold'
       and not ((select r.exclude_visitors_and_casual from rules r)
                and coalesce(s.membership_level::text, '') ~ '^(visitor_|casual_)')
       and not (s.user_id is not null and exists (select 1 from staff_ids x where x.user_id = s.user_id))
       and not (coalesce(s.prog::text, 'adult') <> 'kids'
                and exists (select 1 from staff_emails x where x.email = nullif(lower(btrim(s.email::text)), '')))
  ),
  pres as (
    -- distinct 'present' class dates, never in the future
    select distinct a.student_id, a.class_date
      from public.attendance a
      join elig e on e.id = a.student_id
      cross join today t
     where a.status = 'present'
       and a.class_date is not null
       and a.class_date <= t.d
  ),
  seq as (
    select p.student_id, p.class_date,
           lead(p.class_date) over (partition by p.student_id order by p.class_date) as next_date
      from pres p
  ),
  codes as (
    -- a. the schedule: public.mia_codes (code, days, seq)
    select c.code, c.days as k, c.seq from public.mia_codes c
  ),
  due as (
    -- the CURRENT episode only: the latest present date
    -- b. due `settle_days` after the threshold day, so late cards can land first
    --    (a card that lands makes the episode non-current: the email is gone).
    -- c. nothing for a student whose unit is held.
    select q.student_id, k.code, q.class_date as ep_date,
           ((q.class_date + k.k + st.settle_days) + time '15:00') at time zone 'Australia/Sydney' as due_at,
           k.seq
      from seq q
     cross join codes k
     cross join settings st
     where q.next_date is null
       and not exists (select 1 from public.students s join held_units h on h.unit_id = s.unit_id
                        where s.id = q.student_id)
    union all
    -- R: the day after the class that ended an absence whose M1 was sent
    -- e. ...or the day that class's card was entered, if later.
    select q.student_id, 'R', q.class_date,
           (greatest(q.next_date + 1, coalesce(rc.conf_date, q.next_date + 1)) + time '15:00') at time zone 'Australia/Sydney',
           null::integer
      from seq q
      left join lateral (
        select min((a.confirmed_at at time zone 'Australia/Sydney')::date) as conf_date
          from public.attendance a
         where a.student_id = q.student_id and a.status = 'present' and a.class_date = q.next_date
      ) rc on true
     where q.next_date is not null
       and exists (select 1 from public.email_sends es
                    where es.kind = 'mia' and es.status = 'sent'
                      and es.period_key = q.student_id::text || ':' || q.class_date::text || ':M1')
  ),
  live as (
    select d.* from due d
     where d.due_at <= p_now
       and case when d.code = 'R'
                then d.due_at >= p_now - interval '2 days'           -- R: never more than 2 days late (unchanged)
                -- d. M/T: at most max_late_days late, and never once a later code
                --    of the same episode is due (T4 and M4 share seq 4: together).
                else d.due_at >= p_now - make_interval(days => (select st.max_late_days from settings st))
                     and not exists (select 1 from due d2
                                      where d2.student_id = d.student_id and d2.ep_date = d.ep_date
                                        and d2.code <> 'R' and d2.seq > d.seq and d2.due_at <= p_now)
           end
  ),
  addressed as (
    select l.student_id, l.code, l.ep_date, l.due_at, rc.email::text as recipient, rc.display_name::text as recipient_name
      from live l
     cross join lateral public.email_recipients_for_student(l.student_id, 'mia') rc
     where l.code <> 'T4'
    union all
    select l.student_id, l.code, l.ep_date, l.due_at, 'info@mybjj.com.au', null
      from live l
     where l.code = 'T4'
  )
  select a.student_id,
         a.code::text,
         a.due_at,
         (a.student_id::text || ':' || a.ep_date::text || ':' || a.code)::text,
         lower(btrim(a.recipient))::text,
         nullif(btrim(a.recipient_name), '')::text,
         e.is_kid,
         nullif(e.first_name, '')::text,
         e.last_name::text,
         e.membership_level::text,
         u.name::text,
         lower(u.legacy_id::text)::text,
         nullif(btrim(u.address::text), '')::text,
         nullif(btrim(u.phone::text), '')::text,
         a.ep_date,
         ((select d from today) - a.ep_date)::integer,
         case when a.code = 'T4' and e.is_kid then (
           select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email, 'phone', p.phone)
                                     order by p.name nulls last, p.email), '[]'::jsonb)
             from (
               -- phone: the guardian's own student record, else the legacy
               -- parent_phone / parent2_phone whose email matches (guardianships
               -- has no phone column, 133). Plain "=": no email never matches.
               select coalesce(nullif(btrim(pu.full_name::text), ''), nullif(btrim(gs.full_name::text), ''),
                               nullif(btrim(g.guardian_name::text), '')) as name,
                      ge.email,
                      coalesce(nullif(btrim(gs.phone::text), ''),
                               case when ge.email = nullif(lower(btrim(e.parent_email)), '')  then nullif(btrim(e.parent_phone), '')
                                    when ge.email = nullif(lower(btrim(e.parent2_email)), '') then nullif(btrim(e.parent2_phone), '')
                               end) as phone
                 from public.guardianships g
                 left join auth.users au      on au.id = g.guardian_user_id
                 left join public.users pu    on pu.id = g.guardian_user_id
                 left join public.students gs on gs.id = g.guardian_student_id
                cross join lateral (
                  select nullif(lower(btrim(case when g.status = 'active' then coalesce(au.email::text, pu.email::text)
                                                 else g.invite_email::text end)), '') as email
                ) ge
                where g.student_id = a.student_id
                  and g.status in ('active', 'pending')
             ) p
         ) end,
         -- T4: which member emails this episode actually got (any recipient).
         case when a.code = 'T4' then array(
           select distinct split_part(es.period_key, ':', 3)
             from public.email_sends es
            where es.kind = 'mia' and es.status = 'sent' and es.student_id = a.student_id
              and es.period_key like a.student_id::text || ':' || a.ep_date::text || ':M_'
            order by 1
         ) end,
         -- T4: can the member be emailed at all? 'opted_out' when an address of
         -- theirs (the same sources as email_recipients_for_student, 138) has an
         -- 'all' / 'mia' opt-out; 'no_address' when there is none.
         case when a.code = 'T4' then
           case when exists (select 1 from public.email_recipients_for_student(a.student_id, 'mia')) then 'reachable'
                when exists (
                  select 1
                    from (
                      select st.email::text as em from public.students st where st.id = a.student_id and not e.is_kid
                      union all select pu.email::text from public.students st join public.users pu on pu.id = st.user_id
                                 where st.id = a.student_id and not e.is_kid
                      union all select au.email::text from public.students st join auth.users au on au.id = st.user_id
                                 where st.id = a.student_id and not e.is_kid
                      union all select case when g.status = 'active' then coalesce(au.email::text, pu.email::text)
                                            else g.invite_email::text end
                                  from public.guardianships g
                                  left join auth.users au   on au.id = g.guardian_user_id
                                  left join public.users pu on pu.id = g.guardian_user_id
                                 where g.student_id = a.student_id and g.status in ('active', 'pending') and e.is_kid
                    ) ad
                    join public.email_optouts o
                      on lower(o.email::text) = nullif(lower(btrim(ad.em)), '')
                     and o.kind in ('all', 'mia'))
                then 'opted_out'
                else 'no_address'
           end
         end,
         (select es.status::text from public.email_sends es
           where es.kind = 'mia'
             and es.period_key = a.student_id::text || ':' || a.ep_date::text || ':' || a.code
             and lower(es.recipient_email::text) = lower(btrim(a.recipient))
             and es.status = 'failed'
           limit 1)
    from addressed a
    join elig e on e.id = a.student_id
    left join public.units u on u.id = e.unit_id
   where a.recipient is not null
     and not exists (select 1 from public.email_sends es
                      where es.kind = 'mia'
                        and es.period_key = a.student_id::text || ':' || a.ep_date::text || ':' || a.code
                        and lower(es.recipient_email::text) = lower(btrim(a.recipient))
                        and es.status in ('sent', 'skipped'))
   order by a.due_at, a.student_id, a.code, lower(btrim(a.recipient))
$$;

revoke all on function public.mia_email_candidates(timestamptz) from public, anon, authenticated;
grant execute on function public.mia_email_candidates(timestamptz) to service_role;

commit;
