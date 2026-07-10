-- Migration 78 — public schedule views (schedule expose: "app exposes, site pulls")
--
-- Captures two previously-unversioned live objects so a fresh DB (e.g. mybjj-staging)
-- built from migration files alone has them. Both are public read-only views the
-- academy website pulls via PostgREST with the anon key; the app is the source of
-- truth and never writes into WordPress.
--
--   public_curriculum — weekly curriculum (programme_weeks + units), with cycle_week
--                       and is_current_week computed from units.cycle_anchor_date.
--   public_timetable  — active class grid (classes + units), with human-readable
--                       day_name, HH12:MI AM start_time, and type_label for all live codes.
--
-- Safety: views bypass table RLS by design; access is controlled only by the anon
-- GRANT on the views (base tables never granted to anon). No PII exposed.
-- Grants hardening: live views had ALL privileges granted to anon (inert, since both
-- views are non-updatable) — this revokes them and grants SELECT only.

create or replace view public.public_curriculum as
 SELECT pw.unit_id,
    u.name AS unit_name,
    pw.week_index,
    pw.week_start,
    pw.theme,
    pw.programs,
    pw.fundamentals,
    pw.mixed,
    pw.advanced,
    pw.kids,
    pw.stand_up,
    pw.ground,
        CASE
            WHEN u.cycle_anchor_date IS NULL THEN NULL::integer
            ELSE (floor((CURRENT_DATE - u.cycle_anchor_date)::numeric / 7.0)::integer % GREATEST(COALESCE(u.cycle_length_weeks, 18), 1) + GREATEST(COALESCE(u.cycle_length_weeks, 18), 1)) % GREATEST(COALESCE(u.cycle_length_weeks, 18), 1) + 1
        END AS cycle_week,
        CASE
            WHEN u.cycle_anchor_date IS NULL THEN false
            ELSE pw.week_index = ((floor((CURRENT_DATE - u.cycle_anchor_date)::numeric / 7.0)::integer % GREATEST(COALESCE(u.cycle_length_weeks, 18), 1) + GREATEST(COALESCE(u.cycle_length_weeks, 18), 1)) % GREATEST(COALESCE(u.cycle_length_weeks, 18), 1) + 1)
        END AS is_current_week
   FROM programme_weeks pw
     JOIN units u ON u.id = pw.unit_id
  ORDER BY pw.week_index;

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
        END AS type_label
   FROM classes c
     JOIN units u ON u.id = c.unit_id
  WHERE c.active IS TRUE
  ORDER BY c.day_of_week, c."time";

revoke all on public.public_curriculum from anon;
revoke all on public.public_timetable from anon;
grant select on public.public_curriculum to anon;
grant select on public.public_timetable to anon;
