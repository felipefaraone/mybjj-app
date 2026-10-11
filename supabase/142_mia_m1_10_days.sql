-- ============================================================================
-- 142 — MIA emails: M1 at 10 days since the last class (was 7)
-- ============================================================================
--
-- WHY (12 Oct 2026)
-- The academy asks for M1 at 10 days. Members who train once or twice a week
-- and change their training day go 8 or 9 days between classes, and got an M1
-- ("Haven’t seen you this week") they should not have.
--
-- WHAT
-- public.mia_email_candidates: ('M1', 7) -> ('M1', 10). Nothing else: M2 14,
-- M3 21, M4 30, T4 30 and R, the 15:00 Sydney send time and the 2-day
-- lateness window are unchanged. Same signature and return table, so
-- CREATE OR REPLACE keeps the function's grants (repeated below as in 140).
--
-- SAFETY
-- period_key is '<student_id>:<last class date>:M1'. A member whose M1 already
-- went out at 7 days has a 'sent' row for that key, so the candidates query
-- never offers it again at 10 days. A member at 7, 8 or 9 days with no M1 yet
-- simply gets it at 10.
--
-- Rollback: 142_mia_m1_10_days_rollback.sql (140's function, M1 at 7).
-- Checks: 142_mia_m1_10_days_verify.sql.
-- ============================================================================

begin;

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
    values ('M1', 10), ('M2', 14), ('M3', 21), ('M4', 30), ('T4', 30)
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
