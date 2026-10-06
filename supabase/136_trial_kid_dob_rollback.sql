-- 136_trial_kid_dob_rollback.sql
--
-- Undo 136_trial_kid_dob.sql.
--
-- ORDER MATTERS: redeploy the PREVIOUS trial-booking Edge Function first. The
-- 136 version selects, inserts and updates kid_dob, so once this column is gone
-- every booking through it would fail until it is replaced.
--
-- DROPS DATA: every child date of birth captured since 136. Export it first:
--   select id, kid_name, kid_dob from public.trial_bookings where kid_dob is not null;

begin;

alter table public.trial_bookings
  drop column if exists kid_dob;

commit;
