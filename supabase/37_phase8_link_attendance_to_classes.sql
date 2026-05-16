-- =============================================================================
-- Migration 37: Link attendance.class_id to public.classes via legacy_id
-- Run AFTER 36_phase8_seed_classes.sql. Idempotent.
--
-- Migration 36 seeded public.classes with a legacy_id column carrying the
-- old TT id ('m1', 'm2', …). Pre-Etapa-1 attendance rows stored the same
-- string in public.attendance.class_legacy_id (added by 06_phase4.sql).
-- This migration sets attendance.class_id (the real UUID FK) wherever
-- the back-link is currently NULL.
--
-- The class_legacy_id column is kept as a deprecated breadcrumb for now
-- — we may want it during the cutover. Removal is a later batch.
-- =============================================================================

update public.attendance a
   set class_id = c.id
  from public.classes c
 where a.class_id is null
   and a.class_legacy_id is not null
   and c.legacy_id = a.class_legacy_id;

do $$
declare v_unmapped int;
begin
  select count(*) into v_unmapped
    from public.attendance
   where class_id is null
     and class_legacy_id is not null;
  if v_unmapped > 0 then
    raise warning 'Migration 37: % attendance rows could not be mapped to a class', v_unmapped;
  else
    raise notice 'Migration 37: all attendance rows with legacy_id are now linked to class_id';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Count of unmapped rows that *should* have been mapped:
-- select count(*) from public.attendance
--   where class_id is null and class_legacy_id is not null;
-- -- Expect 0.
-- 2. Spot check a few rows:
-- select a.id, a.class_legacy_id, c.legacy_id, c.day_of_week, c.time, c.type
--   from public.attendance a left join public.classes c on c.id = a.class_id
--   where a.class_legacy_id is not null
--   limit 10;
