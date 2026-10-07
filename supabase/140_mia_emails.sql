-- ============================================================================
-- 140 — MIA ("missing in action") emails: the list of MIA emails due now
-- ============================================================================
--
-- WHY
-- The head instructor wrote an MIA sequence for members who stop training
-- (document: "myBJJ MIA Member Email Sequence"):
--   M1  7 days since the last class        M3  21 days
--   M2  14 days                            M4  30 days
--   T4  a note to the team (info@mybjj.com.au) sent with M4
--   R   "great to have you back", the day after they attend again
-- All at 15:00 Sydney on the day it falls due (the morning's attendance is in
-- by then). Nothing here sends or schedules: the mia-emails Edge Function reads
-- mia_email_candidates() and logs every attempt in email_sends (kind 'mia',
-- allowed since 137).
--
-- RULES (all in the function below)
--   Eligible: active, standing not 'on_hold', at least one 'present' attendance
--     ever, NOT a visitor or casual tier, and NOT staff.
--     Visitors / casual: membership_level starting 'visitor_' or 'casual_' — today
--     exactly visitor_other_gym, visitor_unaffiliated, casual_dropin and
--     casual_member (index.html _MEMBERSHIP_LABELS; the same four the app counts
--     as non-members, _MEMBERSHIP_NON_MEMBER). One switch: rules.exclude_visitors_and_casual.
--     Staff, as this database models it:
--       - the linked account (students.user_id) has users.role instructor /
--         admin / owner (is_staff() checks role = 'instructor'; 32 migrated
--         'owner' to 'instructor'),
--       - or that account owns a unit (unit_owners, or the legacy
--         units.owner_user_id that is_unit_owner_any() still honours),
--       - or that account has an active staff row (staff.user_id),
--       - or, for ADULTS only, the student's own email is an active staff row's
--         email or the email of one of those accounts. (Not for kids: a child's
--         record often carries a parent's address, and a staff member's child
--         is still a member.)
--   Days since the last class: Sydney calendar days since the most recent
--     'present' attendance (class_date, never in the future).
--   Episode: (student, last class date). Its emails are M1..M4/T4; the moment
--     a newer 'present' row exists the latest date changes, the old episode is
--     no longer current, and none of its emails can come due again.
--   Late: an email more than 2 days past its 15:00 is skipped for good. That
--     also means the launch sends nothing for long absences (45 days absent:
--     M4 was due 15 days ago).
--   R: due at 15:00 the day after the first class that ended an absence, and
--     only when that absence's M1 was actually sent. Once per episode.
--   Member emails go to email_recipients_for_student(id, 'mia'): an adult's own
--     address (or account address); for a kid, the active AND pending
--     guardians, never the kid's own address; opt-outs 'all' and 'mia' removed.
--   T4 goes to info@mybjj.com.au and ignores member opt-outs. For a kid it
--     carries the guardians (name, email, phone when known) in `parents`. It also
--     carries what the member actually got: `sent_codes` (M1..M4 with a 'sent'
--     row for this episode) and `member_reach` ('reachable' / 'opted_out' /
--     'no_address') for the "Automated emails sent: …" line.
--
-- period_key = '<student_id>:<last class date>:<code>', e.g. '…:2026-09-01:M2'
-- (R is keyed by the absence it closes). IDEMPOTENCY: 137's unique key
-- (kind, period_key, student_id, recipient_email) already makes each email once
-- per key and address, because MIA rows ALWAYS carry the student_id (it is in
-- the key, and the function always writes it). 139 needed a partial index only
-- because trial rows have no student and NULLs never collide. No new index.
--
-- Closed to clients; service_role only. Text columns cast at the source
-- (auth.users.email is varchar). NULL-safe throughout.
--
-- Rollback: 140_mia_emails_rollback.sql. Checks: 140_mia_emails_verify.sql.
-- ============================================================================

begin;

-- The return type changed during review (sent_codes, member_reach); drop first so
-- a re-run replaces it. Nothing else depends on it.
drop function if exists public.mia_email_candidates(timestamptz);

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
  codes(code, k) as (
    values ('M1', 7), ('M2', 14), ('M3', 21), ('M4', 30), ('T4', 30)
  ),
  due as (
    -- the CURRENT episode only: the latest present date
    select q.student_id, k.code, q.class_date as ep_date,
           ((q.class_date + k.k) + time '15:00') at time zone 'Australia/Sydney' as due_at
      from seq q
     cross join codes k
     where q.next_date is null
    union all
    -- R: the day after the class that ended an absence whose M1 was sent
    select q.student_id, 'R', q.class_date,
           ((q.next_date + 1) + time '15:00') at time zone 'Australia/Sydney'
      from seq q
     where q.next_date is not null
       and exists (select 1 from public.email_sends es
                    where es.kind = 'mia' and es.status = 'sent'
                      and es.period_key = q.student_id::text || ':' || q.class_date::text || ':M1')
  ),
  live as (
    select d.* from due d
     where d.due_at <= p_now
       and d.due_at >= p_now - interval '2 days'           -- never more than 2 days late
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
