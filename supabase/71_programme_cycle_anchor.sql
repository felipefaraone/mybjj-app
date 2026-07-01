-- ============================================================
-- Migration 71: Programme cycle anchor
-- 18-week curriculum cycle — anchor date + length per unit.
-- Cycle content lives in programme_weeks (week_index 1..N,
-- week_start NULL for cycle rows); this anchor maps calendar time
-- to the current cycle week. Null anchor = cycle not configured
-- (app falls back to existing week_start behaviour).
-- Applied via Supabase SQL Editor.
-- Rollback: alter table units drop column cycle_anchor_date, drop column cycle_length_weeks;
-- ============================================================

alter table public.units
  add column if not exists cycle_anchor_date date,
  add column if not exists cycle_length_weeks integer not null default 18;

comment on column public.units.cycle_anchor_date is
  'Monday on which cycle week 1 begins/began. Null = cycle not configured. Editable to shift the cycle (e.g. holiday pause).';
comment on column public.units.cycle_length_weeks is
  'Number of weeks in the curriculum cycle (default 18). Loops back to week 1 after this many weeks.';
