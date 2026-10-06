-- ============================================================================
-- 137 — Engagement emails: send log, opt-outs, and the two data functions
-- ============================================================================
--
-- WHY
-- The head instructor wants automated emails in the academy's name: a monthly
-- training recap now, a missing-in-action email later. This is the ENGINE's data
-- layer only. Nothing here sends, schedules or triggers anything: the
-- engagement-emails Edge Function reads these functions and writes the log, and
-- it only sends when called with send:true.
--
-- OBJECTS
--  email_sends    one row per (kind, period, student, recipient) attempt: the
--                 idempotency key that lets a capped send continue the next day.
--  email_optouts  addresses that asked to stop (one kind, or 'all').
--  training_count(student, from, to)
--                 THE SAME rule as the app's Progress "how many classes in month
--                 X" (_progMonthCounts in index.html): one per attendance row with
--                 status 'present' whose class_date is in the range. class_value
--                 is NOT weighted, a private lesson is a row like any other, and
--                 two classes on one day count as two. (students.total — the
--                 promotion counter — is a different number: SUM(class_value).)
--  email_recipients_for_student(student, kind)
--                 who gets a student's email: an adult's own address; a kid's
--                 active (account email) and pending (invite email) guardians,
--                 never the kid's own address. Lowercased, trimmed, deduplicated,
--                 opt-outs ('all' or this kind) removed.
--  monthly_recap_candidates(from, to)
--                 one row per eligible student x recipient (or one row with a
--                 null email when the student has nobody to send to), built on
--                 the two functions above, so the Edge Function makes one call
--                 instead of two per student. Eligible = active and not on hold.
--
-- All three functions are SECURITY DEFINER with EXECUTE revoked from client
-- roles: only the service role (the Edge Functions) calls them. Every returned
-- text column is cast ::text at its source (the 135 lesson: auth.users.email is
-- varchar(255) in Supabase, and RETURNS TABLE checks types, not values).
--
-- Rollback: 137_engagement_emails_rollback.sql. Checks: 137_engagement_emails_verify.sql.
-- ============================================================================

begin;

-- citext lives in the extensions schema (133 created it there). Abort rather
-- than guess if that ever changes.
do $$
declare v_schema text;
begin
  select n.nspname into v_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'citext';
  if v_schema is distinct from 'extensions' then
    raise exception '137 preflight: citext is in schema %, expected extensions (migration 133)', v_schema;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Send log
-- ---------------------------------------------------------------------------
create table if not exists public.email_sends (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('monthly_recap','mia')),
  period_key      text not null,                -- e.g. '2026-10' for a recap
  student_id      uuid references public.students(id) on delete set null,
  recipient_email extensions.citext not null,
  status          text not null check (status in ('sent','failed','skipped')),
  error           text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,
  constraint email_sends_once unique (kind, period_key, student_id, recipient_email)
);
create index if not exists email_sends_kind_period_idx on public.email_sends (kind, period_key);

alter table public.email_sends enable row level security;
drop policy if exists email_sends_staff_read on public.email_sends;
create policy email_sends_staff_read on public.email_sends
  as permissive for select to authenticated
  using (public.is_staff() or public.is_admin());
-- No insert/update/delete policy, and no write privilege: only the service role writes.
revoke all on public.email_sends from public, anon, authenticated;
grant select on public.email_sends to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Opt-outs
-- ---------------------------------------------------------------------------
create table if not exists public.email_optouts (
  email      extensions.citext not null,
  kind       text not null check (kind in ('all','monthly_recap','mia')),
  created_at timestamptz not null default now(),
  constraint email_optouts_once unique (email, kind)
);

alter table public.email_optouts enable row level security;
-- No policies and no privileges: no client access at all.
revoke all on public.email_optouts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. training_count — the app's rule (see header)
-- ---------------------------------------------------------------------------
create or replace function public.training_count(p_student uuid, p_from date, p_to date)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
    from public.attendance a
   where a.student_id = p_student
     and a.status = 'present'
     and a.class_date between p_from and p_to
