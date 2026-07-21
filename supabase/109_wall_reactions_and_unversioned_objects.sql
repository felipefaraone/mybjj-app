-- 109_wall_reactions_and_unversioned_objects.sql
-- 21 July 2026
--
-- PURPOSE
-- Two things at once:
--   (a) FIX a live production bug in wall_reactions_select (details below).
--   (b) VERSION the Community/Wall/Oss-arc objects that were applied directly in
--       the Supabase SQL Editor and never captured as migration files. A database
--       built from the migration files alone (mybjj-staging) was missing them.
--
-- Objects captured here:
--   - table  public.wall_reactions (+ constraints, indexes, RLS)
--   - policy public.wall_reactions_select   <-- FIXED, not verbatim (see below)
--   - RPC    public.toggle_oss              <-- verbatim from pg_get_functiondef
--   - RPC    public.set_event_participation <-- verbatim from pg_get_functiondef
--   - policy public.promotions_select_adult_peer <-- verbatim from pg_policies
--
-- Everything except wall_reactions_select is captured EXACTLY as it runs in
-- production. Versioning is not the place to change behaviour.
--
-- NUMBERING NOTE
-- The wall_reactions_select fix was applied live in the SQL Editor before this
-- file existed. It is folded in here rather than living in a separate earlier
-- file, because a from-scratch rebuild would otherwise try to drop a policy on a
-- table that had not been created yet. Running this whole file against
-- production is safe and idempotent (if not exists / or replace / drop if
-- exists), but unnecessary: production already holds this exact state.
--
-- ---------------------------------------------------------------------------
-- THE BUG THIS FIXES
--
-- toggle_oss (the WRITE path, SECURITY DEFINER) gates on:
--     current_role() in ('student','instructor')
--
-- wall_reactions_select (the READ path) gated on:
--     current_role() in ('student','owner','admin')
--
-- An instructor could therefore WRITE an Oss but never READ it back. The RPC is
-- SECURITY DEFINER so it bypasses RLS: the row was really inserted and the RPC
-- returned {count, reacted:true}, the UI painted the button active, and the next
-- refetch ran under the caller's own RLS, returned zero rows, and the Oss
-- vanished. One production user alone had 13 orphaned rows they could not see.
--
-- This is the same shape recorded in 08-multi-unit-architecture 7b: a
-- SECURITY DEFINER RPC returning the right data masks an RLS bug on the raw
-- fetch. Always test the raw fetch in the real authenticated session.
--
-- 'owner' and 'admin' were orphaned role values. users.role only ever holds
-- 'student', 'instructor', 'parent'; an owner carries role='instructor' plus a
-- row in unit_owners. Verified 21 Jul 2026: select role, count(*) from users
-- returns student=4, instructor=3 and nothing else. They are replaced by
-- is_admin() (= is_unit_owner_any()), which does not depend on the role enum.
--
-- Unit scope and the prog='adult' kids exclusion are UNCHANGED.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. table public.wall_reactions
--    Backs the "Oss" reaction on the Community Wall.
--    FK is ON DELETE CASCADE deliberately: a reaction is not a legal record
--    (contrast health_waivers, which use SET NULL so a signed document survives
--    the deletion of its subject). If the reactor is gone, the reaction goes.
-- ---------------------------------------------------------------------------

create table if not exists public.wall_reactions (
  id               uuid not null default gen_random_uuid(),
  target_type      text not null,
  target_id        uuid not null,
  reactor_user_id  uuid not null,
  kind             text not null default 'oss'::text,
  created_at       timestamp with time zone not null default now(),
  constraint wall_reactions_pkey primary key (id),
  constraint wall_reactions_reactor_user_id_fkey
    foreign key (reactor_user_id) references public.users(id) on delete cascade,
  constraint wall_reactions_target_type_target_id_reactor_user_id_kind_key
    unique (target_type, target_id, reactor_user_id, kind)
);

-- The unique constraint is what makes toggle_oss safe under concurrent taps:
-- one reaction per (target, reactor, kind), enforced by the database rather
-- than by a read-modify-write in the client.

create index if not exists idx_wall_reactions_target
  on public.wall_reactions using btree (target_type, target_id);

