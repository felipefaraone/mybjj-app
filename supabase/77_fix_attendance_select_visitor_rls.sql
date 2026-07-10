-- 77_fix_attendance_select_visitor_rls.sql
--
-- Cross-unit teacher visibility fix (applied live; this file records it).
--
-- Bug: attendance_select's staff clause was nested INSIDE the EXISTS on
-- public.students:
--
--     EXISTS (SELECT 1 FROM students s WHERE s.id = attendance.student_id
--             AND ( ... OR (is_staff() AND attendance.unit_id = current_unit()) ... ))
--
-- That inner students subquery is itself subject to students_select RLS,
-- which is scoped to the student's HOME unit. When a visiting student
-- (home unit != the class's unit) checked into a class here, the teacher
-- could not see the student's row, so the EXISTS returned no rows — and the
-- staff clause, being trapped inside that EXISTS, never got a chance to
-- match. The confirming teacher therefore could not see the visitor's
-- attendance row at all.
--
-- Fix: hoist the staff clause to the TOP LEVEL of the policy (a plain OR on
-- attendance.unit_id = current_unit()), so it evaluates directly against the
-- attendance row and does NOT depend on being able to read the student's
-- row. Staff now see every attendance row for their active unit regardless
-- of whether students_select would surface that student. The admin,
-- self/parent, and adult-peer clauses are unchanged.

drop policy if exists attendance_select on public.attendance;

create policy attendance_select on public.attendance
for select using (
  public.is_admin()
  OR (public.is_staff() AND attendance.unit_id = public.current_unit())
  OR EXISTS (
    SELECT 1 FROM public.students s WHERE s.id = attendance.student_id AND (
      s.user_id = auth.uid()
      OR s.parent_user_id = auth.uid()
      OR (s.unit_id = public.current_unit() AND public.current_role() = 'student' AND s.prog = 'adult' AND attendance.status = 'going')
    )
  )
);
