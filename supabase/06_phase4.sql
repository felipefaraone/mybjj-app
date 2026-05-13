-- =============================================================================
-- myBJJ V1 — SCHEMA additions for Phase 4 (Mutations)
-- Run AFTER 04_schema_v2.sql and 05_seed.sql. Safe to re-run.
-- =============================================================================

-- The prototype's TT timetable has not been migrated to the classes table
-- yet, so attendance rows reference the TT class id by string until that
-- migration lands. class_id stays UUID-nullable; class_legacy_id holds the
-- legacy 'm1','t3', etc.
alter table public.attendance
  add column if not exists class_legacy_id text;

create index if not exists idx_attendance_class_legacy
  on public.attendance(class_legacy_id);
