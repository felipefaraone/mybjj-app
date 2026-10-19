-- Snapshot of a function created in the SQL Editor (no numbered migration).
-- Captured from production on 19 Oct 2026. Reference only: do not re-run blindly.

CREATE OR REPLACE FUNCTION public.search_students_all_units(p_query text)
 RETURNS TABLE(id uuid, legacy_id text, full_name text, belt text, degree integer, prog text, initials text, unit_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select s.id, s.legacy_id, s.full_name, s.belt, s.degree, s.prog, s.initials, s.unit_id
  from public.students s
  where (public.is_staff() or public.is_admin())     -- staff/owner only
    and s.active is not false
    and length(coalesce(trim(p_query),'')) >= 2       -- min 2 chars, no full dump
    and s.full_name ilike '%'||trim(p_query)||'%'
  order by s.full_name
  limit 30
$function$

