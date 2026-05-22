-- 55_phase8_rls_privacy.sql
-- Child-safety / privacy RLS hardening (students/promotions/attendance).
-- "current_role" double-quoted: current_role is a reserved SQL keyword.

alter policy students_select on public.students
using (
  is_admin()
  or (is_staff() and unit_id = current_unit())
  or (user_id = auth.uid())
  or (parent_user_id = auth.uid())
  or (unit_id = current_unit() and "current_role"() = 'student' and prog = 'adult')
);

alter policy promotions_select on public.promotions
using (
  is_admin()
  or exists (
    select 1 from public.students s
    where s.id = promotions.student_id
      and (
        s.user_id = auth.uid()
        or s.parent_user_id = auth.uid()
        or (is_staff() and s.unit_id = current_unit())
      )
  )
);

alter policy attendance_select on public.attendance
using (
  is_admin()
  or exists (
    select 1 from public.students s
    where s.id = attendance.student_id
      and (
        s.user_id = auth.uid()
        or s.parent_user_id = auth.uid()
        or (is_staff() and s.unit_id = current_unit())
        or (s.unit_id = current_unit() and "current_role"() = 'student'
            and s.prog = 'adult' and attendance.status = 'going')
      )
  )
);
