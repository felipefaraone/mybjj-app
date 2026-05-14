-- =============================================================================
-- myBJJ V1 — Phase 8 fix — claim_profile must upgrade pending → approved
-- Run AFTER 17_phase7_5_nickname.sql. Safe to re-run.
--
-- Bug: if a user signed in once before being whitelisted, their public.users
-- row was created with status='pending'. When the admin later added them to
-- the whitelist and sent a fresh magic link, claim_profile's "already
-- onboarded" branch returned the existing row untouched — so the student
-- saw "Pending approval" forever even though the whitelist now sanctioned
-- them. Fresh users (no prior public.users row) were unaffected.
--
-- Fix: in the catch-up branch, also look up the whitelist. If the user is
-- still 'pending' and a matching whitelist row exists, upgrade status to
-- 'approved' and re-sync role + unit_id from the whitelist. The function
-- stays idempotent — calling it on an already-approved user is a no-op.
--
-- Includes a one-shot back-fix update for anyone currently stuck pending
-- whose email is now in the whitelist, so existing victims don't have to
-- click another magic link to escape the bad state.
-- =============================================================================

create or replace function public.claim_profile()
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := auth.email();
  v_name  text;
  v_existing public.users;
  v_wl    public.whitelist;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_existing from public.users where id = v_uid;

  -- Always look up the whitelist by email — we need it both for the
  -- first-time-insert path and for the catch-up upgrade below.
  select * into v_wl
    from public.whitelist
   where lower(email) = lower(v_email)
   limit 1;

  if v_existing.id is not null then
    -- Catch-up upgrade: user signed up before being whitelisted, then admin
    -- whitelisted them. Promote pending → approved and re-sync role / unit.
    if v_wl.email is not null and v_existing.status = 'pending' then
      update public.users
         set status  = 'approved',
             role    = coalesce(v_wl.role,    v_existing.role),
             unit_id = coalesce(v_wl.unit_id, v_existing.unit_id)
       where id = v_uid
       returning * into v_existing;
    end if;

    -- Existing catch-up auto-links: staff, students-self, students-parent.
    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and lower(parent_email) = lower(v_email);

    -- If whitelist references a specific student (parent invites), wire it.
    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    return v_existing;
  end if;

  -- First sign-in for this auth user: create their public.users row.
  v_name := coalesce(
    (auth.jwt() -> 'user_metadata' ->> 'full_name'),
    (auth.jwt() -> 'user_metadata' ->> 'name'),
    null
  );

  if v_wl.email is not null then
    insert into public.users (id, email, role, unit_id, status, full_name)
    values (v_uid, v_email, v_wl.role, v_wl.unit_id, 'approved', v_name)
    returning * into v_existing;

    if v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and lower(parent_email) = lower(v_email);
  else
    -- No whitelist match → keep self-signup-pending semantics so an
    -- owner can review the request in admin.
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- One-shot back-fix: anyone currently 'pending' whose email is in the
-- whitelist gets upgraded immediately. Idempotent.
-- ---------------------------------------------------------------------------
update public.users u
   set status  = 'approved',
       role    = coalesce(w.role,    u.role),
       unit_id = coalesce(w.unit_id, u.unit_id)
  from public.whitelist w
 where u.status = 'pending'
   and lower(u.email) = lower(w.email);

-- ---------------------------------------------------------------------------
-- Verification (uncomment in SQL Editor to inspect)
-- ---------------------------------------------------------------------------
-- select id, email, role, status from public.users where status = 'pending';
-- select email, role, unit_id, invited_at from public.whitelist order by invited_at desc limit 20;
