-- 72_phase8_multiunit_schema.sql
-- Multi-unit epic, Batch 1 (schema, additive, behavior-preserving).
-- Adds users.active_unit_id (mutable "active unit"; null => resolves to home on read)
-- and home_unit() (byte-exact copy of today's current_unit() chain, for identity-anchored policies).
-- Does NOT touch current_unit() (Batch 2) or any policy (Batch 3). Nothing calls these yet.

alter table public.users
  add column if not exists active_unit_id uuid references public.units(id);

create or replace function public.home_unit()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
    (select unit_id from public.users    where id      = auth.uid()),
    (select unit_id from public.students where user_id = auth.uid() limit 1),
    (select unit_id from public.staff    where user_id = auth.uid() limit 1),
    (select unit_id from public.students where parent_user_id = auth.uid() limit 1)
  )
$function$;
