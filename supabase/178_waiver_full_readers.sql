-- 178_waiver_full_readers.sql
--
-- Who reads the FULL health waiver (decision 27 Oct 2026): only Patricia, Mario
-- and the admin account. Everyone else who sees a student today (instructors, and
-- the owners who are not in the list) keeps the in-class ALERTS only: the 8 flags,
-- safety_notes and signed_at. A member and their parent / active guardians keep
-- their own full waiver.
--
-- This migration is ADDITIVE: nothing is revoked, the app of today keeps working.
-- 179 is the lock (column grants on health_waivers + the waivers bucket policy).
--
--   1. public.waiver_full_readers (user_id pk -> auth.users): the readers, by key.
--      RLS on, no client policies, no client grants. Seeded with the 3 users of
--      the decision, resolved by email HERE ONLY (never at runtime); the seed
--      refuses to run unless exactly 3 users are found.
--   2. public.can_read_full_waiver(): auth.uid() is a reader.
--   3. public.waiver_document(p_student, p_trial): the latest waiver, the columns
--      the app's _fetchWaiverDoc selects today. A student's: a reader, the student
--      themselves, their parent_user_id or an active guardian (hw_select's own /
--      guardian branches). A trial's: a reader only. Anyone else: no row.
--   4. public.waiver_alerts(p_student): the latest flags + safety_notes +
--      signed_at among the rows hw_select lets the caller see today (its row rule
--      mirrored exactly; hw_select itself is not changed).
--   5. public.waiver_trial_link_check(p_trial) -> (id, student_id) and
--      public.waiver_trial_prefill(p_trial) -> (dob, gender) from answers->>'dob'
--      and answers->>'gender' (the kid conversion's prefill): for staff / admin,
--      on the rows hw_select's staff branches show today (is_admin(), or is_staff()
--      in the current unit), what the trial conversion paths read today.
--
-- All functions: SECURITY DEFINER, search_path = public, execute for
-- authenticated only (not anon, not PUBLIC).
-- Not touched: hw_select / hw_insert / hw_update / hw_delete, the waivers bucket,
-- Edge Functions, waiver.html, any row of health_waivers.
-- Run with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/178_waiver_full_readers.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. The readers
-- ---------------------------------------------------------------------------
create table if not exists public.waiver_full_readers (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now(),
  added_by uuid references auth.users (id) on delete set null   -- null: the 178 seed
);
alter table public.waiver_full_readers enable row level security;
revoke all on public.waiver_full_readers from anon, authenticated;

do $$
declare
  v_n integer;
begin
  select count(*) into v_n
    from auth.users
   where lower(email) in ('info@mybjj.com.au', 'mariobjj@hotmail.com', 'admin.mybjj@gmail.com');
  if v_n <> 3 then
    raise exception '178: expected exactly 3 waiver readers in auth.users, found %', v_n;
  end if;
  insert into public.waiver_full_readers (user_id, added_by)
  select id, null
    from auth.users
   where lower(email) in ('info@mybjj.com.au', 'mariobjj@hotmail.com', 'admin.mybjj@gmail.com')
  on conflict (user_id) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Is the caller a reader
