-- 89_public_units.sql
-- Trial/Waiver Phase 2 follow-up. The public booking page (trial.html) needs each
-- academy's ADDRESS on step 1. public_timetable only carries unit_id + unit_name,
-- so the Phase 2 rewrite silently dropped the address the old page showed under
-- each unit card. This view re-exposes the display-safe unit fields the page reads
-- with the publishable key, active units only.
--
-- ALREADY APPLIED to the live DB. This file is documentation + staging-replay
-- (a fresh DB built from migration files alone must end up identical). The
-- statement is idempotent (create or replace), so re-running is a no-op.
--
-- The page also uses legacy_id here to resolve the ?unit=nb|cd deep-link against
-- real data instead of a hard-coded map.
--
-- Safety: the view bypasses table RLS by design; access is controlled only by the
-- anon/authenticated GRANT (base `units` is never granted to anon). Only public,
-- already-on-the-website fields are exposed — no owner_user_id, no internal notes.

create or replace view public.public_units as
 SELECT u.id AS unit_id,
    u.legacy_id,
    u.name AS unit_name,
    u.address,
    u.city,
    u.phone,
    u.email
   FROM units u
  WHERE u.active IS TRUE
  ORDER BY u.name;

revoke all on public.public_units from anon;
grant select on public.public_units to anon, authenticated;
