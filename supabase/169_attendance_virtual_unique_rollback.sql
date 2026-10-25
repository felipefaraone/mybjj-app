-- 169_attendance_virtual_unique_rollback.sql
--
-- Undoes 169: drops the partial unique index on one-off attendance. After this,
-- repeated one-off check-ins can insert duplicate rows again (the app no longer
-- double-writes from one tab, but a stale tab or second device can).
-- Does not restore the duplicate rows deleted before 169 was applied; those are
-- in public._bak_attendance_virtual_dupes_20261025.

drop index if exists public.attendance_virtual_occurrence_uq;
