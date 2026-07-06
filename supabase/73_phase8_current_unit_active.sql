-- 73_phase8_current_unit_active.sql
-- Multi-unit epic, Batch 2. current_unit() now follows users.active_unit_id (the
-- dropdown "active unit"), validated against units (exists AND active=true), and
-- falls back to home_unit() when active_unit_id is null OR points to a missing/
-- inactive unit. Behavior-preserving today: active_unit_id is null for all users,
-- so everyone resolves to home_unit() (identical to the pre-batch chain).

create or replace function public.current_unit()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
    (
      select u.id
      from public.units u
      where u.id = (select active_unit_id from public.users where id = auth.uid())
        and u.active = true
    ),
    public.home_unit()
  )
$function$;
