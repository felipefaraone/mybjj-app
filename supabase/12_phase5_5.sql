-- =============================================================================
-- myBJJ V1 — Phase 5.5 (Staff management)
-- Run AFTER 11_phase5.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema bump
-- ---------------------------------------------------------------------------
alter table public.staff add column if not exists active boolean default true;
update public.staff set active = true where active is null;

-- ---------------------------------------------------------------------------
-- 2. Loosen staff_select so everyone authenticated sees the staff roster
--    (writes stay gated to admin via the existing staff_write policy, but
--    the RPCs below are SECURITY DEFINER so they bypass RLS anyway).
-- ---------------------------------------------------------------------------
drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff
  for select to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- 3. RPC: add_staff_member  (owner-only)
-- ---------------------------------------------------------------------------
-- Inserts a new staff row + upserts whitelist so the invitee can sign in
-- and have claim_profile pick them up. Returns the inserted staff row.
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

  -- Slugify the name into a stable legacy_id, suffixed to avoid collisions.
  v_base := lower(regexp_replace(trim(p_full_name), '[^a-zA-Z0-9]+', '_', 'g'));
  v_base := trim(both '_' from v_base);
  if v_base = '' then v_base := 'staff'; end if;
  v_legacy := v_base || '_s';
  while exists (select 1 from public.staff where legacy_id = v_legacy) loop
    v_n := v_n + 1;
    v_legacy := v_base || '_s' || v_n;
  end loop;

  insert into public.staff (
    legacy_id, full_name, belt, degree, role_title, initials,
    unit_id, total_classes, journey, feedback, active
  ) values (
    v_legacy,
    trim(p_full_name),
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

  -- New professors get users.role='admin' on first sign-in via claim_profile;
  -- their staff.belt='black' is what the client uses to render the
  -- "Professor" title (see canEditClassCounts / isProfessor in index.html).
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
-- 4. RPC: edit_staff_self  (caller must be the staff row's user)
-- ---------------------------------------------------------------------------
-- Only updates the safe self-editable fields. Belt / degree / unit / role
-- are owner-only and live on edit_staff_admin.
-- ---------------------------------------------------------------------------
create or replace function public.edit_staff_self(
  p_legacy_id text,
  p_payload   jsonb
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.staff;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;
  if v_row.user_id is null or v_row.user_id <> auth.uid() then
    raise exception 'not authorised: you can only edit your own staff profile';
  end if;

  update public.staff set
    full_name = coalesce(p_payload->>'full_name', full_name),
    initials  = coalesce(p_payload->>'initials',  initials),
    journey   = case when p_payload ? 'journey' then p_payload->'journey' else journey end
  where legacy_id = p_legacy_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.edit_staff_self(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. RPC: edit_staff_admin  (owner-only, full edit)
-- ---------------------------------------------------------------------------
create or replace function public.edit_staff_admin(
  p_legacy_id text,
  p_payload   jsonb
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row       public.staff;
  v_unit_id   uuid;
  v_new_role  text;
  v_title     text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if public.current_role() <> 'owner' then
    raise exception 'not authorised: owner only';
  end if;
  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;

  if p_payload ? 'unit_legacy_id' then
    select id into v_unit_id from public.units where legacy_id = p_payload->>'unit_legacy_id';
    if v_unit_id is null then
      raise exception 'unit % not found', p_payload->>'unit_legacy_id';
    end if;
  end if;

  if p_payload ? 'belt' and (p_payload->>'belt') not in ('white','blue','purple','brown','black') then
    raise exception 'invalid belt';
  end if;
  if p_payload ? 'degree' and ((p_payload->>'degree')::int < 0 or (p_payload->>'degree')::int > 6) then
    raise exception 'invalid degree';
  end if;

  update public.staff set
    full_name  = coalesce(p_payload->>'full_name', full_name),
    initials   = coalesce(p_payload->>'initials',  initials),
    belt       = coalesce(p_payload->>'belt',      belt),
    degree     = coalesce((p_payload->>'degree')::int, degree),
    unit_id    = coalesce(v_unit_id, unit_id),
    role_title = coalesce(p_payload->>'role_title', role_title),
    journey    = case when p_payload ? 'journey' then p_payload->'journey' else journey end
  where legacy_id = p_legacy_id
  returning * into v_row;

  -- If the brief's "promote to owner / demote to professor" path was used,
  -- mirror it onto users.role so the auth-side permission checks stay
  -- consistent on the next request.
  if p_payload ? 'role' and v_row.user_id is not null then
    v_new_role := p_payload->>'role';
    if v_new_role not in ('owner','admin') then
      raise exception 'invalid role: must be owner or admin';
    end if;
    update public.users set role = v_new_role where id = v_row.user_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.edit_staff_admin(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. RPC: remove_staff  (owner-only soft delete)
-- ---------------------------------------------------------------------------
create or replace function public.remove_staff(
  p_legacy_id text
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row          public.staff;
  v_other_owners int;
  v_email        text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if public.current_role() <> 'owner' then
    raise exception 'not authorised: owner only';
  end if;
  select * into v_row from public.staff where legacy_id = p_legacy_id;
  if not found then
    raise exception 'staff % not found', p_legacy_id;
  end if;
  if v_row.user_id = auth.uid() then
    raise exception 'cannot remove yourself';
  end if;
  if v_row.role_title = 'Head Professor' then
    select count(*) into v_other_owners
      from public.staff
      where role_title = 'Head Professor'
        and active = true
        and id <> v_row.id;
    if v_other_owners = 0 then
      raise exception 'cannot remove the only owner';
    end if;
  end if;

  update public.staff set active = false where legacy_id = p_legacy_id
    returning * into v_row;

  -- Pull the email from users so we can drop the whitelist row that
  -- granted them access — this is what blocks re-login.
  if v_row.user_id is not null then
    select email into v_email from public.users where id = v_row.user_id;
    if v_email is not null then
      delete from public.whitelist where lower(email) = lower(v_email);
    end if;
  end if;

  return v_row;
end;
$$;

grant execute on function public.remove_staff(text) to authenticated;
