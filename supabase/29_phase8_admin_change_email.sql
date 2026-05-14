-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — admin-driven email change
-- Run AFTER 28_phase8_kid_secondary_parent.sql. Safe to re-run.
--
-- "Change email" link in the admin Edit-profile views now calls this
-- RPC. Updates students/staff/users/whitelist atomically so the new
-- address is consistently the single source of truth.
--
-- Notes vs. the spec:
--   * users.role in our schema uses 'admin' for professors and coaches
--     (see existing edit_staff_admin RPC). The spec said 'instructor'
--     but that value isn't used anywhere by the app, so the guard
--     here matches the rest of the codebase: ('owner','admin').
--   * The spec's whitelist UPDATE referenced users.email AFTER updating
--     it; that would never match. We capture the old address up-front
--     and use it to relocate the whitelist row.
--   * Targets can be linked (have a users row via user_id) or not
--     (whitelist only, hasn't signed in yet). The RPC takes a target
--     kind + students.id / staff.id and handles both cases.
--   * Owner can change emails for any unit. Admin (instructor /
--     professor) is gated to their own unit_id.
-- =============================================================================

create or replace function public.admin_change_user_email(
  p_target_kind  text,   -- 'student' | 'staff'
  p_target_db_id uuid,   -- students.id or staff.id
  p_new_email    text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id      uuid := auth.uid();
  v_caller_role    text;
  v_caller_unit    uuid;
  v_target_unit    uuid;
  v_target_user_id uuid;
  v_old_email      text;
  v_new_email      text := lower(btrim(coalesce(p_new_email,'')));
begin
  if v_caller_id is null then
    raise exception 'not authenticated';
  end if;

  if p_target_kind not in ('student','staff') then
    raise exception 'invalid target kind: %', p_target_kind;
  end if;

  -- Caller must be owner or instructor (admin) per the existing role model.
  select role, unit_id into v_caller_role, v_caller_unit
    from public.users where id = v_caller_id;
  if v_caller_role not in ('owner','admin') then
    raise exception 'only owner or instructor can change emails';
  end if;

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

  -- Owner can change any unit; admin is same-unit only.
  if v_caller_role = 'admin' and v_target_unit <> v_caller_unit then
    raise exception 'cross-unit email change not allowed';
  end if;

  -- Email format check — same lightweight regex as the front-end
  -- validation in saveEmailEditor.
  if v_new_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'invalid email format';
  end if;

  -- No-op when nothing actually changes (lets the UI fire the RPC
  -- defensively without a wasted error).
  if v_new_email = lower(coalesce(v_old_email,'')) then
    return;
  end if;

  -- Uniqueness — exclude the target's own rows so re-saving the
  -- same address never blocks itself.
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

  -- Update the target row first.
  if p_target_kind = 'student' then
    update public.students set email = v_new_email where id = p_target_db_id;
  else
    update public.staff    set email = v_new_email where id = p_target_db_id;
  end if;

  -- If a public.users row exists, mirror the change there. Note: this
  -- does NOT touch auth.users.email — Supabase Auth requires a
  -- user-initiated auth.updateUser flow which is out of scope for V1.
  -- The user's existing session stays valid; their next claim_profile
  -- call will see the new public.users.email.
  if v_target_user_id is not null then
    update public.users set email = v_new_email where id = v_target_user_id;
  end if;

  -- Relocate the whitelist row from the old address to the new one,
  -- if a whitelist row exists for the old address.
  if v_old_email is not null and btrim(v_old_email) <> '' then
    update public.whitelist
       set email = v_new_email
     where lower(email) = lower(v_old_email);
  end if;
end;
$$;

grant execute on function public.admin_change_user_email(text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Function exists + permission:
-- select p.proname, p.prosecdef, has_function_privilege('authenticated', p.oid, 'EXECUTE')
--   from pg_proc p where p.proname='admin_change_user_email';
--
-- 2. Round-trip: change a test student's email, verify all three tables.
-- select email from public.students where id = '<id>';
-- select email from public.users    where id = (select user_id from public.students where id='<id>');
-- select email from public.whitelist where lower(email) = '<new>';
