-- 116 — teaching_all(staff_id, since): full list of classes a staff member
-- TAUGHT in a window (since=null → all time), for the instructor "all my classes"
-- attendance history. Same shape/guard as teaching_recent (mig 115) but no
-- 20-row cap and an optional date floor for the 30d/90d/all-time filters.
-- The FE merges these (tagged Taught) with the staff's own attendance (Trained).
create or replace function public.teaching_all(p_staff_id uuid, p_since date default null)
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
    and (p_since is null or a.class_date >= p_since)
  order by a.class_date desc, a.class_time desc
  limit 500;
end;
$function$;
