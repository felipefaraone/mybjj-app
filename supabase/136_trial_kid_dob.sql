-- ============================================================================
-- 136 — Child's date of birth on trial bookings
-- ============================================================================
--
-- WHY
-- The head instructor wants a child's date of birth on every child trial: it
-- helps pick the right class and catches a parent who picked the wrong one.
--
-- WHERE
-- public.trial_bookings is the LEAD table: it holds is_kid and kid_name
-- (70_trial_bookings.sql). trial_sessions are per-class occurrences of one lead,
-- and a child's birthday is a fact about the lead, so the column lives here.
-- The staff app reads trial_bookings directly (no view over it in the repo), so
-- no view needs the column.
--
-- NULLABLE, NO CHECK
--  - Every existing lead has no date, and adult leads never will.
--  - An old trial.html still open in a tab during the rollout books without it.
--  - "Not in the future" and "age 2 to 17" depend on current_date, which a CHECK
--    must not use. Validation lives in the trial-booking Edge Function, and
--    "required" is enforced by trial.html.
--
-- ROLLOUT: this file, then deploy trial-booking, then push the pages.
-- Rollback: 136_trial_kid_dob_rollback.sql.
-- ============================================================================

begin;

alter table public.trial_bookings
  add column if not exists kid_dob date;

comment on column public.trial_bookings.kid_dob is
  'Child''s date of birth as given at booking (is_kid rows only). Validated by the trial-booking Edge Function (real date, not future, age 2-17 on the booking date). Never overwritten on a rebooking (migration 136).';

commit;
