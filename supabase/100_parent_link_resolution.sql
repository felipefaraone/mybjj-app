-- 100_parent_link_resolution.sql
-- Structural parent→kid resolution by parent_student_id, layered on top of the
-- existing email-based re-link.
--
-- WHY: migration 99 added students.parent_student_id / parent2_student_id (uuid
-- FKs to students.id) so a kid can be linked to a parent's OWN students row
-- independently of email. This migration teaches the two places that stitch
-- parent_user_id onto kids to honour that structural link, so a parent's kids
-- resolve on login even when no parent_email matches:
--   * public.claim_profile()                        — runs on the parent's login
--   * public.relink_orphan_kids_on_user_insert()    — AFTER INSERT trigger on users
--
-- In claim_profile the parent's own students row is linked by user_id EARLIER in
-- the function (update students set user_id = v_uid where email = v_email), so the
-- structural block anchors on `user_id = v_uid` — it matches kids whose
-- parent_student_id points at that just-linked row. It is added in all three login
-- branches (existing user / whitelisted new / non-whitelisted new), each right
-- after the branch's email-based re-link.
--
-- The trigger fires on the public.users INSERT, BEFORE claim_profile has linked the
-- parent's students.user_id, so it cannot anchor on user_id yet — it anchors on
-- EMAIL instead (parent_student_id points at a students row whose email matches the
-- new user's email), alongside the existing email parent_email/parent2_email path.
--
-- Everything else in both functions is carried over verbatim from migrations 60
-- (relink trigger) and 61 (claim_profile name-fallback) — this file is the CURRENT
-- full definition of each, so a fresh DB built from migrations alone matches prod.
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor) on 2026-07-16; this file
-- versions it after the fact. applied live 2026-07-16, verified against production.
-- Idempotent: create-or-replace functions + drop/create trigger.

-- ---------------------------------------------------------------------------
-- 1. claim_profile — resolve parent_user_id from parent_student_id (user_id
--    anchored) in all three branches, right after each email-based re-link.
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

    -- Structural link (migration 99): kids whose parent_student_id /
    -- parent2_student_id points at THIS user's own students row (linked by
    -- user_id just above). Resolves parents the email match can't.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (parent_student_id  in (select id from public.students where user_id = v_uid)
            or parent2_student_id in (select id from public.students where user_id = v_uid));

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

    -- Migration 61: heal existing users whose full_name was never populated
    -- (magic-link signups created before that fix). Never overwrites an edited name.
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

  -- Migration 61: JWT-less paths (magic-link) carry no user_metadata.full_name.
  -- Derive from the data we already hold for this email before inserting the row.
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

    -- Structural link (migration 99): anchored on the students row just linked
    -- by user_id above.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (parent_student_id  in (select id from public.students where user_id = v_uid)
            or parent2_student_id in (select id from public.students where user_id = v_uid));

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- Migration 59: re-link orphan kids on first login even when the parent has
    -- no whitelist row. Safe here because the public.users row was just inserted.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email)  = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structural link (migration 99): anchored on the caller's students row by
    -- user_id (set on the adult-self path when their email matches).
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (parent_student_id  in (select id from public.students where user_id = v_uid)
            or parent2_student_id in (select id from public.students where user_id = v_uid));
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. relink_orphan_kids_on_user_insert — AFTER INSERT trigger on public.users.
--    Adds the structural parent_student_id path, EMAIL-anchored (the parent's
--    students.user_id isn't linked yet at trigger time), beside the email path.
-- ---------------------------------------------------------------------------
create or replace function public.relink_orphan_kids_on_user_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and (lower(parent_email)  = lower(new.email)
          or lower(parent2_email) = lower(new.email));

  -- Structural link (migration 99): kids whose parent_student_id /
  -- parent2_student_id points at a students row whose email matches the new
  -- user. Email-anchored because the parent's students.user_id has not been
  -- stitched yet when this AFTER INSERT trigger fires.
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and (parent_student_id  in (select id from public.students where lower(email) = lower(new.email))
          or parent2_student_id in (select id from public.students where lower(email) = lower(new.email)));

  return new;
end;
$$;

drop trigger if exists trg_relink_orphan_kids on public.users;

create trigger trg_relink_orphan_kids
  after insert on public.users
  for each row
  execute function public.relink_orphan_kids_on_user_insert();
