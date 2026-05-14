-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — last-name placeholder for seeded rows
-- Run AFTER 24_phase8_attendance.sql. Safe to re-run.
--
-- Some seed students were inserted with single-word full_name values
-- ("Felipe", "Aaron", ...). The Add Student form now enforces first +
-- last, and the front-end shows a "Update your last name in Edit
-- profile" nudge whenever it spots the placeholder "NeedsLastName".
-- This back-fill makes existing one-word rows obviously incomplete so
-- the user sees and fixes them.
--
-- Idempotent — only touches rows whose full_name is one token AND
-- doesn't already contain "NeedsLastName".
-- =============================================================================

update public.students
   set full_name = btrim(full_name) || ' NeedsLastName'
 where full_name is not null
   and btrim(full_name) <> ''
   and position(' ' in btrim(full_name)) = 0
   and full_name !~* 'NeedsLastName';

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select full_name from public.students
--   where full_name ilike '%NeedsLastName%';
-- select count(*) as still_one_word
--   from public.students
--  where full_name is not null
--    and position(' ' in btrim(full_name)) = 0;
-- -- Expect 0.
