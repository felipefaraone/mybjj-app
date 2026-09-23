-- ============================================================================
-- 130 — audit the class timetable
-- ============================================================================
--
-- WHY
--
-- The head instructor changed the instructor on a class, saw the class's whole
-- history move to him, and changed it back. He then asked whether it had
-- affected anything — and the database had no answer.
--
-- classes carried no audit trigger and has no updated_at, so a change to
-- instructor_id left no trace at all. Whether it had happened before him was
-- unanswerable: not "we looked and found nothing", but "there is nowhere to
-- look". He remembered his own change; nobody could have confirmed anyone
-- else's.
--
-- This is the second time in one week that the answer to "did this change?"
-- was "there is no record". The first cost five hours and a data recovery.
--
-- WHY IT MATTERED HERE
--
-- The app stores who is SCHEDULED to teach a class, not who taught a given
-- occurrence. attendance.confirmed_by_instructor_id exists and is null across
-- all 4552 rows; cover is recorded per date in class_exceptions. So every past
-- occurrence resolves through the current template, and changing
-- classes.instructor_id rewrites that class's entire history.
--
-- Migration-free fix shipped alongside (SW v565): changing the instructor now
-- asks whether it applies from now on or to everything, and "from now on"
-- writes an instructor_override per past date naming the outgoing instructor
-- before the template moves.
--
-- COST
--
-- classes holds 91 rows and changes rarely, so the volume is negligible —
-- unlike students.grade, which moves on every check-in.
--
-- THE RULE THIS PRODUCED
--
-- A column that decides who gets credit for something needs an audit trail
-- before it needs a feature. Both incidents this week came from the same gap:
-- a value changed, somebody noticed downstream, and there was no way to say
-- when or by whom.
-- ============================================================================

drop trigger if exists trg_audit_classes on public.classes;
create trigger trg_audit_classes
after insert or update or delete on public.classes
for each row execute function public.audit_row(
  'instructor_id','day_of_week','time','uniform','level','audience',
  'modality','duration_minutes','unit_id','programme_id','active'
);
