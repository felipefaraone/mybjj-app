-- 92_drop_time_based_attendance_uniq.sql
-- Drop the last (date, time) identity in the system — and the worst one, because
-- it was a CONSTRAINT that silently rejected legitimate inserts.
--
-- WHY: idx_attendance_class_unique was UNIQUE (student_id, class_date, class_time).
-- It asserted "a student cannot be in two classes at the same clock time." That is
-- false, and the academy's own timetable disproves it four times a week —
-- Camperdown runs, simultaneously:
--   * Beginners AND Advanced       — 18:00 Monday
--   * Beginners AND Advanced       — 18:00 Wednesday
--   * Beginners AND Advanced       — 11:00 Saturday
--   * Juniors  AND All Levels      — 10:00 Saturday (children and adults at once)
-- A student legitimately in both halves of any of these pairs hit the unique
-- violation on the second insert.
--
-- It also blocked an intended act: a Neutral Bay student visiting a Camperdown
-- class at the same hour. The client already supports this — it writes
-- attendance.unit_id as the CLASS's unit (not the student's home unit) precisely so
-- a visiting student can be marked present. The index rejected the insert and the
-- UI surfaced it as "Something went wrong. Please try again." — advice that could
-- never work, because the row was correct and the constraint was wrong.
--
-- The CORRECT identity sat right beside it and is untouched:
--   attendance_student_class_date_uniq  UNIQUE (student_id, class_id, class_date)
-- One student, one class, one date — that is what "already on this class" means,
-- and it is exactly what the client's upsert onConflict already targets
-- (onConflict: 'student_id,class_id,class_date').
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). Documentation
-- + staging-replay; idempotent (drop index if exists).

drop index if exists public.idx_attendance_class_unique;

-- Record the sole remaining identity constraint and why it is the right one, so a
-- future reader does not "helpfully" reinstate a time-based unique index.
comment on constraint attendance_student_class_date_uniq on public.attendance is
  'THE identity constraint for attendance: one (student, class, date) row. '
  'Replaces the dropped idx_attendance_class_unique (student_id, class_date, '
  'class_time), which wrongly forbade a student attending two classes at the same '
  'clock time (Camperdown runs concurrent classes) and blocked cross-unit visitors. '
  'Do NOT add any (date, time)-based unique index — class_id is the identity.';
