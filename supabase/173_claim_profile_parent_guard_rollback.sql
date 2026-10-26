-- 173 rollback: restores claim_profile exactly as it was before 173 (unguarded).
-- Run on its own, never in the same paste as the fix.

CREATE OR REPLACE FUNCTION public.claim_profile()
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := auth.email();
  v_name text;
  v_existing public.users;
  v_wl public.whitelist;
  v_stu uuid;
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
         set status = 'approved',
             role = coalesce(v_wl.role, v_existing.role),
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
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    -- 133: activate pending guardianships addressed to this person (their email,
    -- or a guardian student row they now own). Requested rows are NOT touched:
    -- those still wait for staff.
    perform public._guardianship_claim(v_uid, v_email);

    if v_existing.unit_id is null then
      update public.users u
         set unit_id = sub.unit_id
        from (
          select coalesce(
            (select unit_id from public.students where user_id = v_uid limit 1),
            (select unit_id from public.staff where user_id = v_uid limit 1),
            (select unit_id from public.students where parent_user_id = v_uid limit 1),
            -- 133: same fallback through an active guardianship.
            (select s.unit_id from public.guardianships g join public.students s on s.id = g.student_id
              where g.guardian_user_id = v_uid and g.status = 'active' limit 1)
          ) as unit_id
        ) sub
       where u.id = v_uid
         and sub.unit_id is not null
       returning u.* into v_existing;
    end if;

    if v_existing.full_name is null or trim(v_existing.full_name) = '' then
      v_name := null;
      select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
        into v_name
        from public.students
       where lower(email) = lower(v_email)
       limit 1;
      if v_name is null or trim(v_name) = '' then
        select parent_name
          into v_name
          from public.students
         where lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email)
         limit 1;
      end if;
      -- 133: a pending invite can carry a display name of its own.
      if v_name is null or trim(v_name) = '' then
        select g.guardian_name
          into v_name
          from public.guardianships g
         where lower(g.invite_email::text) = lower(v_email)
           and g.guardian_name is not null
           and g.status in ('requested','pending','active')
         limit 1;
      end if;
      if v_name is not null and trim(v_name) <> '' then
        update public.users
           set full_name = v_name
         where id = v_uid
           and (full_name is null or trim(full_name) = '')
         returning * into v_existing;
      end if;
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

  if v_name is null or trim(v_name) = '' then
    select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
      into v_name
      from public.students
     where lower(email) = lower(v_email)
     limit 1;
  end if;
  if v_name is null or trim(v_name) = '' then
    select parent_name
      into v_name
      from public.students
     where lower(parent_email) = lower(v_email)
        or lower(parent2_email) = lower(v_email)
     limit 1;
  end if;
  -- 133: a pending invite can carry a display name of its own.
  if v_name is null or trim(v_name) = '' then
    select g.guardian_name
      into v_name
      from public.guardianships g
     where lower(g.invite_email::text) = lower(v_email)
       and g.guardian_name is not null
       and g.status in ('requested','pending','active')
     limit 1;
  end if;

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
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    -- 133: activate pending guardianships addressed to this person.
    perform public._guardianship_claim(v_uid, v_email);

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- Migration 59: re-link orphan kids on first login even when the
    -- parent has no whitelist row.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    -- 133: activate pending guardianships addressed to this person (mirrors the
    -- legacy links above, which also run for a pending user).
    perform public._guardianship_claim(v_uid, v_email);
  end if;

  return v_existing;
end;
$function$;
