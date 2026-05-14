-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — clean up Correction entries + label suffix
-- Run AFTER 30_phase8_lock_old_auto_journey.sql. Idempotent.
--
-- Journey timeline = student / staff progression story. The previous
-- batch had saveEditStaff add a "Correction" milestone on every
-- downgrade — that polluted the timeline. New behavior (in JS) is to
-- REMOVE the milestone being undone instead. This migration cleans
-- pre-existing data so the timeline starts fresh:
--
--   1. Drop every milestone whose label starts with "Correction"
--      (case-insensitive).
--   2. Strip the " belt promotion" suffix so "Black belt promotion"
--      becomes "Black belt" — matches the clean-label convention.
--
-- Applied to public.students.journey and public.staff.journey.
-- Safe to re-run: the WHERE-EXISTS guard makes each step a no-op
-- once there's nothing left to clean.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Remove Correction entries
-- ---------------------------------------------------------------------------
update public.students s
   set journey = coalesce((
     select jsonb_agg(elem)
       from jsonb_array_elements(s.journey) as elem
      where elem->>'label' is null
         or lower(elem->>'label') not like 'correction%'
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where lower(e->>'label') like 'correction%'
   );

update public.staff s
   set journey = coalesce((
     select jsonb_agg(elem)
       from jsonb_array_elements(s.journey) as elem
      where elem->>'label' is null
         or lower(elem->>'label') not like 'correction%'
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where lower(e->>'label') like 'correction%'
   );

-- ---------------------------------------------------------------------------
-- 2. Strip " belt promotion" suffix
--    "Black belt promotion" → "Black belt". Case-insensitive trail
--    only — we don't touch labels that mention "belt promotion" in
--    the middle of free-text milestones.
-- ---------------------------------------------------------------------------
update public.students s
   set journey = coalesce((
     select jsonb_agg(
       case
         when elem->>'label' is not null
              and lower(elem->>'label') like '% belt promotion'
           then jsonb_set(
                  elem,
                  '{label}',
                  to_jsonb(regexp_replace(elem->>'label', ' belt promotion$', ' belt', 'i'))
                )
         else elem
       end
     )
       from jsonb_array_elements(s.journey) as elem
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where lower(e->>'label') like '% belt promotion'
   );

update public.staff s
   set journey = coalesce((
     select jsonb_agg(
       case
         when elem->>'label' is not null
              and lower(elem->>'label') like '% belt promotion'
           then jsonb_set(
                  elem,
                  '{label}',
                  to_jsonb(regexp_replace(elem->>'label', ' belt promotion$', ' belt', 'i'))
                )
         else elem
       end
     )
       from jsonb_array_elements(s.journey) as elem
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where lower(e->>'label') like '% belt promotion'
   );

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select count(*) from public.students s, jsonb_array_elements(s.journey) e
--  where lower(e->>'label') like 'correction%';
-- -- Expect 0.
-- select count(*) from public.students s, jsonb_array_elements(s.journey) e
--  where lower(e->>'label') like '%belt promotion%';
-- -- Expect 0.
-- (Same for public.staff.)
