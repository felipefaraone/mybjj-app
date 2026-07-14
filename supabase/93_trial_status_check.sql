-- 93_trial_status_check.sql
-- One CHECK for the full trial funnel.
--
-- WHY: Phase 3 drives a lead through booked → attended → no_show / converted /
-- lapsed, so the office can `group by trial_status` and read the funnel (how many
-- booked, came, vanished, joined). But trial_bookings carried TWO contradictory
-- CHECK constraints on trial_status:
--   * trial_status_valid          — the original (migration 70), limited to
--                                    (booked, attended, lapsed);
--   * trial_bookings_status_check — the intended full set.
-- A row must satisfy EVERY check, so the strict one wins: it would have SILENTLY
-- rejected every 'no_show' and 'converted' write Phase 3 makes — the mark-no-show
-- and convert actions would fail with a constraint violation the UI shows as
-- "Something went wrong." Collapse to ONE check with the full set.
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). Documentation
-- + staging-replay; idempotent (drop-if-exists + add).

alter table public.trial_bookings drop constraint if exists trial_status_valid;
alter table public.trial_bookings drop constraint if exists trial_bookings_status_check;
alter table public.trial_bookings add  constraint trial_bookings_status_check
  check (trial_status in ('booked','attended','no_show','converted','lapsed'));
