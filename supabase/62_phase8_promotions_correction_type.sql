-- 62_phase8_promotions_correction_type.sql
-- Extend the promotions.type CHECK to allow 'correction' so the new
-- Promote modal can record an admin demote / belt fix without
-- bulk-deleting historical rows. The Community Wall renderer filters
-- type='correction' out so corrections don't leak into the feed
-- (frontend: index.html rCommunityWall).
--
-- Idempotent: drops the legacy constraint by name and re-creates with
-- the widened set.

alter table public.promotions drop constraint if exists promotions_type_check;
alter table public.promotions add  constraint promotions_type_check
  check (type in ('belt','stripe','correction'));
