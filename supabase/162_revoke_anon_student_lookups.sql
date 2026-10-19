-- 162: student lookup RPCs are for signed-in staff only.
-- search_students_all_units (SQL Editor, no numbered file) and
-- visitor_students_for_unit (76) are SECURITY DEFINER reads of students.
-- Both gate on is_staff()/is_admin() inside, so anon already got 0 rows;
-- this removes the EXECUTE grant anyway, so the gate is not the only guard.
begin;
revoke execute on function public.search_students_all_units(text) from anon, public;
revoke execute on function public.visitor_students_for_unit() from anon, public;
grant execute on function public.search_students_all_units(text) to authenticated;
grant execute on function public.visitor_students_for_unit() to authenticated;
commit;
