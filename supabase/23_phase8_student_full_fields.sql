-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — full student profile columns + active flag
-- Run AFTER 22_phase8_email_has_password.sql. Safe to re-run.
--
-- Adds the columns the new "Edit full profile" form writes, plus an
-- `active` flag that powers the soft-delete / inactive-student feature.
-- The existing students_write RLS (admin / staff-of-unit) already covers
-- the new columns, so nothing to change there.
-- =============================================================================

alter table public.students
  add column if not exists date_of_birth          date,
  add column if not exists phone                  text,
  add column if not exists gender                 text,
  add column if not exists weight_kg              int,
  add column if not exists height_cm              int,
  add column if not exists emergency_contact_name  text,
  add column if not exists emergency_contact_phone text,
  add column if not exists active                 boolean not null default true;

create index if not exists idx_students_active on public.students(active);

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select column_name, data_type from information_schema.columns
--   where table_schema='public' and table_name='students'
--     and column_name in ('date_of_birth','phone','gender','weight_kg',
--                         'height_cm','emergency_contact_name',
--                         'emergency_contact_phone','active');
