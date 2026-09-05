-- 118_whitelist_backfill.sql
-- 5 September 2026
--
-- PURPOSE
-- Put every active member's email into public.whitelist. The table itself is
-- versioned (01_schema.sql); what was missing was its CONTENTS.
--
-- THE BUG THIS FIXES
-- public.whitelist is the allow-list every sign-in path consults. When the roster
-- was imported, emails landed in students.email / students.parent_email but never
-- in this table. The consequence was not cosmetic: 319 people could not sign in
-- AT ALL — not by magic link, not by password, not with Google.
--
--   send-magic-link  -> "Email not in whitelist", 400, before anything is sent
--   email_signin_state -> 'not_authorized'
--   claim_profile      -> no whitelist row means the else branch: the user is
--                         created with status 'pending', so even a successful
--                         Google sign-in lands on "Pending approval"
--
-- It surfaced as "Send invite does nothing for this one guy". It was everyone.
--
-- Corrects a claim in doc 09: "Pending approval" does NOT come from a missing
-- students/staff link. It comes from a missing whitelist row.
--
-- WRITTEN AS LOGIC, NOT AS A LIST
-- This is data, not schema, so it must not hard-code the 319 production rows.
-- Run against any database it whitelists whoever is active THERE, which is what
-- a staging rebuild needs.
--
-- ROLE ON COLLISION
-- whitelist.email is the PRIMARY KEY, so one email gets one row and one role.
-- Someone who is both a student and a parent — 28 people in production — is
-- whitelisted as 'student'. Reason: whitelist.role becomes users.role in
-- claim_profile, and current_role() is what RLS reads. Marking a training adult
-- as 'parent' would narrow what she sees as a student, while the reverse costs
-- nothing: claim_profile links children by matching parent_email, not by role.
--
-- student_id stays NULL. claim_profile uses it only for role='parent', and the
-- email match already links every child; a parent with two kids could only fit
-- one there anyway.
--
-- invited_by stays NULL. Nobody invited these people — this is a data repair,
-- and stamping an admin id on 319 rows would fabricate authorship. The batch is
-- identifiable by its shared invited_at instead.

with cand as (
  select lower(btrim(s.email)) as email, 'student'::text as role, s.unit_id, 1 as pri
  from public.students s
  where s.active is true and s.email is not null and btrim(s.email) <> ''
  union all
  select lower(btrim(s.parent_email)), 'parent', s.unit_id, 2
  from public.students s
  where s.active is true and s.parent_email is not null and btrim(s.parent_email) <> ''
  union all
  select lower(btrim(s.parent2_email)), 'parent', s.unit_id, 2
  from public.students s
  where s.active is true and s.parent2_email is not null and btrim(s.parent2_email) <> ''
),
ranked as (
  -- distinct on + order by pri: student (1) wins over parent (2) for the same
  -- address, which is the collision rule above.
  select distinct on (email) email, role, unit_id
  from cand
  where email ~ '^\S+@\S+\.\S+$'
  order by email, pri
)
insert into public.whitelist (email, role, unit_id, student_id, invited_by)
select r.email, r.role, r.unit_id, null, null
from ranked r
on conflict (email) do nothing;
