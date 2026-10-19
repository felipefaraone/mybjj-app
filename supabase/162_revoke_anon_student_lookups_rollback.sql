-- Rollback of 162: give anon EXECUTE back on both functions.
begin;
grant execute on function public.search_students_all_units(text) to anon;
grant execute on function public.visitor_students_for_unit() to anon;
commit;
