-- 88_trial_scheduling.sql
-- Trial/Waiver Phase 2: turn the public booking page into a real scheduler whose
-- slots are DERIVED from the app's live timetable (move a class in the app, the
-- booking page follows next load — zero maintenance).
--
-- ALREADY APPLIED to the live DB. This file is documentation + staging-replay
-- (a fresh DB built from migration files alone must end up identical). Every
-- statement is idempotent, so re-running is a no-op on the live DB.
--
--   1. trial_bookings gains class_id / class_date / class_time so a booking can
--      point at the exact projected occurrence of a live class, plus an index
--      for the "who's booked into this class on this date" lookup.
--   2. public_timetable re-exposes class_id (appended as the LAST column —
--      CREATE OR REPLACE VIEW refuses to insert a column mid-list) so the public
--      page can send the concrete class the visitor picked. The Edge Function
--      re-validates it server-side against classes; the client is never trusted.
--
-- waiver_token uuid (default gen_random_uuid()) already existed on trial_bookings;
-- there is NO expiry column — TTL is derived from booked_at. Nothing to add here.
--
-- Safety: the view bypasses table RLS by design; access is controlled only by the
-- anon/authenticated GRANT on the view (base tables never granted). No PII exposed.

-- 1. Booking → concrete class occurrence -------------------------------------
alter table public.trial_bookings
  add column if not exists class_id   uuid references public.classes(id),
  add column if not exists class_date date,
  add column if not exists class_time time;

create index if not exists tb_class_idx
  on public.trial_bookings (class_id, class_date);

-- 2. public_timetable — class_id appended as the LAST column ------------------
create or replace view public.public_timetable as
 SELECT c.unit_id,
    u.name AS unit_name,
    c.day_of_week,
        CASE c.day_of_week
            WHEN 0 THEN 'Sunday'::text
            WHEN 1 THEN 'Monday'::text
            WHEN 2 THEN 'Tuesday'::text
            WHEN 3 THEN 'Wednesday'::text
            WHEN 4 THEN 'Thursday'::text
            WHEN 5 THEN 'Friday'::text
            WHEN 6 THEN 'Saturday'::text
            ELSE NULL::text
        END AS day_name,
    to_char(c."time"::interval, 'HH12:MI AM'::text) AS start_time,
    c."time" AS start_time_raw,
    c.duration_minutes,
    c.audience,
    c.type AS type_code,
        CASE lower(c.type)
            WHEN 'nogi'::text THEN 'No-Gi'::text
            WHEN 'gi'::text THEN 'Gi'::text
            WHEN 'alev'::text THEN 'All Levels'::text
            WHEN 'beg'::text THEN 'Beginners'::text
            WHEN 'adv'::text THEN 'Advanced'::text
            WHEN 'fund'::text THEN 'Fundamentals'::text
            WHEN 'mma'::text THEN 'MMA'::text
            WHEN 'jmma'::text THEN 'Junior MMA'::text
            WHEN 'jun'::text THEN 'Juniors'::text
            WHEN 'mini'::text THEN 'Mini Kids'::text
            WHEN 'omat'::text THEN 'Open Mat'::text
            ELSE initcap(c.type)
        END AS type_label,
    c.id AS class_id
   FROM classes c
     JOIN units u ON u.id = c.unit_id
  WHERE c.active IS TRUE
  ORDER BY c.day_of_week, c."time";

revoke all on public.public_timetable from anon;
grant select on public.public_timetable to anon, authenticated;
