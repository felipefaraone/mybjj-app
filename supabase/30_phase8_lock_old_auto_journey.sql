-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — back-fill auto:true on old journey entries
-- Run AFTER 29_phase8_admin_change_email.sql. Idempotent.
--
-- Phase 8 started flagging new auto-generated journey entries with
-- `auto: true` so the milestone editor knows to lock label / date /
-- belt. Pre-existing entries (seed rows + everything written before
-- that batch) have no flag, so a typo would still rewrite the audit
-- trail. This migration back-fills the flag on any entry whose label
-- looks system-generated.
--
-- Patterns considered auto (all case-insensitive):
--   - "% belt promotion"   (saveEditStaff belt change)
--   - "%degree%"           (1st/2nd/3rd/Nth degree)
--   - "correction%"        (saveEditStaff downgrade)
--   - "%stripe%"           ("Blue — 1st stripe", "1st stripe", …)
--   - "joined mybjj%"      (claim_profile / seed milestone)
--   - exact "<color> belt" (doPromote shorthand: "Blue belt", "Black belt")
--
-- Entries that already have an `auto` key are left untouched so a
-- user who explicitly set `auto:false` (none today, defensive) keeps
-- their choice. Re-running this migration is safe.
-- =============================================================================

create or replace function public.__journey_is_auto_label(p_label text)
returns boolean
language sql immutable as $$
  select case
    when p_label is null then false
    else (
      lower(p_label) like '%belt promotion%'
      or lower(p_label) like '%degree%'
      or lower(p_label) like 'correction%'
      or lower(p_label) like '%stripe%'
      or lower(p_label) like 'joined mybjj%'
      or lower(p_label) in (
           'white belt','blue belt','purple belt','brown belt','black belt',
           'grey belt','yellow belt','orange belt','green belt'
         )
    )
  end;
$$;

-- ---------------------------------------------------------------------------
-- students.journey
-- ---------------------------------------------------------------------------
update public.students s
   set journey = coalesce((
     select jsonb_agg(
       case
         when (elem ? 'auto') then elem
         when public.__journey_is_auto_label(elem->>'label')
           then elem || '{"auto":true}'::jsonb
         else elem
       end
     )
     from jsonb_array_elements(s.journey) as elem
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where not (e ? 'auto')
        and public.__journey_is_auto_label(e->>'label')
   );

-- ---------------------------------------------------------------------------
-- staff.journey
-- ---------------------------------------------------------------------------
update public.staff s
   set journey = coalesce((
     select jsonb_agg(
       case
         when (elem ? 'auto') then elem
         when public.__journey_is_auto_label(elem->>'label')
           then elem || '{"auto":true}'::jsonb
         else elem
       end
     )
     from jsonb_array_elements(s.journey) as elem
   ), '[]'::jsonb)
 where jsonb_typeof(s.journey) = 'array'
   and exists (
     select 1 from jsonb_array_elements(s.journey) as e
      where not (e ? 'auto')
        and public.__journey_is_auto_label(e->>'label')
   );

drop function if exists public.__journey_is_auto_label(text);

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Count of auto entries (students):
-- select count(*) from public.students s, jsonb_array_elements(s.journey) e
--  where (e->>'auto')::boolean is true;
--
-- 2. Count of auto entries (staff):
-- select count(*) from public.staff st, jsonb_array_elements(st.journey) e
--  where (e->>'auto')::boolean is true;
--
-- 3. Spot check — any students with promotion-like labels still missing the flag:
-- select s.full_name, e->>'label' as label
--   from public.students s, jsonb_array_elements(s.journey) e
--  where not (e ? 'auto')
--    and (
--      lower(e->>'label') like '%belt promotion%'
--      or lower(e->>'label') like '%degree%'
--      or lower(e->>'label') like 'correction%'
--      or lower(e->>'label') like '%stripe%'
--      or lower(e->>'label') like 'joined mybjj%'
--    );
-- -- Expect 0 rows.
