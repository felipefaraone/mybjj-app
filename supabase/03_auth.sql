-- =============================================================================
-- myBJJ V1 — AUTH PROFILE BOOTSTRAP (Phase 2)
-- Run AFTER 01_schema.sql and 02_rls.sql.
-- The client calls public.claim_profile() right after sign-in.
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

  -- Already onboarded? Return existing row.
  select * into v_existing from public.users where id = v_uid;
  if found then
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

    -- Parent invites attach to the named student.
    if v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id;
    end if;
  else
    -- Not whitelisted: record as pending so admin can see and decide.
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;
