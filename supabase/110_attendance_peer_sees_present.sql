-- 110_attendance_peer_sees_present.sql
-- Adult peers could only see each other's 'going' rows (migration 91, deliberate:
-- "the status='going' guard keeps confirmed/absent records staff-only"). The cost:
-- the moment an instructor confirmed the class everyone flipped to 'present' and
-- the attendee list emptied from the students' view -- "8 going" became "1 going",
-- i.e. the roster disappeared exactly when it became real. Peers now see 'going'
-- AND 'present'. 'absent' stays staff-only: who skipped is not peer business.
-- prog='adult' still keeps kids out of peer view (child safety, unchanged).
drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance
  for select to authenticated
  using (
    public.is_admin()
    or (public.is_staff() and attendance.unit_id = public.current_unit())
    or exists (
      select 1 from public.students s
       where s.id = attendance.student_id
         and (
           s.user_id = auth.uid()
           or s.parent_user_id = auth.uid()
           or (s.unit_id = public.current_unit()
               and s.prog = 'adult'
               and attendance.status in ('going','present')
               and public.is_adult_peer_here())
         )
    )
  );
