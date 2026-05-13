-- =============================================================================
-- myBJJ V1 — SCHEMA v2 (Phase 3a)
-- Adds legacy_id columns and the prototype fields the client already
-- consumes (has_gi, gender, initials, total/grade counters, feedback,
-- programme stand_up/ground, event participant arrays, etc.).
-- Run AFTER 01_schema.sql / 02_rls.sql / 03_auth.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- legacy_id everywhere (text unique) — lets the seed and client look up rows
-- by the prototype's string IDs ('nb','ff','mario_s', ...).
-- ---------------------------------------------------------------------------
alter table public.units           add column if not exists legacy_id text unique;
alter table public.students        add column if not exists legacy_id text unique;
alter table public.staff           add column if not exists legacy_id text unique;
alter table public.promotions      add column if not exists legacy_id text unique;
alter table public.events          add column if not exists legacy_id text unique;
alter table public.programme_weeks add column if not exists legacy_id text unique;

-- ---------------------------------------------------------------------------
-- Students: fields the prototype uses but the V1 schema didn't model yet.
-- ---------------------------------------------------------------------------
alter table public.students add column if not exists has_gi   boolean default true;
alter table public.students add column if not exists gender   text;
alter table public.students add column if not exists initials text;
alter table public.students add column if not exists total    int     default 0;   -- lifetime classes (all)
alter table public.students add column if not exists grade    int     default 0;   -- classes since last promotion (all)
alter table public.students add column if not exists gi_grade int     default 0;   -- classes since last promotion (gi only)
alter table public.students add column if not exists feedback jsonb   default '[]'::jsonb;

-- ---------------------------------------------------------------------------
-- Staff: prototype fields.
-- ---------------------------------------------------------------------------
alter table public.staff add column if not exists initials      text;
alter table public.staff add column if not exists total_classes int   default 0;
alter table public.staff add column if not exists feedback      jsonb default '[]'::jsonb;

-- ---------------------------------------------------------------------------
-- Promotions: display names and the IBJJF "is this a belt or a stripe" flag.
-- unit_id is a denormalised convenience for unit-scoped queries.
-- ---------------------------------------------------------------------------
alter table public.promotions add column if not exists student_name     text;
alter table public.promotions add column if not exists promoted_by_name text;
alter table public.promotions add column if not exists is_new_belt      boolean default false;
alter table public.promotions add column if not exists unit_id          uuid references public.units(id) on delete set null;
create index if not exists idx_promotions_unit on public.promotions(unit_id);

-- ---------------------------------------------------------------------------
-- Events: prototype stores roster arrays as legacy student IDs and a
-- date_text because some events span two days ("28-29 Mar 2026").
-- ---------------------------------------------------------------------------
alter table public.events add column if not exists date_text            text;
alter table public.events add column if not exists competing_legacy_ids text[] default '{}';
alter table public.events add column if not exists supporting_legacy_ids text[] default '{}';
alter table public.events add column if not exists unit_legacy_ids      text[] default '{}';

-- ---------------------------------------------------------------------------
-- Programme weeks: align with the prototype's SCHED shape.
-- ---------------------------------------------------------------------------
alter table public.programme_weeks add column if not exists week_index int;
alter table public.programme_weeks add column if not exists programs   text[] default '{}';
alter table public.programme_weeks add column if not exists color      text;
alter table public.programme_weeks add column if not exists notes      text;
alter table public.programme_weeks add column if not exists stand_up   jsonb default '[]'::jsonb;
alter table public.programme_weeks add column if not exists ground     jsonb default '[]'::jsonb;
