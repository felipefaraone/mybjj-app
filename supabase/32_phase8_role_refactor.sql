-- =============================================================================
-- Migration 32: Role refactor — separate ownership from permission
-- Run AFTER 31_phase8_cleanup_correction_milestones.sql. Idempotent.
--
-- Before this migration `role` mixed two ideas: who owns the academy
-- (Mario) and who has admin power. We separate them so admin power can
-- be granted independently of ownership in the future (Mario's wife,
-- partner, manager, etc).
--
-- The shape of the change:
--   1. New column public.units.owner_user_id → who owns this unit.
--   2. The single role='owner' user gets converted to role='instructor'
--      (they ARE an instructor in practice — Mario teaches).
--   3. RLS helpers reimplemented:
--        public.is_admin()        — "owns at least one unit"
--                                   (backwards-compat shim — all
--                                    existing policies that call
--                                    is_admin() keep working)
--        public.is_staff()        — "role = 'instructor'"
--        public.is_unit_owner()   — new, takes a unit id
--        public.is_unit_owner_any() — new
--   4. The one feedback policy that literally tested role='owner'
--      is rewritten to use is_unit_owner_any().
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. units.owner_user_id
-- ---------------------------------------------------------------------------
alter table public.units
  add column if not exists owner_user_id uuid references public.users(id) on delete set null;

create index if not exists units_owner_user_id_idx on public.units(owner_user_id);

-- ---------------------------------------------------------------------------
-- 2. Populate owner_user_id from the existing role='owner' user(s).
--    Map: each unit's owner = the user with role='owner' whose
--    unit_id matches. If a role='owner' user has no unit_id set
--    they don't get linked to any unit — verify post-migration.
-- ---------------------------------------------------------------------------
update public.units u
   set owner_user_id = (
     select usr.id
       from public.users usr
      where usr.role = 'owner'
        and usr.unit_id = u.id
      limit 1
   )
 where owner_user_id is null;

-- ---------------------------------------------------------------------------
-- 3. Convert role='owner' users → role='instructor'
--    Owners ARE instructors in practice. Their elevated admin power
--    now comes from units.owner_user_id, not from a special role value.
-- ---------------------------------------------------------------------------
update public.users
   set role = 'instructor'
 where role = 'owner';

update public.whitelist
   set role = 'instructor'
 where role = 'owner';

-- ---------------------------------------------------------------------------
-- 4. New helpers
-- ---------------------------------------------------------------------------
create or replace function public.is_unit_owner(p_unit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.units
     where id = p_unit_id
       and owner_user_id = auth.uid()
  )
$$;

create or replace function public.is_unit_owner_any()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.units
     where owner_user_id = auth.uid()
  )
$$;

-- ---------------------------------------------------------------------------
-- 5. Reimplement existing helpers
-- ---------------------------------------------------------------------------
-- is_admin() now means "owns at least one unit". Backwards-compatible
-- with every RLS policy that calls is_admin() today — the predicate
-- still returns true for the academy owner, just sourced from
-- units.owner_user_id instead of users.role.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_unit_owner_any()
$$;

-- is_staff() now simpler: just checks role='instructor'. Ownership
-- doesn't grant staff-ness; instructor role does. Ownership is
-- orthogonal (an owner may or may not also be an instructor, though
-- in the pilot Mario is both).
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_role() = 'instructor', false)
$$;

-- ---------------------------------------------------------------------------
-- 6. Update the one policy that literally references 'owner'
-- ---------------------------------------------------------------------------
drop policy if exists feedback_delete on public.feedback;
create policy feedback_delete on public.feedback
  for delete
  using (
    public.is_unit_owner_any()
    or instructor_id in (
      select s.id from public.staff s where s.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 7. Sanity assertions
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner_count        int;
  v_units_without_owner int;
begin
  select count(*) into v_owner_count from public.users where role = 'owner';
  if v_owner_count > 0 then
    raise notice 'WARN: % users still have role=owner after migration', v_owner_count;
  end if;

  select count(*) into v_units_without_owner
    from public.units
   where active = true and owner_user_id is null;
  if v_units_without_owner > 0 then
    raise notice 'WARN: % active units have no owner_user_id', v_units_without_owner;
  end if;

  raise notice 'Migration 32 sanity: % users with role=owner remaining (expected 0), % active units without owner_user_id', v_owner_count, v_units_without_owner;
end $$;

-- ---------------------------------------------------------------------------
-- Verification (run manually post-migration)
-- ---------------------------------------------------------------------------
-- select id, name, owner_user_id from public.units;
-- select id, email, role from public.users where role='owner'; -- expect 0 rows
-- select id, email, role from public.users where role='instructor';
-- select public.is_admin() as is_admin, public.is_staff() as is_staff,
--        public.is_unit_owner_any() as owns_any;
-- select tgname, tgrelid::regclass from pg_trigger where tgname like '%feedback%';
