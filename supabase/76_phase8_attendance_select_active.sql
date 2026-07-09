-- 76_phase8_attendance_select_active.sql
-- Cross-unit confirm. A visiting student (home unit ≠ class unit) who checks
-- into a class here creates an attendance row with unit_id = this unit, but
-- the instructor could not SEE the row to confirm it. Two parts:
--
--  1. Re-anchor attendance_select's STAFF clause from the student's home unit
--     to the class's unit (attendance.unit_id), mirroring migration 74 for
--     attendance_update. The visiting student's row (unit_id = the class's
--     unit) then becomes visible to that unit's instructor. Every other
--     clause is unchanged, incl. the adult-peer rule anchored to s.unit_id.
--
--  2. visitor_students_for_unit() — a SECURITY DEFINER helper returning the
--     MINIMAL fields needed to render a cross-unit visitor (name/belt/prog/
--     initials/unit), for STAFF only, and ONLY for students who have an
--     attendance row in a class at the caller's active unit (current_unit())
--     whose home unit differs. This is the bounded, intended exposure: it
--     never returns another unit's roster — only students who physically
--     checked into THIS unit's class. The staff-scoped attendance embed of
--     students is otherwise blocked by students_select (unit-scoped to the
--     student's home unit); a students_select cross-reference to attendance
--     would recurse against attendance_select, so the read runs through this
--     SECURITY DEFINER function instead. students_select is left unchanged.
--
-- Child-safety: this surfaces a student to a staff member solely because the
-- student attended a class at that staff's active unit — not a roster leak.

-- 1. attendance_select — staff clause anchored to the class's unit.
alter policy attendance_select on public.attendance
using (
  is_admin()
  or exists (
    select 1 from public.students s
    where s.id = attendance.student_id
      and (
        s.user_id = auth.uid()
        or s.parent_user_id = auth.uid()
        or (is_staff() and attendance.unit_id = current_unit())
        or (s.unit_id = current_unit() and "current_role"() = 'student'
            and s.prog = 'adult' and attendance.status = 'going')
      )
  )
);

-- 2. Minimal visitor lookup for the active unit's staff. SECURITY DEFINER so
--    the inner students read is not re-filtered by students_select (and no
--    RLS recursion with attendance_select). is_staff() + current_unit()
--    bound it to the caller's own unit; non-staff callers get no rows.
create or replace function public.visitor_students_for_unit()
returns table (
  id        uuid,
  full_name text,
  belt      text,
  prog      text,
  initials  text,
  unit_id   uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select distinct s.id, s.full_name, s.belt, s.prog, s.initials, s.unit_id
  from public.attendance a
  join public.students s on s.id = a.student_id
  where public.is_staff()                                  -- in-body gate: non-staff → 0 rows
    and a.unit_id = public.current_unit()                  -- attended a class at MY unit
    and a.status in ('going','present')                    -- active check-ins only
    and s.unit_id is distinct from public.current_unit()   -- home unit ≠ my unit (visitor)
$$;

grant execute on function public.visitor_students_for_unit() to authenticated;
