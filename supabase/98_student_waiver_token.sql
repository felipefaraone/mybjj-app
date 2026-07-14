-- 98_student_waiver_token.sql
-- Give every EXISTING member a door to the health waiver.
--
-- WHY: the waiver only existed for people who booked a trial. Counted across 389
-- active students on 14 Jul: phone missing on 387, emergency contact on 362, date
-- of birth on 373, gender on 357. If someone is hurt on the mat right now there is
-- nobody to call — not the student, not their emergency contact. The waiver
-- collects exactly what is missing, from the person who actually knows the answer,
-- but it had no entry point for members. This adds one: a per-student token that
-- resolves through the same waiver-submit function the trial links use.
--
-- Mirrors trial_bookings.waiver_token, with ONE deliberate difference: NO TTL. A
-- trial link expires in 60 days because a lead goes cold. A member is a member —
-- their link stays valid until used, so there is no expiry column and the Edge
-- Function skips the age check on this path.
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). This file is
-- documentation + staging-replay: a fresh DB built from migration files alone must
-- end up identical. Every statement is idempotent, so re-running is a no-op. The
-- backfill already covered 389/389 rows; the UPDATE below re-fills only any row
-- still NULL, so it is safe to re-run.

-- 1. Columns (mirror trial_bookings: token + sent + signed timestamps).
alter table public.students
  add column if not exists waiver_token   uuid default gen_random_uuid(),
  add column if not exists waiver_sent_at   timestamptz,
  add column if not exists waiver_signed_at timestamptz;

-- 2. Backfill any row that predates the default (idempotent — only fills NULLs).
update public.students
   set waiver_token = gen_random_uuid()
 where waiver_token is null;

-- 3. One token, one member — and the not-null lets the default do its job for
--    every future insert. A UNIQUE index is what lets waiver-submit resolve a
--    token straight back to a single student.
alter table public.students
  alter column waiver_token set not null;

create unique index if not exists students_waiver_token_key
  on public.students (waiver_token);
