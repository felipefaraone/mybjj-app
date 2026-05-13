-- =============================================================================
-- myBJJ V1 — Phase 5.9 (Auto-link auth users to staff / students rows)
-- Run AFTER 12_phase5_5.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. email column on staff and students (nullable, lower-cased on write).
--    Lets us match auth.email() back to the row without a join table.
-- ---------------------------------------------------------------------------
alter table public.staff    add column if not exists email text;
alter table public.students add column if not exists email text;

create index if not exists idx_staff_email_lower
  on public.staff(lower(email));
create index if not exists idx_students_email_lower
  on public.students(lower(email));

-- ---------------------------------------------------------------------------
-- 2. add_staff_member — supersedes 12_phase5_5.sql version.
--    Same signature; now also writes staff.email so claim_profile can
--    auto-link the auth user on their first sign-in.
-- ---------------------------------------------------------------------------
create or replace function public.add_staff_member(
  p_full_name      text,
  p_email          text,
  p_belt           text,
  p_degree         int,
  p_unit_legacy_id text,
  p_initials       text
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit_id uuid;
  v_legacy  text;
  v_base    text;
  v_n       int := 1;
  v_row     public.staff;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if public.current_role() <> 'owner' then
    raise exception 'not authorised: owner only';
  end if;
  if p_full_name is null or trim(p_full_name) = '' then
    raise exception 'full_name required';
  end if;
  if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format';
  end if;
  if p_belt is null or p_belt not in ('white','blue','purple','brown','black') then
    raise exception 'invalid belt';
  end if;
  if p_degree is null or p_degree < 0 or p_degree > 6 then
    raise exception 'invalid degree';
  end if;

  select id into v_unit_id from public.units where legacy_id = p_unit_legacy_id;
  if v_unit_id is null then
    raise exception 'unit % not found', p_unit_legacy_id;
  end if;

  v_base := lower(regexp_replace(trim(p_full_name), '[^a-zA-Z0-9]+', '_', 'g'));
  v_base := trim(both '_' from v_base);
  if v_base = '' then v_base := 'staff'; end if;
  v_legacy := v_base || '_s';
  while exists (select 1 from public.staff where legacy_id = v_legacy) loop
    v_n := v_n + 1;
    v_legacy := v_base || '_s' || v_n;
  end loop;

  insert into public.staff (
    legacy_id, full_name, email, belt, degree, role_title, initials,
    unit_id, total_classes, journey, feedback, active
  ) values (
    v_legacy,
    trim(p_full_name),
    lower(p_email),
    p_belt,
    p_degree,
    'Professor',
    coalesce(nullif(trim(p_initials), ''),
             upper(substring(regexp_replace(trim(p_full_name),'[^a-zA-Z]','','g') from 1 for 2))),
    v_unit_id,
    0,
    '[]'::jsonb,
    '[]'::jsonb,
    true
  )
  returning * into v_row;

  insert into public.whitelist (email, role, unit_id, invited_by, invited_at)
  values (lower(p_email), 'admin', v_unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = 'admin',
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.add_staff_member(text,text,text,int,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. claim_profile — supersedes 03_auth.sql version.
--    Same behaviour for the public.users row + parent linkage, plus a new
--    step at the end that backfills staff.user_id and students.user_id by
--    email match. The auto-link also runs for existing users on every
--    call, so emails set AFTER the user first signed in still link up on
--    their next request.
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
    -- Run the auto-link every call so a late-set staff.email / students.email
    -- catches up the next time the user authenticates.
    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);
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
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;
