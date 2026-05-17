-- =============================================================================
-- Migration 39: RPC role cleanup
-- Run AFTER 37_phase8_link_attendance_to_classes.sql (38 is reserved /
-- unused). Idempotent — every statement is either CREATE OR REPLACE,
-- DROP IF EXISTS, or guarded with IF EXISTS / IF NOT EXISTS.
--
-- Tightens the post-Batch-2A role taxonomy on the server side. After
-- migration 32 the canonical user role is 'instructor' (the head
-- professor's elevated power moved to units.owner_user_id). 'owner' was
-- flipped to 'instructor' there; 'admin' was historically used by
-- add_staff_member as the whitelist role for new pros but was never a
-- valid users.role value. This migration:
--
--   1. Backfills any residual users.role='admin' / whitelist.role='admin'
--      rows to 'instructor' (parallels migration 32's owner→instructor
--      flip).
--   2. Drops the 6-param add_staff_member overload from 13_phase5_9.sql
--      (superseded by the 7-param version in 15_phase7_fixes.sql).
--   3. Tightens the 7-param add_staff_member: p_role only accepts
--      'professor'; the legacy 'owner' branch is removed. New invites
--      land on whitelist.role='instructor' (was 'admin').
--   4. Tightens edit_staff_admin: when p_payload->>'role' is supplied
--      it must equal 'instructor' (was 'owner'|'admin'). This matches
--      what the frontend has actually sent since Batch 2A (the legacy
--      promote-to-owner path was removed from Edit Staff then).
--   5. edit_staff_self is unchanged (no role parameter).
--   6. update_class_counts is NOT dropped: the frontend still calls it
--      from saveEditCounts (index.html ~line 5118). The architecture
--      target flags it as superseded by trg_attendance_recompute, but
--      that trigger only runs on attendance changes — the manual
--      counter-override path still needs its own RPC. A follow-up
--      batch can refactor the caller; for now we leave the function
--      in place and just tighten its internal role checks here.
--
-- Order of application is critical: the user must pull the
-- companion frontend changes (which stop sending legacy role values
-- and stop treating the head-professor in-memory role as 'owner')
-- BEFORE running this migration. See PR / commit notes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Backfill: users.role='admin' / whitelist.role='admin' → 'instructor'
-- ---------------------------------------------------------------------------
update public.users
   set role = 'instructor'
 where role = 'admin';

update public.whitelist
   set role = 'instructor'
 where role = 'admin';

-- ---------------------------------------------------------------------------
-- 2. Drop the 6-param add_staff_member overload
--    Superseded by 15_phase7_fixes.sql's 7-param version. Dropping it
--    removes the ambiguous overload resolution surface — only the
--    7-param signature should be callable from clients.
-- ---------------------------------------------------------------------------
drop function if exists public.add_staff_member(text, text, text, int, text, text);

-- ---------------------------------------------------------------------------
-- 3. add_staff_member — supersedes 15_phase7_fixes.sql
--    p_role validation tightened to 'professor' only (drops 'owner').
--    whitelist.role for the new invite is 'instructor' (was 'admin'),
--    matching the post-Batch-2A canon. staff.role_title stays
--    'Professor' — title and role are now cleanly separated.
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
  v_unit_id uuid;
  v_legacy  text;
  v_base    text;
  v_n       int := 1;
  v_row     public.staff;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_unit_owner_any() then
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
  if p_role <> 'professor' then
    raise exception 'invalid role: only ''professor'' is supported';
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
  values (lower(p_email), 'instructor', v_unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = 'instructor',
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.add_staff_member(text,text,text,int,text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. edit_staff_admin — supersedes 12_phase5_5.sql
--    When p_payload->>'role' is provided it must equal 'instructor'.
--    The legacy promote-to-owner path is removed; ownership lives on
--    units.owner_user_id and is managed in a separate (future) flow.
--    Owner-only gate is reimplemented via is_unit_owner_any() so the
--    check survives the migration-32 role refactor.
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
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_unit_owner_any() then
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

  -- Optional users.role write-through. Only 'instructor' is accepted;
  -- the legacy 'owner'/'admin' values rejected here so callers that
  -- have drifted off the canonical taxonomy fail loud.
  if p_payload ? 'role' and v_row.user_id is not null then
    v_new_role := p_payload->>'role';
    if v_new_role <> 'instructor' then
      raise exception 'invalid role: must be instructor (post Batch 2A)';
    end if;
    update public.users set role = v_new_role where id = v_row.user_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.edit_staff_admin(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------------
do $$
declare
  v_count        int;
  v_admin_users  int;
  v_admin_wl     int;
begin
  select count(*) into v_count
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('edit_staff_admin', 'edit_staff_self', 'add_staff_member');
  raise notice 'Migration 39: % staff RPCs present (expect 3 — add_staff_member, edit_staff_admin, edit_staff_self)', v_count;

  select count(*) into v_admin_users  from public.users     where role = 'admin';
  select count(*) into v_admin_wl     from public.whitelist where role = 'admin';
  if v_admin_users > 0 or v_admin_wl > 0 then
    raise warning 'Migration 39: residual admin rows — users=%, whitelist=% (expected 0 after backfill)', v_admin_users, v_admin_wl;
  else
    raise notice 'Migration 39: no admin rows remaining';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Verification (run manually post-migration)
-- ---------------------------------------------------------------------------
-- 1. Overload table for the staff RPCs — should be exactly one row per
--    function name:
-- select p.proname, pg_get_function_identity_arguments(p.oid) as args
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname='public'
--     and p.proname in ('add_staff_member','edit_staff_admin','edit_staff_self')
--   order by p.proname;
-- -- Expect 3 rows.
--
-- 2. Role distribution:
-- select role, count(*) from public.users     group by role order by role;
-- select role, count(*) from public.whitelist group by role order by role;
-- -- Expect: users.role in {instructor, student, parent}; no 'admin' or 'owner'.
-- --         whitelist.role in {instructor, student, parent}.
--
-- 3. Smoke an invalid role and confirm it raises:
-- select public.edit_staff_admin('mario_s', '{"role":"owner"}'::jsonb);
-- -- Expect: ERROR invalid role: must be instructor (post Batch 2A)