create index if not exists idx_wall_reactions_reactor
  on public.wall_reactions using btree (reactor_user_id);

alter table public.wall_reactions enable row level security;

-- ---------------------------------------------------------------------------
-- 2. policy wall_reactions_select  (FIXED — see header)
--    SELECT only. There is no INSERT/UPDATE/DELETE policy by design: every
--    write goes through toggle_oss (SECURITY DEFINER), which is the only place
--    the insert/delete pair is atomic and gated.
--    current_role() MUST be schema-qualified: it is a Postgres reserved word.
-- ---------------------------------------------------------------------------

drop policy if exists wall_reactions_select on public.wall_reactions;

create policy wall_reactions_select on public.wall_reactions
for select using (
  target_type = 'promotion'
  and public.current_status() = 'approved'
  and (public.current_role() in ('student','instructor') or public.is_admin())
  and exists (
    select 1
    from public.promotions p
    join public.students s on s.id = p.student_id
    where p.id = wall_reactions.target_id
      and s.prog = 'adult'
      and (public.is_unit_owner_any() or s.unit_id = public.current_unit())
  )
);

-- ---------------------------------------------------------------------------
-- 3. RPC toggle_oss — verbatim from production (pg_get_functiondef, 21 Jul 2026)
--    Toggles the caller's Oss on a feed target and returns {count, reacted}.
--    The insert/delete + recount happen server-side in one call, which is what
--    removes the read-modify-write race the client would otherwise have.
-- ---------------------------------------------------------------------------

create or replace function public.toggle_oss(p_target_type text, p_target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_ok boolean; v_exist uuid; v_count integer; v_react boolean;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if public.current_status() <> 'approved' then raise exception 'not approved'; end if;
  if public.current_role() not in ('student','instructor') then raise exception 'not allowed'; end if;
  if p_target_type <> 'promotion' then raise exception 'unsupported target type'; end if;

  select true into v_ok
  from public.promotions p
  join public.students s on s.id = p.student_id
  where p.id = p_target_id and s.prog = 'adult'
    and ( public.is_unit_owner_any() or s.unit_id = public.current_unit() )
  limit 1;
  if v_ok is not true then raise exception 'target not visible'; end if;

  select id into v_exist from public.wall_reactions
  where target_type = p_target_type and target_id = p_target_id
    and reactor_user_id = v_uid and kind = 'oss';

  if v_exist is not null then
    delete from public.wall_reactions where id = v_exist;
    v_react := false;
  else
    insert into public.wall_reactions(target_type, target_id, reactor_user_id, kind)
    values (p_target_type, p_target_id, v_uid, 'oss');
    v_react := true;
  end if;

  select count(*) into v_count from public.wall_reactions
  where target_type = p_target_type and target_id = p_target_id and kind = 'oss';

  return jsonb_build_object('count', v_count, 'reacted', v_react);
end $function$;

revoke all on function public.toggle_oss(text, uuid) from public;
grant execute on function public.toggle_oss(text, uuid) to authenticated;

-- NOTE for a future change, not done here: the hard `p_target_type <> 'promotion'`
-- guard (mirrored in the policy above) is why the Wall's "New member" card has no
-- Oss button. A member card is derived from students, not from a promotions row,
-- so there is no stable target to react to. Supporting it needs a 'member' branch
-- in BOTH this RPC and the policy, and that branch MUST carry the same
-- prog='adult' condition, or a kid becomes a reaction target.

-- ---------------------------------------------------------------------------
-- 4. RPC set_event_participation — verbatim from production
--    Any approved unit member marks their OWN participation. Exists because
--    events writes are admin-only (RLS block) and because the array update
--    would otherwise be a read-modify-write race in the client.
-- ---------------------------------------------------------------------------

create or replace function public.set_event_participation(p_event_id uuid, p_status text)
returns events
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_legacy text;
  v_event  public.events;
begin
  if p_status not in ('competing','supporting','none') then
    raise exception 'invalid status: %', p_status;
  end if;

  -- resolve caller's person: student first, then staff
  select legacy_id into v_legacy from students where user_id = auth.uid() limit 1;
  if v_legacy is null then
    select legacy_id into v_legacy from staff where user_id = auth.uid() limit 1;
  end if;
  if v_legacy is null then
    raise exception 'no linked person for caller';
  end if;

  select * into v_event from events where id = p_event_id;
  if v_event.id is null then
    raise exception 'event not found';
  end if;

  -- caller must be approved and a member of the event's unit
  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.status = 'approved'
      and u.unit_id = any(v_event.unit_ids)
  ) then
    raise exception 'not allowed for this event';
  end if;

  update events e set
    competing_legacy_ids = case when p_status = 'competing'
      then array_append(array_remove(coalesce(e.competing_legacy_ids,'{}'::text[]), v_legacy), v_legacy)
      else array_remove(coalesce(e.competing_legacy_ids,'{}'::text[]), v_legacy) end,
    supporting_legacy_ids = case when p_status = 'supporting'
      then array_append(array_remove(coalesce(e.supporting_legacy_ids,'{}'::text[]), v_legacy), v_legacy)
      else array_remove(coalesce(e.supporting_legacy_ids,'{}'::text[]), v_legacy) end
  where e.id = p_event_id
  returning * into v_event;

  return v_event;
