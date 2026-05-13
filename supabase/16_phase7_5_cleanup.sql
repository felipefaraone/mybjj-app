-- =============================================================================
-- myBJJ V1 — Phase 7.5 cleanup
-- Run AFTER 15_phase7_fixes.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. photo_approvals.staff_id — subject column for staff/owner self-uploads
--    so the approval queue can route the approved URL to the right table.
--    The existing student_id column stays for student photos. When BOTH
--    student_id AND staff_id are NULL the row is a "user-self" subject (dev
--    admin / any user without a staff or student linkage) — approval writes
--    to users.photo_url for the submitter (user_id column).
-- ---------------------------------------------------------------------------
alter table public.photo_approvals
  add column if not exists staff_id uuid references public.staff(id) on delete cascade;
create index if not exists idx_photo_approvals_staff on public.photo_approvals(staff_id);

-- ---------------------------------------------------------------------------
-- 2. Fix Prof. John's unit (was hq, real-world he's at Neutral Bay)
-- ---------------------------------------------------------------------------
update public.staff
   set unit_id = (select id from public.units where legacy_id = 'nb')
 where legacy_id = 'john_s';

-- ---------------------------------------------------------------------------
-- 3. Drop the duplicate "John (The Half Guard Prince)" student row — same
--    person as john_s staff. Promotions / feedback / attendance referencing
--    that legacy_id will cascade out below.
-- ---------------------------------------------------------------------------
delete from public.students where legacy_id = 'jhn';

-- ---------------------------------------------------------------------------
-- 4. Orphan cleanup — runs AFTER the John delete so anything that pointed
--    at 'jhn' is cleaned in the same pass.
-- ---------------------------------------------------------------------------
delete from public.promotions     where student_id not in (select id from public.students);
delete from public.feedback       where student_id not in (select id from public.students);
delete from public.attendance     where student_id not in (select id from public.students);
delete from public.photo_approvals where student_id is not null
                                     and student_id not in (select id from public.students);

-- ---------------------------------------------------------------------------
-- 5. Reset events — the seeded 5 events referenced fake student rosters and
--    a fake unit setup; academy now adds real events via the Add Event UI.
-- ---------------------------------------------------------------------------
delete from public.events;

-- ---------------------------------------------------------------------------
-- 6. Verification queries (Console output only — these are SELECTs that
--    return rows in the SQL Editor for the user to eyeball).
-- ---------------------------------------------------------------------------
-- select 'promotions' as t, count(*) from promotions
-- union all select 'events', count(*) from events
-- union all select 'feedback', count(*) from feedback
-- union all select 'attendance', count(*) from attendance
-- union all select 'photo_approvals', count(*) from photo_approvals;
-- select legacy_id, full_name, unit_id from staff order by legacy_id;
-- select count(*) from students where legacy_id = 'jhn';
