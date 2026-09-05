-- 117_staff_units_and_adult_peer.sql
-- 5 September 2026
--
-- PURPOSE
-- Version two objects that were applied directly in the Supabase SQL Editor and
-- never captured as migration files. A database built from the migration files
-- alone (mybjj-staging) is missing both, and both sit in the PERMISSION layer,
-- where a difference does not raise an error — it silently shows or hides people.
--
-- Objects captured here:
--   - table  public.staff_units (+ PK, FKs, index, RLS, policies)
--   - RPC    public.is_adult_peer_here  <-- verbatim from pg_get_functiondef
--
-- Captured EXACTLY as they run in production. Versioning is not the place to
-- change behaviour (see the note in migration 109).
--
-- WHY staff_units EXISTS
-- staff.unit_id says where an instructor APPEARS in the roster; it was never
-- meant to gate access. But an instructor who teaches at both units needs to be
-- listed at both, so the single column could not express it. staff_units is the
-- N:N that can.
--
-- POLICY NOTE — su_select is `true`, deliberately.
-- The obvious move was to mirror unit_owners, which gates on is_admin(). That
-- would have been wrong: unit_owners answers "who owns this place", staff_units
-- answers "who teaches here", and a student has to be able to see their own
-- instructors. Mirroring the wrong parent table would have hidden every
-- instructor from every student, with nothing in the console. The right parent
-- is public.staff, whose select policy is also `true`.
--
-- WHY is_adult_peer_here NO LONGER FILTERS BY UNIT
-- It used to require the viewer to be an adult student OF THE SELECTED UNIT.
-- With the unit picker in the header, that meant switching units emptied the
-- Community tab: the viewer stopped being a "peer here" the moment they looked
-- at the other unit. The unit filter belongs to the picker, not to the identity
-- test. Approved by the head instructor before it went live.

create table if not exists public.staff_units (
  staff_id uuid not null references public.staff(id) on delete cascade,
  unit_id  uuid not null references public.units(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (staff_id, unit_id)
);

create index if not exists staff_units_unit_idx on public.staff_units using btree (unit_id);

alter table public.staff_units enable row level security;

drop policy if exists su_select on public.staff_units;
create policy su_select on public.staff_units
for select using (true);

drop policy if exists su_write on public.staff_units;
create policy su_write on public.staff_units
for all using (public.is_admin()) with check (public.is_admin());

-- Backfill, part 1: every staff row is a member of the unit it already names.
-- Idempotent.
insert into public.staff_units (staff_id, unit_id)
select st.id, st.unit_id
from public.staff st
where st.unit_id is not null
on conflict do nothing;

-- Backfill, part 2: the cross-unit memberships that do NOT follow from
-- staff.unit_id and were added by hand in production. Without this a rebuilt
-- database silently drops the second unit and the instructor stops appearing
-- there, with nothing in the console — the exact failure this table exists to
-- fix. Resolved by email, not by name: staff.email is the key the app already
-- uses to link a person across tables, and two people can share a display name.
insert into public.staff_units (staff_id, unit_id)
select st.id, u.id
from public.staff st
cross join public.units u
where lower(st.email) = 'felipe.silvamma@gmail.com'
  and u.name in ('Neutral Bay','Camperdown')
on conflict do nothing;

create or replace function public.is_adult_peer_here()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists(
    select 1 from public.students s
     where s.user_id = auth.uid()
       and s.prog    = 'adult'
       and s.active  is true
  )
$function$;
