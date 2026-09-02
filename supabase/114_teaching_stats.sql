-- 114 — teaching_stats(staff_id, since): read-only aggregate of classes a staff
-- member taught in a window. "Classes taught" = distinct (class_date, class_id)
-- from attendance joined to classes on instructor_id (classes is a weekly
-- template with no occurrence date; the real occurrence lives in attendance).
-- gi/nogi/mixed counted PER CLASS (via classes.uniform), not per attendance.
-- Powers the Teaching card on the professor's Progress > Rank (staff-only in FE).

create or replace function public.teaching_stats(p_staff_id uuid, p_since date)
returns table(taught int, gi int, nogi int, mixed int, weeks numeric, weekly numeric)
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if p_staff_id is null
     or p_staff_id <> (select s.id from public.staff s where s.user_id = auth.uid()) then
    raise exception 'Not authorized to read these teaching stats' using errcode = '42501';
  end if;
  return query
  with aulas as (
    select distinct a.class_date, a.class_id, c.uniform
    from public.attendance a
    join public.classes c on c.id = a.class_id
    where c.instructor_id = p_staff_id and a.class_date >= p_since
  ),
  agg as (
    select count(*)::int as taught,
      count(*) filter (where uniform='Gi')::int as gi,
      count(*) filter (where uniform='No-Gi')::int as nogi,
      count(*) filter (where uniform not in ('Gi','No-Gi') or uniform is null)::int as mixed,
      greatest((current_date - p_since)::numeric / 7.0, 1) as weeks
    from aulas
  )
  select a.taught, a.gi, a.nogi, a.mixed, round(a.weeks,1), round(a.taught / a.weeks, 1) from agg a;
end;
$function$;
