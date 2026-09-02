-- 115 — teaching_recent(staff_id, limit): the N most recent classes a staff
-- member TAUGHT (distinct class_date+class_time+uniform via attendance JOIN
-- classes on instructor_id). Powers the "Taught" rows in the professor's
-- Journey Recent, merged client-side with their own attendance ("Trained").
-- Read-only, self-only guard (same as teaching_stats, mig 114).
create or replace function public.teaching_recent(p_staff_id uuid, p_limit int default 20)
returns table(class_date date, class_time text, uniform text)
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if p_staff_id is null
     or p_staff_id <> (select s.id from public.staff s where s.user_id = auth.uid()) then
    raise exception 'Not authorized to read these taught classes' using errcode = '42501';
  end if;
  return query
  select distinct a.class_date, a.class_time, c.uniform
  from public.attendance a
  join public.classes c on c.id = a.class_id
  where c.instructor_id = p_staff_id
  order by a.class_date desc, a.class_time desc
  limit greatest(p_limit, 1);
end;
$function$;
