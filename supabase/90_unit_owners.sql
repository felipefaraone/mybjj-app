-- 90_unit_owners.sql
-- Ownership becomes a RELATION, not a column.
--
-- WHY: units.owner_user_id is a single uuid — one owner per unit — but three
-- people now need owner-level authority at myBJJ:
--   * Mario    — the actual academy owner, and a professor;
--   * Patricia — operations (add_staff_member hard-requires is_unit_owner_any());
--   * Felipe   — builds the thing.
-- One uuid cannot hold three people, so ownership moves to an N:N table.
--
-- TRAP, recorded so nobody walks into it: users.role = 'owner' is an ORPHANED
-- value. Authority is derived from FUNCTIONS, not the enum — is_admin() reads
-- is_unit_owner_any() ("do you own a unit?") and is_staff() reads
-- current_role() = 'instructor'. A user with role = 'owner' passes NEITHER and
-- ends up with LESS authority than a student. Never set role = 'owner'; grant
-- ownership by inserting into unit_owners instead.
--
-- WHY THIS WAS CHEAP: is_admin() already delegated to is_unit_owner_any(), so
-- rewriting that ONE function (below) re-pointed every policy that gates on
-- is_admin() at the new table for free. Not a single policy was touched.
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). This file is
-- documentation + staging-replay: a fresh DB built from migration files alone must
-- end up identical. Every statement is idempotent, so re-running is a no-op.

-- 1. The relation. Composite PK (unit_id, user_id) — a user owns a unit at most
--    once; both FKs cascade so deleting a unit or a user cleans up its ownership.
create table if not exists public.unit_owners (
  unit_id  uuid not null references public.units(id) on delete cascade,
  user_id  uuid not null references public.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (unit_id, user_id)
);

-- "which units does this user own?" — the hot path for is_unit_owner_any().
create index if not exists uo_user_idx on public.unit_owners(user_id);

-- 2. RLS. Ownership rows are admin-only in both directions; a non-owner never
--    sees or edits them (and the frontend hydrate tolerates the empty result).
alter table public.unit_owners enable row level security;

drop policy if exists uo_select on public.unit_owners;
create policy uo_select on public.unit_owners
  for select to authenticated
  using (public.is_admin());

drop policy if exists uo_write on public.unit_owners;
create policy uo_write on public.unit_owners
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- 3. Backfill the existing single owner of each unit into the relation, so the
--    table is authoritative from the first read. Idempotent via ON CONFLICT.
insert into public.unit_owners (unit_id, user_id)
  select id, owner_user_id
    from public.units
   where owner_user_id is not null
on conflict (unit_id, user_id) do nothing;

-- 4. Reimplement the ownership helpers to read the relation, WITH a fallback to
--    the legacy units.owner_user_id column so nothing breaks in the gap while both
--    the column and the frontend are still populated/read. Signatures unchanged,
--    so every is_admin()/is_unit_owner() caller picked this up untouched.
create or replace function public.is_unit_owner_any()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.unit_owners
     where user_id = auth.uid()
  ) or exists(
    -- LEGACY fallback — remove once units.owner_user_id is retired.
    select 1 from public.units
     where owner_user_id = auth.uid()
  )
$$;

create or replace function public.is_unit_owner(p_unit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.unit_owners
     where unit_id = p_unit_id
       and user_id = auth.uid()
  ) or exists(
    -- LEGACY fallback — remove once units.owner_user_id is retired.
    select 1 from public.units
     where id = p_unit_id
       and owner_user_id = auth.uid()
  )
$$;

-- 5. Mark the column LEGACY so the next reader knows it is superseded but not yet
--    dead: it is still read as a fallback by BOTH the functions above and the
--    frontend isUnitOwner(). Drop it only once both sides are off it.
comment on column public.units.owner_user_id is
  'LEGACY single-owner column, superseded by public.unit_owners (migration 90). '
  'Still read as a fallback by is_unit_owner()/is_unit_owner_any() and by the '
  'frontend isUnitOwner(); do not drop until both are off it.';
