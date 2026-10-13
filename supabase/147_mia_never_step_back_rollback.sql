-- 147_mia_never_step_back_rollback.sql
--
-- Undo 147: re-apply 146's mia_email_candidates exactly (146's text). Drops no data.

begin;

create or replace function public.mia_email_candidates(p_now timestamptz)
returns table (
  student_id       uuid,
  code             text,          -- 'M1','M2','M3','M4','T4','R'
  due_at           timestamptz,
  period_key       text,          -- '<student_id>:<episode anchor>:<code>' (146: anchor = latest of last class, resume day, conversion day)
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
           s.parent2_email::text as parent2_email, s.parent2_phone::text as parent2_phone,
           -- 146: the Sydney day this member came off hold / was reactivated,
           -- and the Sydney day a trial was converted into this member
           (s.mia_resume_at at time zone 'Australia/Sydney')::date as resume_date,
           (s.converted_at  at time zone 'Australia/Sydney')::date as conv_date
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
  ep as (
    -- 146: the absence ANCHOR of each gap: the latest of its last class, the
    -- resume day (off hold / reactivated) and the conversion day (trial ->
    -- member), each day counting only when it falls after the class and before
    -- the next one. So coming back from a hold, or becoming a member weeks after
    -- the trial class, starts a NEW episode: the clock, the due dates and the
    -- period_key all start at that day (fresh M1 first).
    select q.student_id, q.class_date, q.next_date,
           greatest(q.class_date,
                    case when e.resume_date > q.class_date and (q.next_date is null or e.resume_date < q.next_date)
                         then e.resume_date end,
                    case when e.conv_date > q.class_date and (q.next_date is null or e.conv_date < q.next_date)
                         then e.conv_date end) as anchor
      from seq q
      join elig e on e.id = q.student_id
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
    -- 146: from the episode anchor (= the last class unless a resume came later)
    select q.student_id, k.code, q.anchor as ep_date,
           ((q.anchor + k.k + st.settle_days) + time '15:00') at time zone 'Australia/Sydney' as due_at,
           k.seq, q.class_date as last_date
      from ep q
     cross join codes k
     cross join settings st
     where q.next_date is null
       and not exists (select 1 from public.students s join held_units h on h.unit_id = s.unit_id
                        where s.id = q.student_id)
    union all
    -- R: the day after the class that ended an absence whose M1 was sent
    -- e. ...or the day that class's card was entered, if later.
    select q.student_id, 'R', q.anchor,
           (greatest(q.next_date + 1, coalesce(rc.conf_date, q.next_date + 1)) + time '15:00') at time zone 'Australia/Sydney',
           null::integer, q.class_date
      from ep q
      left join lateral (
        select min((a.confirmed_at at time zone 'Australia/Sydney')::date) as conf_date
          from public.attendance a
         where a.student_id = q.student_id and a.status = 'present' and a.class_date = q.next_date
      ) rc on true
     where q.next_date is not null
       and exists (select 1 from public.email_sends es
                    where es.kind = 'mia' and es.status = 'sent'
                      and es.period_key = q.student_id::text || ':' || q.anchor::text || ':M1')   -- 146: the anchored episode's M1
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
    select l.student_id, l.code, l.ep_date, l.due_at, rc.email::text as recipient, rc.display_name::text as recipient_name, l.last_date
      from live l
     cross join lateral public.email_recipients_for_student(l.student_id, 'mia') rc
     where l.code <> 'T4'
    union all
    select l.student_id, l.code, l.ep_date, l.due_at, 'info@mybjj.com.au', null, l.last_date
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
         a.last_date,                                   -- 146: the real last class (T4 shows it as "Last class")
         ((select d from today) - a.last_date)::integer,  -- and days since it ("Days since last class")
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
