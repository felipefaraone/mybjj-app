-- 74_phase8_attendance_update_active.sql
-- Multi-unit epic, cross-unit check-in. Re-anchor attendance_update from the
-- student's home unit to attendance.unit_id (the unit where the class occurred),
-- so the instructor of the active unit can confirm a visiting student's presence
-- (08 §7). Behavior-preserving in single-unit pilot: attendance.unit_id equals the
-- student's unit today, so NB instructors still confirm NB rows unchanged. Diverges
-- only once cross-unit check-ins exist. All 80 live rows have unit_id populated.

drop policy if exists attendance_update on public.attendance;

create policy attendance_update on public.attendance
  for update
  using ( is_staff() and attendance.unit_id = current_unit() )
  with check ( is_staff() );
