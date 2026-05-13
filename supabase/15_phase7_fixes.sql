-- =============================================================================
-- myBJJ V1 — Phase 7 fixes
-- Run AFTER 14_phase7.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. photo_url on users + staff so non-student subjects can carry an avatar.
--    students.photo_url stays the canonical source for student rows; users /
--    staff get their own column so the upload flow can update the right
--    table based on the photo subject.
-- ---------------------------------------------------------------------------
alter table public.users add column if not exists photo_url text;
alter table public.staff add column if not exists photo_url text;

-- ---------------------------------------------------------------------------
-- 2. Dev-account label so Mario's future "Owner" entry is unambiguous.
--    Only re-runs the rename if the email row exists.
-- ---------------------------------------------------------------------------
update public.users
   set full_name = 'Felipe Faraone (Dev / Owner)'
 where lower(email) = lower('admin.mybjj@gmail.com');

-- ---------------------------------------------------------------------------
-- 3. add_staff_member — supersedes 13_phase5_9.sql.
--    Takes an optional p_role ('professor' | 'owner'), defaulting to
--    'professor'. Owner-only check still gates the call. When p_role='owner':
--      * staff.role_title  = 'Head Professor'
--      * whitelist.role    = 'owner'
--    Otherwise the previous behaviour is preserved verbatim (whitelist.role
--    = 'admin' so the existing canEditClassCounts client gates still apply
--    to the new pro on first sign-in).
-- ---------------------------------------------------------------------------
create or replace function public.add_staff_member(
  p_full_name      text,
  p_email          text,
  p_belt           text,
  p_degree         int,
  p_unit_legacy_id text,
  p_initials       text,
  p_role           text default 'professor'
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit_id   uuid;
  v_legacy    text;
  v_base      text;
  v_n         int := 1;
  v_row       public.staff;
  v_title     text;
  v_wl_role   text;
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
  if p_role not in ('professor','owner') then
    raise exception 'invalid role';
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

  v_title   := case when p_role = 'owner' then 'Head Professor' else 'Professor' end;
  v_wl_role := case when p_role = 'owner' then 'owner'          else 'admin'     end;

  insert into public.staff (
    legacy_id, full_name, email, belt, degree, role_title, initials,
    unit_id, total_classes, journey, feedback, active
  ) values (
    v_legacy,
    trim(p_full_name),
    lower(p_email),
    p_belt,
    p_degree,
    v_title,
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
  values (lower(p_email), v_wl_role, v_unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = v_wl_role,
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.add_staff_member(text,text,text,int,text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. set_staff_email — owner-only RPC used by the new "Email" field on the
--    Edit Staff modal. Updates staff.email AND keeps the matching whitelist
--    row consistent (so the invite tracking still works after an email
--    change). claim_profile's auto-link already runs on every sign-in, so
--    a fresh email immediately rewires the staff.user_id on next request.
-- ---------------------------------------------------------------------------
create or replace function public.set_staff_email(
  p_legacy_id text,
  p_email     text
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row     public.staff;
  v_old     text;
  v_wl_role text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if public.current_role() <> 'owner' then
    raise exception 'not authorised: owner only';
  end if;
  if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format';
  end if;

  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;
  v_old := v_row.email;

  update public.staff set email = lower(p_email)
    where legacy_id = p_legacy_id
    returning * into v_row;

  v_wl_role := case when v_row.role_title = 'Head Professor' then 'owner' else 'admin' end;

  if v_old is not null and lower(v_old) <> lower(p_email) then
    delete from public.whitelist where lower(email) = lower(v_old);
  end if;

  insert into public.whitelist (email, role, unit_id, invited_by, invited_at)
  values (lower(p_email), v_wl_role, v_row.unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = v_wl_role,
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.set_staff_email(text,text) to authenticated;
