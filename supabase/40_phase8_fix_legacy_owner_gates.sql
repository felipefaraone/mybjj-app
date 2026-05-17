-- =============================================================================
-- Migration 40: Fix legacy `current_role() = 'owner'` gates in RPCs
-- Run AFTER 39_phase8_rpc_role_cleanup.sql. Idempotent — every statement
-- is CREATE OR REPLACE.
--
-- After migration 32 (Batch 2A) the role 'owner' no longer exists on
-- public.users — head professors had their role flipped to 'instructor'
-- and ownership moved to units.owner_user_id. The canonical owner check
-- is now public.is_unit_owner_any().
--
-- Several RPCs predating migration 32 still gate with
--   if public.current_role() <> 'owner' then raise 'not authorised'
-- which always rejects the very person it was meant to authorize. The
-- check is dead in the wrong direction: it lets nobody through.
--
-- Migration 39 already fixed this in add_staff_member and
-- edit_staff_admin. This migration finishes the job for the remaining
-- broken RPCs:
--
--   * remove_staff           — owner-only. Gate was hard-broken: nobody
--                              could remove staff in production.
--   * set_staff_email        — owner-only. Same.
--   * reject_photo           — owner-or-black-belt-instructor. Outer
--                              owner fast-path was hard-broken; the
--                              function still worked for the
--                              black-belt-instructor branch but the
--                              owner could not reject a photo from a
--                              student in another unit.
--   * admin_change_user_email — owner-or-instructor, with cross-unit
--                              gate. Hard-broken because the role
--                              check listed only ('owner','admin').
--   * update_class_counts    — outer owner fast-path was dead but
--                              non-broken (the inner 'instructor'
--                              branch caught the head professor too).
--                              Cleaned anyway so every gate uses the
--                              same canonical helper.
--
-- Out of scope (per the batch spec / architecture target):
--   * RLS policy photo_update (11_phase5.sql:64-82) — still references
--     `public.current_role() = 'owner'`. RLS policies are explicitly
--     off-limits for this batch. Flagged for a future RLS sweep.
--   * is_admin / is_staff / is_unit_owner / is_unit_owner_any helpers —
--     post-Batch-2A canon, untouched.
--   * Function signatures, return types, parameter lists.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. remove_staff — supersedes 12_phase5_5.sql
--    Owner-only soft delete. Gate switched from current_role()='owner'
--    to is_unit_owner_any(). All other logic identical to the
--    12_phase5_5.sql version (verbatim).
-- ---------------------------------------------------------------------------
create or replace function public.remove_staff(
  p_legacy_id text
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row          public.staff;
  v_other_owners int;
  v_email        text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_unit_owner_any() then
    raise exception 'not authorised: owner only';
  end if;
  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;
  if v_row.user_id = auth.uid() then
    raise exception 'cannot remove yourself';
  end if;
  if v_row.role_title = 'Head Professor' then
    select count(*) into v_other_owners
      from public.staff
      where role_title = 'Head Professor'
        and active = true
        and id <> v_row.id;
    if v_other_owners = 0 then
      raise exception 'cannot remove the only owner';
    end if;
  end if;

  update public.staff set active = false where legacy_id = p_legacy_id
    returning * into v_row;

  if v_row.user_id is not null then
    select email into v_email from public.users where id = v_row.user_id;
    if v_email is not null then
      delete from public.whitelist where lower(email) = lower(v_email);
    end if;
  end if;

  return v_row;
end;
$$;

grant execute on function public.remove_staff(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. set_staff_email — supersedes 15_phase7_fixes.sql
--    Owner-only. Gate switched to is_unit_owner_any(). The whitelist
--    insert role is also normalised — was 'owner' for Head Professor
--    rows or 'admin' for others; both are gone post-migration-32. The
--    canonical value is 'instructor' (matches what migration 39's
--    add_staff_member writes for new invites).
-- ---------------------------------------------------------------------------
create or replace function public.set_staff_email(
  p_legacy_id text,
  p_email     text
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.staff;
  v_old text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_unit_owner_any() then
    raise exception 'not authorised: owner only';
  end if;
  if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format';
  end if;

  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;
  v_old := v_row.email;

  update public.staff set email = lower(p_email)
    where legacy_id = p_legacy_id
    returning * into v_row;

  if v_old is not null and lower(v_old) <> lower(p_email) then
    delete from public.whitelist where lower(email) = lower(v_old);
  end if;

  insert into public.whitelist (email, role, unit_id, invited_by, invited_at)
  values (lower(p_email), 'instructor', v_row.unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = 'instructor',
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.set_staff_email(text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. reject_photo — supersedes 11_phase5.sql
--    Owner-or-(black-belt instructor in same unit). Outer fast-path
--    switched to is_unit_owner_any(); inner branch logic unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.reject_photo(
  p_id     uuid,
  p_reason text default null
) returns public.photo_approvals
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  v_row     public.photo_approvals;
  v_belt    text;
  v_unit_ok boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select * into v_row from public.photo_approvals where id = p_id;
  if not found then
    raise exception 'photo_approval % not found', p_id;
  end if;

  -- Owner has the fast-path. Otherwise must be a black-belt instructor
  -- whose staff.unit_id matches the subject student's unit.
  if not public.is_unit_owner_any() then
    select belt into v_belt from public.staff where user_id = auth.uid() limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can reject photos';
    end if;
    select (s.unit_id = (select unit_id from public.staff where user_id = auth.uid() limit 1))
      into v_unit_ok
      from public.students s
      where s.id = v_row.student_id;
    if not v_unit_ok then
      raise exception 'not authorised: student is in another unit';
    end if;
  end if;

  update public.photo_approvals
     set status          = 'rejected',
         rejected_reason = p_reason,
         approved_by_id  = auth.uid(),
         approved_at     = now()
   where id = p_id
   returning * into v_row;

  if v_row.photo_url is not null and v_row.photo_url <> '' then
    begin
      delete from storage.objects
       where bucket_id = 'avatars' and name = v_row.photo_url;
    exception when others then null;
    end;
  end if;

  return v_row;
end;
$$;

grant execute on function public.reject_photo(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. admin_change_user_email — supersedes 29_phase8_admin_change_email.sql
--    Owner-or-instructor. Gate switched: caller must own at least one
--    unit OR be staff. Cross-unit gate: if caller is NOT a unit owner,
--    target unit must match caller's unit_id. All other logic
--    (validation, uniqueness, atomic write) is verbatim from
--    29_phase8_admin_change_email.sql.
-- ---------------------------------------------------------------------------
create or replace function public.admin_change_user_email(
  p_target_kind  text,
  p_target_db_id uuid,
  p_new_email    text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id      uuid := auth.uid();
  v_caller_unit    uuid;
  v_target_unit    uuid;
  v_target_user_id uuid;
  v_old_email      text;
  v_new_email      text := lower(btrim(coalesce(p_new_email,'')));
  v_is_owner       boolean := public.is_unit_owner_any();
begin
  if v_caller_id is null then
    raise exception 'not authenticated';
  end if;

  if p_target_kind not in ('student','staff') then
    raise exception 'invalid target kind: %', p_target_kind;
  end if;

  -- Caller must be owner (of at least one unit) or an instructor.
  if not (v_is_owner or public.is_staff()) then
    raise exception 'only owner or instructor can change emails';
  end if;

  select unit_id into v_caller_unit from public.users where id = v_caller_id;

  -- Load target row + old email + unit + linked user_id (if any).
  if p_target_kind = 'student' then
    select unit_id, user_id, email
      into v_target_unit, v_target_user_id, v_old_email
      from public.students where id = p_target_db_id;
  else
    select unit_id, user_id, email
      into v_target_unit, v_target_user_id, v_old_email
      from public.staff where id = p_target_db_id;
  end if;

  if v_target_unit is null then
    raise exception 'target % not found', p_target_db_id;
  end if;

  -- Owner can change any unit; non-owner instructor is same-unit only.
  if not v_is_owner and v_target_unit <> v_caller_unit then
    raise exception 'cross-unit email change not allowed';
  end if;

  if v_new_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'invalid email format';
  end if;

  if v_new_email = lower(coalesce(v_old_email,'')) then
    return;
  end if;

  if exists (
    select 1 from public.users
     where lower(email) = v_new_email
       and (v_target_user_id is null or id <> v_target_user_id)
  ) or exists (
    select 1 from public.students
     where lower(email) = v_new_email
       and (p_target_kind <> 'student' or id <> p_target_db_id)
  ) or exists (
    select 1 from public.students
     where lower(parent_email)  = v_new_email
  ) or exists (
    select 1 from public.students
     where lower(parent2_email) = v_new_email
  ) or exists (
    select 1 from public.staff
     where lower(email) = v_new_email
       and (p_target_kind <> 'staff' or id <> p_target_db_id)
  ) or exists (
    select 1 from public.whitelist
     where lower(email) = v_new_email
       and (v_old_email is null or lower(email) <> lower(v_old_email))
  ) then
    raise exception 'email already in use';
  end if;

  if p_target_kind = 'student' then
    update public.students set email = v_new_email where id = p_target_db_id;
  else
    update public.staff    set email = v_new_email where id = p_target_db_id;
  end if;

  if v_target_user_id is not null then
    update public.users set email = v_new_email where id = v_target_user_id;
  end if;

  if v_old_email is not null and btrim(v_old_email) <> '' then
    update public.whitelist
       set email = v_new_email
     where lower(email) = lower(v_old_email);
  end if;
end;
$$;

grant execute on function public.admin_change_user_email(text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. update_class_counts — supersedes 10_phase4_5.sql
--    Allowed callers: unit owner (any) OR black-belt instructor.
--    The original outer fast-path was `if v_role <> 'owner'` (dead
--    since migration 32). The inner check accepted ('admin','instructor')
--    which kept the function working for Mario via fall-through. Now
--    every gate uses the canonical helpers; no dead branches.
-- ---------------------------------------------------------------------------
create or replace function public.update_class_counts(
  p_legacy_id text,
  p_total     int,
  p_gi        int,
  p_nogi      int,
  p_grade     int,
  p_gi_grade  int
) returns public.students
language plpgsql
security definer
set search_path = public
as $$
declare
  v_belt    text;
  v_student public.students;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_total < 0 or p_gi < 0 or p_nogi < 0 or p_grade < 0 or p_gi_grade < 0 then
    raise exception 'counters must be non-negative integers';
  end if;

  -- Owner is always allowed; otherwise the caller must be a black-belt
  -- instructor (a "Professor" in myBJJ titling).
  if not public.is_unit_owner_any() then
    if not public.is_staff() then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
    select s.belt into v_belt
      from public.staff s
      where s.user_id = auth.uid()
      limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
  end if;

  update public.students set
    total        = p_total,
    gi_classes   = p_gi,
    nogi_classes = p_nogi,
    grade        = p_grade,
    gi_grade     = p_gi_grade
  where legacy_id = p_legacy_id
  returning * into v_student;

  if not found then
    raise exception 'student % not found', p_legacy_id;
  end if;

  return v_student;
end;
$$;

grant execute on function public.update_class_counts(text,int,int,int,int,int) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
begin
  select count(*) into v_count
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in (
       'remove_staff',
       'set_staff_email',
       'reject_photo',
       'admin_change_user_email',
       'update_class_counts'
     );
  raise notice 'Migration 40: % RPCs reconfigured (expect 5)', v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Verification (run manually post-migration)
-- ---------------------------------------------------------------------------
-- 1. No active function body still gates on current_role() = 'owner'.
--    This includes RLS policy bodies — the one known offender is the
--    photo_update policy from 11_phase5.sql:64-82 (out of scope for
--    this batch).
-- select p.proname
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname='public'
--     and pg_get_functiondef(p.oid) ilike '%current_role()%''owner''%';
-- -- Expect: 0 rows.
--
-- 2. is_admin() and is_staff() helpers untouched.
-- select pg_get_functiondef('public.is_admin'::regproc);
-- select pg_get_functiondef('public.is_staff'::regproc);
--
-- 3. Smoke test from the app as admin.mybjj@gmail.com (owner of NB):
--    a. Manage → Staff → click "remove" on a non-owner staff row.
--       Should succeed (was raising "not authorised: owner only").
--    b. Manage → Staff → edit a row → change email → save.
--       Should succeed (was failing).
--    c. Open a pending photo approval → reject. Should succeed.
--    d. Manage → Roster → student → edit profile → change email.
--       Should succeed.
--    e. Manage → Roster → student → edit class counts → save.
--       Should succeed (was already working via fall-through).
