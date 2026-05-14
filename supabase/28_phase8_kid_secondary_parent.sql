-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — secondary parent contact for kids
-- Run AFTER 27_phase8_attendance_recompute.sql. Safe to re-run.
--
-- Adds an optional second parent/guardian to public.students. The
-- existing parent_name / parent_phone / parent_email columns become
-- "parent 1" and are still required for kids. The new parent2_* set is
-- optional — when parent2_email is filled, the front-end also writes
-- a whitelist row for that email with role='parent' and student_id
-- linked, so the second parent can sign in independently and see the
-- same child via parent_user_id linkage.
--
-- No RLS changes — students_write (admin / staff-of-unit) already
-- covers the new columns. claim_profile picks up parent_user_id via
-- its existing match on lower(parent_email) = lower(v_email), so the
-- only thing we still need server-side is to broaden that lookup to
-- also match parent2_email — handled in this migration.
-- =============================================================================

alter table public.students
  add column if not exists parent2_name  text,
  add column if not exists parent2_phone text,
  add column if not exists parent2_email text;

-- Helpful index for the parent-link lookup in claim_profile.
create index if not exists idx_students_parent2_email
  on public.students (lower(parent2_email));

-- ---------------------------------------------------------------------------
-- claim_profile — supersedes 22_phase8_email_has_password.sql's version.
-- Same approval / catch-up / link logic, but the parent_user_id link
-- now also matches lower(parent2_email) = lower(v_email) so the
-- secondary parent's first sign-in attaches to the right student row.
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
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Columns:
-- select column_name, data_type
--   from information_schema.columns
--  where table_schema='public' and table_name='students'
--    and column_name like 'parent2_%';
-- 2. Index:
-- select indexname from pg_indexes
--   where schemaname='public' and indexname='idx_students_parent2_email';
