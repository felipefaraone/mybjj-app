-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — two-step login support + journey back-fill
-- Run AFTER 21_phase8_journey_label_fix.sql. Safe to re-run.
--
-- The login screen is moving to the two-step pattern (Stripe / Notion /
-- Linear): user enters email first, app decides whether to ask for a
-- password or send a magic link. To route correctly we need a public
-- check that doesn't expose auth.users to the browser. Two RPCs:
--
--   public.email_signin_state(email)  → 'has_password' | 'no_password'
--                                        | 'not_authorized'
--   public.mark_password_set()         → flips public.users.has_password
--                                        to true (the password is stored
--                                        in auth.users; we mirror a
--                                        boolean on public for the
--                                        front-end's banner gate).
--
-- Plus:
--   - has_password column on public.users (default false), back-filled
--     from auth.users.encrypted_password.
--   - claim_profile rewritten to seed an empty journey on EVERY linked
--     student row, not just the one that was just linked this call.
--     That catches the case the user reported: Felipe (owner) signed in
--     and his linked students row was never seeded with "Joined myBJJ
--     app" because the seed only fired on the link-this-call path.
--   - One-shot back-fill of any user-linked students.journey that's
--     still empty.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. has_password column + back-fill from auth.users.encrypted_password
-- ---------------------------------------------------------------------------
alter table public.users
  add column if not exists has_password boolean not null default false;

update public.users u
   set has_password = true
  from auth.users a
 where a.id = u.id
   and a.encrypted_password is not null
   and a.encrypted_password <> ''
   and u.has_password = false;

-- ---------------------------------------------------------------------------
-- 2. email_signin_state(email) — public read so the unauthenticated
--    login screen can call it. Returns one of:
--      'not_authorized'   — email isn't on the whitelist
--      'no_password'      — whitelisted but the user has no password set
--      'has_password'     — whitelisted and password exists
--
--    SECURITY DEFINER so it can read public.whitelist (admin-only RLS)
--    and public.users (self-only RLS). Granted to anon + authenticated.
--    Doesn't expose any other user data.
-- ---------------------------------------------------------------------------
create or replace function public.email_signin_state(p_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_has   boolean;
begin
  if v_email = '' or v_email !~ '^\S+@\S+\.\S+$' then
    return 'not_authorized';
  end if;
  if not exists (select 1 from public.whitelist where lower(email) = v_email) then
    return 'not_authorized';
  end if;
  select coalesce(u.has_password, false) into v_has
    from public.users u
   where lower(u.email) = v_email
   limit 1;
  if v_has then return 'has_password'; end if;
  return 'no_password';
end;
$$;

grant execute on function public.email_signin_state(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. mark_password_set() — called by the client right after
--    auth.updateUser({password}) succeeds, so the next claim_profile
--    return reflects the new state without the client having to round
--    trip auth.users.
-- ---------------------------------------------------------------------------
create or replace function public.mark_password_set()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  update public.users
     set has_password = true
   where id = auth.uid();
end;
$$;

grant execute on function public.mark_password_set() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. claim_profile — supersedes 19_phase8_journey_seed.sql's version
--    once more. Same approval / catch-up / link logic. The journey-seed
--    pass at the end now iterates EVERY linked students row instead of
--    only the one just linked this call, so an owner / professor who
--    also trains as a student gets the "Joined myBJJ app" milestone.
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

    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and lower(parent_email) = lower(v_email);

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

    -- Seed journey on every linked students row that's still empty.
    -- Covers the owner / professor who also has a student row case
    -- (their student row may have been linked in a prior call without
    -- the seed firing).
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
       and lower(parent_email) = lower(v_email);

    -- Same final journey-seed pass as the catch-up branch.
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
-- 5. Back-fill: any existing linked student row with empty journey gets
--    the starting milestone retroactively. Idempotent — the helper
--    no-ops when journey is already non-empty.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select s.id as stu_id
      from public.students s
     where s.user_id is not null
       and (s.journey is null or jsonb_array_length(s.journey) = 0)
  loop
    perform public.seed_student_journey_if_empty(r.stu_id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Verification (uncomment in SQL editor)
-- ---------------------------------------------------------------------------
-- select id, email, has_password from public.users where has_password = false;
-- select public.email_signin_state('admin.mybjj@gmail.com');
-- select s.full_name, jsonb_array_length(s.journey) n_milestones
--   from public.students s where s.user_id is not null;