end;
$function$;

revoke all on function public.set_event_participation(uuid, text) from public;
grant execute on function public.set_event_participation(uuid, text) to authenticated;

-- KNOWN ISSUE, deliberately preserved verbatim here (fix belongs in its own
-- migration, with its own test): the membership check reads u.unit_id, which is
-- the caller's HOME unit, while everything unit-scoped in this system resolves
-- through current_unit(), the ACTIVE unit. A member whose home unit is Neutral
-- Bay but who is training at Camperdown cannot mark participation on a
-- Camperdown-only event. Same home-vs-active confusion as
-- admin_change_user_email (11-roles-capability-matrix 4.2b), myStudentRow
-- (08-multi-unit-architecture 7c) and canPromote (fixed 21 Jul 2026, SW v342).

-- ---------------------------------------------------------------------------
-- 5. policy promotions_select_adult_peer — verbatim from production
--    Powers the Community Wall: an approved adult student sees other ADULT
--    promotions in their current unit. Kids are excluded (prog='adult').
-- ---------------------------------------------------------------------------

drop policy if exists promotions_select_adult_peer on public.promotions;

create policy promotions_select_adult_peer on public.promotions
for select using (
  public.current_status() = 'approved'
  and public.current_role() = 'student'
  and exists (
    select 1
    from public.students s
    where s.id = promotions.student_id
      and s.prog = 'adult'
      and s.unit_id = public.current_unit()
  )
);

-- KNOWN ISSUE, preserved verbatim: this policy still keys on
-- current_role() = 'student'. Migration 91 replaced exactly this test with
-- is_adult_peer_here() in students_select and attendance_select — deriving the
-- peer right from HAVING an active adult students row in the unit, rather than
-- from the role enum — but this third policy was not migrated with them. A
-- parent who trains (role='parent' plus an adult students row) therefore sees
-- the Wall's promotions through no path here. Zero occupants today: as of
-- 21 Jul 2026 users.role holds only 'student' and 'instructor'. Aligning it is a
-- behaviour change and belongs in its own migration.

commit;

-- ---------------------------------------------------------------------------
-- VERIFY AFTER APPLYING
--
-- select policyname, qual from pg_policies
-- where schemaname='public' and tablename in ('wall_reactions','promotions')
--   and policyname in ('wall_reactions_select','promotions_select_adult_peer');
--
-- select relrowsecurity from pg_class where oid='public.wall_reactions'::regclass;
--
-- select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and proname in ('toggle_oss','set_event_participation');
--
-- STAGING BACKLOG AFTER THIS FILE
-- Cleared: wall_reactions, wall_reactions_select, toggle_oss,
--          set_event_participation, promotions_select_adult_peer.
-- Still unversioned: migrations 95, 96, 96b, 97, 102, 103, plus
--          recompute_student_safety (migration 99 era, never written to a file)
--          and the student_safety / modality objects.
-- ---------------------------------------------------------------------------
