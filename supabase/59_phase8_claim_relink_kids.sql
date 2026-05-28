-- 59_phase8_claim_relink_kids.sql
-- Re-asserts public.claim_profile() and closes the orphan-kid re-link
-- gap in the new-without-whitelist branch.
--
-- Migration 28 already runs the parent re-link inside the existing-user
-- branch and the new-via-whitelist branch — both fire AFTER the
-- public.users row exists for v_uid. The only missing branch was the
-- final `else` (new user with no whitelist row): it inserts a pending
-- users row but did not run the re-link, leaving orphan kids unlinked
-- until the parent's NEXT login.
--
-- Fix: add the same re-link UPDATE immediately AFTER the
--   `insert into public.users (...) returning * into v_existing;`
-- in the `else` branch. Doing it AFTER the insert is critical:
-- students.parent_user_id has a FK to public.users(id), so the UPDATE
-- must run only once the row is guaranteed to exist. (An earlier draft
-- of this migration hoisted the re-link to the top of the function —
-- that version would fail with an FK violation for any brand-new user
-- without an existing public.users row, blocking the exact
-- Save-&-add-child flow we're trying to fix.)
--
-- Idempotent: `create or replace function` swaps the definition.

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
  v_stu   uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_existing from public.users where id = v_uid;

  select * into v_wl
    from public.whitelist
   where lower(email) = lower(v_email)
   limit 1;

  if v_existing.id is not null then
    if v_wl.email is not null and v_existing.status = 'pending' then
      update public.users
         set status  = 'approved',
             role    = coalesce(v_wl.role,    v_existing.role),
             unit_id = coalesce(v_wl.unit_id, v_existing.unit_id)
       where id = v_uid
       returning * into v_existing;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    -- Parent link — matches parent_email OR parent2_email.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    if v_existing.unit_id is null then
      update public.users u
         set unit_id = sub.unit_id
        from (
          select coalesce(
            (select unit_id from public.students where user_id = v_uid limit 1),
            (select unit_id from public.staff    where user_id = v_uid limit 1),
            (select unit_id from public.students where parent_user_id = v_uid limit 1)
          ) as unit_id
        ) sub
       where u.id = v_uid
         and sub.unit_id is not null
       returning u.* into v_existing;
    end if;

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;

    return v_existing;
  end if;

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
       and (lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- NEW (migration 59): re-link orphan kids on first login even when
    -- the parent has no whitelist row. Safe to run here because the
    -- public.users row was just inserted on the line above — FK
    -- students.parent_user_id → users(id) is satisfied. Matches both
    -- parent_email and parent2_email, same shape as the other two
    -- branches.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email));
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;