-- ---------------------------------------------------------------------------
create or replace function public.can_read_full_waiver()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (select 1 from public.waiver_full_readers r where r.user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------------
-- 3. The full document (the columns _fetchWaiverDoc selects)
-- ---------------------------------------------------------------------------
create or replace function public.waiver_document(p_student uuid default null, p_trial uuid default null)
returns table (
  id uuid, participant_name text, is_minor boolean, signed_by_name text, signed_by_relationship text,
  signed_at timestamptz, waiver_text_version text, signature_path text,
  emergency_name text, emergency_phone text, emergency_relationship text,
  safety_notes text, answers jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or (p_student is null) = (p_trial is null) then
    return;                                                   -- exactly one key
  end if;
  if p_student is not null then
    if not (public.can_read_full_waiver()
            or exists (select 1 from public.students s
                        where s.id = p_student and (s.user_id = v_uid or s.parent_user_id = v_uid))
            or p_student = any ((select public.guardian_student_ids())::uuid[])) then
      return;
    end if;
    return query
      select w.id, w.participant_name, w.is_minor, w.signed_by_name, w.signed_by_relationship,
             w.signed_at, w.waiver_text_version, w.signature_path,
             w.emergency_name, w.emergency_phone, w.emergency_relationship,
             w.safety_notes, w.answers
        from public.health_waivers w
       where w.student_id = p_student
       order by w.signed_at desc, w.created_at desc, w.id
       limit 1;
  else
    if not public.can_read_full_waiver() then
      return;                                                 -- a trial's: readers only
    end if;
    return query
      select w.id, w.participant_name, w.is_minor, w.signed_by_name, w.signed_by_relationship,
             w.signed_at, w.waiver_text_version, w.signature_path,
             w.emergency_name, w.emergency_phone, w.emergency_relationship,
             w.safety_notes, w.answers
        from public.health_waivers w
       where w.trial_booking_id = p_trial
       order by w.signed_at desc, w.created_at desc, w.id
       limit 1;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The alerts (hw_select's row rule, mirrored exactly)
-- ---------------------------------------------------------------------------
create or replace function public.waiver_alerts(p_student uuid)
returns table (
  has_asthma boolean, has_heart_condition boolean, has_diabetes boolean, has_epilepsy boolean,
  is_pregnant boolean, takes_medication boolean, has_allergies boolean, has_recent_injury boolean,
  safety_notes text, signed_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select w.has_asthma, w.has_heart_condition, w.has_diabetes, w.has_epilepsy,
         w.is_pregnant, w.takes_medication, w.has_allergies, w.has_recent_injury,
         w.safety_notes, w.signed_at
    from public.health_waivers w
   where auth.uid() is not null
     and w.student_id = p_student
     and (public.is_admin()
          or (public.is_staff() and w.unit_id = public.current_unit())
          or exists (select 1 from public.students s
                      where s.id = w.student_id and (s.user_id = auth.uid() or s.parent_user_id = auth.uid()))
          or w.student_id = any ((select public.guardian_student_ids())::uuid[]))
   order by w.signed_at desc, w.created_at desc, w.id
   limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 5. Trial conversion reads (hw_select's staff branches)
-- ---------------------------------------------------------------------------
create or replace function public.waiver_trial_link_check(p_trial uuid)
returns table (id uuid, student_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select w.id, w.student_id
    from public.health_waivers w
   where auth.uid() is not null
     and w.trial_booking_id = p_trial
     and (public.is_admin() or (public.is_staff() and w.unit_id = public.current_unit()))
   order by w.signed_at desc, w.created_at desc, w.id;
$$;

create or replace function public.waiver_trial_prefill(p_trial uuid)
returns table (dob text, gender text)
language sql
stable
security definer
set search_path = public
as $$
  select w.answers ->> 'dob', w.answers ->> 'gender'
    from public.health_waivers w
   where auth.uid() is not null
     and w.trial_booking_id = p_trial
     and (public.is_admin() or (public.is_staff() and w.unit_id = public.current_unit()))
   order by w.signed_at desc, w.created_at desc, w.id
   limit 1;
$$;

-- ---------------------------------------------------------------------------
-- Grants: authenticated only
-- ---------------------------------------------------------------------------
revoke all on function public.can_read_full_waiver()              from public, anon;
revoke all on function public.waiver_document(uuid, uuid)         from public, anon;
revoke all on function public.waiver_alerts(uuid)                 from public, anon;
revoke all on function public.waiver_trial_link_check(uuid)       from public, anon;
revoke all on function public.waiver_trial_prefill(uuid)          from public, anon;
grant execute on function public.can_read_full_waiver()           to authenticated;
grant execute on function public.waiver_document(uuid, uuid)      to authenticated;
grant execute on function public.waiver_alerts(uuid)              to authenticated;
grant execute on function public.waiver_trial_link_check(uuid)    to authenticated;
grant execute on function public.waiver_trial_prefill(uuid)       to authenticated;

commit;
