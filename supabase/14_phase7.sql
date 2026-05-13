-- =============================================================================
-- myBJJ V1 — Phase 7 (Parent role + Meet the team)
-- Run AFTER 13_phase5_9.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Parent contact columns on students
-- ---------------------------------------------------------------------------
alter table public.students add column if not exists parent_name  text;
alter table public.students add column if not exists parent_phone text;
alter table public.students add column if not exists parent_email text;
create index if not exists idx_students_parent_email_lower
  on public.students(lower(parent_email));

-- ---------------------------------------------------------------------------
-- 2. claim_profile — supersedes 13_phase5_9.sql. Adds the parent auto-link
--    by parent_email, in both the new-user insert branch and the existing-
--    user catch-up branch. The role pass-through from whitelist now also
--    covers 'parent' / 'student' (was already allowed by the users role
--    check; this is just a comment update — the INSERT keeps using
--    v_wl.role verbatim).
-- ---------------------------------------------------------------------------
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

  if found then
    -- Catch-up auto-links every call: staff, students-self, students-parent.
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
    return v_existing;
  end if;

  v_name := coalesce(
    (auth.jwt() -> 'user_metadata' ->> 'full_name'),
    (auth.jwt() -> 'user_metadata' ->> 'name'),
    null
  );

  select * into v_wl
    from public.whitelist
    where lower(email) = lower(v_email)
    limit 1;

  if found then
    -- whitelist.role passes straight through to users.role, including
    -- 'parent' and 'student'. The check constraint on users.role allows
    -- ('admin','owner','instructor','student','parent').
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
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. RLS adjustments for parent role
-- ---------------------------------------------------------------------------
-- students_select already includes the parent_user_id = auth.uid() branch
-- (from 02_rls.sql), so parents see their kid's row through that path.
-- Add a parent-can-insert-attendance branch and a parent-can-insert-photo
-- branch so the kid's own attendance + photo flows work without staff
-- elevation.
-- ---------------------------------------------------------------------------

drop policy if exists attendance_insert on public.attendance;
create policy attendance_insert on public.attendance
  for insert to authenticated
  with check (
    public.is_staff()
    or exists (
      select 1 from public.students s
      where s.id = attendance.student_id
        and (s.user_id = auth.uid() or s.parent_user_id = auth.uid())
    )
  );

drop policy if exists photo_insert on public.photo_approvals;
create policy photo_insert on public.photo_approvals
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (
      public.is_staff()
      or exists (
        select 1 from public.students s
        where s.id = photo_approvals.student_id
          and (s.user_id = auth.uid() or s.parent_user_id = auth.uid())
      )
    )
  );
