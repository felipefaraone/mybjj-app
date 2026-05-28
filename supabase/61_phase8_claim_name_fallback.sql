-- 61_phase8_claim_name_fallback.sql
-- Derive users.full_name when the JWT carries no name (magic-link
-- signups). Two-step fallback:
--   1. students.first_name + last_name where students.email matches v_email
--      (the adult-self path — user is a student in their own right).
--   2. students.parent_name where students.parent_email OR parent2_email
--      matches v_email (the parent path — user is the parent of a kid).
-- Both insert branches now use the derived v_name; the existing-user
-- branch backfills public.users.full_name when it's currently blank,
-- so accounts that signed in before this migration heal on next login.
--
-- Preserves migration 59's else-branch re-link and every other
-- claim_profile behaviour.
--
-- Idempotent: create-or-replace function + a one-off backfill UPDATE
-- gated on `full_name is null or trim(full_name) = ''`.

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

    -- NEW (migration 61): heal existing users whose full_name was
    -- never populated (magic-link signups created before this fix).
    -- Derive from the same two sources the insert branches now use,
    -- and only write when the column is blank — never overwrites a
    -- name the user already edited.
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
         where lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email)
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

  -- NEW (migration 61): JWT-less paths (magic-link signups) carry no
  -- user_metadata.full_name. Derive from the existing data we already
  -- have for this email before inserting the users row, so the row is
  -- born with a real name instead of falling back to the raw email.
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
     where lower(parent_email)  = lower(v_email)
        or lower(parent2_email) = lower(v_email)
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
       and (lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- Migration 59: re-link orphan kids on first login even when the
    -- parent has no whitelist row. Safe here because the public.users
    -- row was just inserted on the line above.
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

-- ---------------------------------------------------------------------------
-- Backfill: heal historical null/blank full_name rows.
-- ---------------------------------------------------------------------------
do $$
declare
  v_before int;
  v_after  int;
  v_fixed  int;
begin
  select count(*) into v_before
    from public.users
   where full_name is null or trim(full_name) = '';

  update public.users u
     set full_name = sub.nm
    from (
      select u2.id,
        coalesce(
          (select nullif(trim(coalesce(s.first_name,'')||' '||coalesce(s.last_name,'')),'')
             from public.students s where lower(s.email)=lower(u2.email) limit 1),
          (select s.parent_name
             from public.students s
            where lower(s.parent_email)=lower(u2.email)
               or lower(s.parent2_email)=lower(u2.email)
            limit 1)
        ) as nm
      from public.users u2
      where u2.full_name is null or trim(u2.full_name) = ''
    ) sub
   where u.id = sub.id
     and sub.nm is not null
     and trim(sub.nm) <> '';

  get diagnostics v_fixed = row_count;

  select count(*) into v_after
    from public.users
   where full_name is null or trim(full_name) = '';

  raise notice 'Migration 61 — full_name backfill';
  raise notice '  blank before: %', v_before;
  raise notice '  rows healed : %', v_fixed;
  raise notice '  blank after : %', v_after;
end $$;