$$;

-- ---------------------------------------------------------------------------
-- 4. email_recipients_for_student
-- ---------------------------------------------------------------------------
create or replace function public.email_recipients_for_student(p_student uuid, p_kind text)
returns table (email text, display_name text, is_guardian boolean)
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select st.id, st.prog::text as prog, st.user_id,
           nullif(lower(btrim(st.email::text)), '') as own_email,
           coalesce(nullif(btrim(st.first_name::text), ''), split_part(btrim(coalesce(st.full_name::text, '')), ' ', 1)) as first_name
      from public.students st
     where st.id = p_student
  ),
  cand as (
    -- Adult: their own address, else the linked account's.
    select nullif(lower(btrim(coalesce(s.own_email, pu.email::text, au.email::text))), '') as email,
           nullif(s.first_name, '') as display_name,
           false as is_guardian
      from s
      left join public.users pu on pu.id = s.user_id
      left join auth.users au   on au.id = s.user_id
     where coalesce(s.prog, 'adult') <> 'kids'
    union all
    -- Kid: guardians only. Active -> the account's address; pending -> the invite.
    select nullif(lower(btrim(case when g.status = 'active'
                                   then coalesce(au.email::text, pu.email::text)
                                   else g.invite_email::text end)), '') as email,
           coalesce(nullif(btrim(pu.full_name::text), ''),
                    nullif(btrim(gs.full_name::text), ''),
                    nullif(btrim(g.guardian_name::text), '')) as display_name,
           true as is_guardian
      from s
      join public.guardianships g   on g.student_id = s.id and g.status in ('active','pending')
      left join auth.users au       on au.id = g.guardian_user_id
      left join public.users pu     on pu.id = g.guardian_user_id
      left join public.students gs  on gs.id = g.guardian_student_id
     where s.prog = 'kids'
  )
  select distinct on (c.email)
         c.email::text, c.display_name::text, c.is_guardian
    from cand c, s
   where c.email is not null
     -- never the kid's own address for a kid
     and not (s.prog = 'kids' and c.email = s.own_email)
     and not exists (select 1 from public.email_optouts o
                      where lower(o.email::text) = c.email
                        and o.kind in ('all', p_kind))
   order by c.email, (c.display_name is null), c.display_name
$$;

-- ---------------------------------------------------------------------------
-- 5. monthly_recap_candidates — one call for the Edge Function
-- ---------------------------------------------------------------------------
create or replace function public.monthly_recap_candidates(p_from date, p_to date)
returns table (
  student_id   uuid,
  student_name text,
  first_name   text,
  is_kid       boolean,
  n            integer,
  email        text,
  display_name text,
  is_guardian  boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id,
         coalesce(s.full_name::text, ''),
         coalesce(nullif(btrim(s.first_name::text), ''), split_part(btrim(coalesce(s.full_name::text, '')), ' ', 1)),
         (s.prog::text = 'kids'),
         public.training_count(s.id, p_from, p_to),
         r.email::text,
         r.display_name::text,
         r.is_guardian
    from public.students s
    left join lateral public.email_recipients_for_student(s.id, 'monthly_recap') r on true
   where s.active is true
     and s.standing is distinct from 'on_hold'
   order by coalesce(s.full_name::text, ''), s.id, r.email
$$;

revoke all on function public.training_count(uuid, date, date) from public, anon, authenticated;
revoke all on function public.email_recipients_for_student(uuid, text) from public, anon, authenticated;
revoke all on function public.monthly_recap_candidates(date, date) from public, anon, authenticated;
-- The Edge Functions run as service_role: grant it explicitly instead of relying
-- on the platform's default privileges.
grant execute on function public.training_count(uuid, date, date) to service_role;
grant execute on function public.email_recipients_for_student(uuid, text) to service_role;
grant execute on function public.monthly_recap_candidates(date, date) to service_role;
grant select, insert, update on public.email_sends to service_role;
grant select, insert on public.email_optouts to service_role;

commit;
