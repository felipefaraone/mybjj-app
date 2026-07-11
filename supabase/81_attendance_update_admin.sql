-- 81_attendance_update_admin.sql
-- Bug: attendance_update was the only attendance policy WITHOUT the is_admin()
-- short-circuit. is_staff() = (current_role()='instructor'), so an OWNER
-- (role='owner') fails it and cannot Undo/re-status an attendance row even in
-- their own unit. Add is_admin() to match attendance_select/insert/delete.
alter policy attendance_update on public.attendance
  using (public.is_admin() OR (public.is_staff() AND unit_id = public.current_unit()))
  with check (public.is_admin() OR public.is_staff());
