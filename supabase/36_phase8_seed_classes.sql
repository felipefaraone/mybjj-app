-- =============================================================================
-- Migration 36: Seed public.classes with the Neutral Bay timetable
-- Run AFTER 35_phase8_remove_absent.sql. Idempotent.
--
-- Until this batch the schedule lived as a hardcoded TT array in the
-- single-file frontend. The architecture target (Etapa 1) moves it to
-- the database: one row per (unit, day_of_week, time, type) recurring
-- template. Class instances stay virtual — projected per date.
--
-- The base table (01_schema.sql) only carries
-- (id, unit_id, day_of_week, time, type, instructor_id, programme_id,
-- created_at). We extend it here with the columns the frontend needs:
--   legacy_id        text  — old TT id ('m1', 'm2', …) for attendance
--                            back-link (migration 37).
--   duration_minutes int   — class length (45/50/60/90 in TT today).
--   audience         text  — 'Adults' | 'Kids' | 'All' (display label).
--   active           bool  — soft-delete flag so a class can be hidden
--                            without losing attendance history.
--
-- A unique index on (unit_id, day_of_week, time, type) makes the INSERTs
-- below idempotent via ON CONFLICT and prevents duplicate templates.
-- =============================================================================

alter table public.classes
  add column if not exists legacy_id        text,
  add column if not exists duration_minutes int  not null default 60,
  add column if not exists audience         text not null default 'Adults',
  add column if not exists active           bool not null default true;

create unique index if not exists classes_unit_day_time_type_idx
  on public.classes (unit_id, day_of_week, time, type);

create index if not exists classes_legacy_id_idx
  on public.classes (legacy_id);

-- ---------------------------------------------------------------------------
-- Seed the 32 TT rows for Neutral Bay. Staff UUIDs resolved by legacy_id
-- so re-running the migration after staff legacy ids are stable is safe.
-- ---------------------------------------------------------------------------
do $$
declare
  v_unit   uuid;
  v_mario  uuid;
  v_felipe uuid;
  v_john   uuid;
begin
  select id into v_unit
    from public.units
   where legacy_id = 'nb' and active = true;
  if v_unit is null then
    raise exception 'Migration 36: Neutral Bay unit (legacy_id=nb) not found or inactive';
  end if;

  select id into v_mario  from public.staff where legacy_id = 'mario_s'  and active = true;
  select id into v_felipe from public.staff where legacy_id = 'felipe_s' and active = true;
  select id into v_john   from public.staff where legacy_id = 'john_s'   and active = true;
  if v_mario is null or v_felipe is null or v_john is null then
    raise exception 'Migration 36: missing active staff. mario=%, felipe=%, john=%',
      v_mario, v_felipe, v_john;
  end if;

  -- Monday (day_of_week = 1) — 5 classes
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 1, '06:00', 'nogi', v_mario,  'm1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 1, '12:00', 'alev', v_john,   'm2', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 1, '16:00', 'jun',  v_felipe, 'm3', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 1, '17:00', 'jun',  v_felipe, 'm4', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 1, '18:00', 'nogi', v_mario,  'm5', 60, 'Adults') on conflict do nothing;

  -- Tuesday (day_of_week = 2) — 6 classes
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '06:00', 'alev', v_felipe, 't1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '12:00', 'nogi', v_john,   't2', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '16:00', 'jun',  v_john,   't3', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '17:00', 'jun',  v_john,   't4', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '18:00', 'alev', v_mario,  't5', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 2, '18:30', 'beg',  v_mario,  't6', 45, 'Adults') on conflict do nothing;

  -- Wednesday (day_of_week = 3) — 5 classes
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 3, '06:00', 'nogi', v_mario,  'w1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 3, '12:00', 'alev', v_felipe, 'w2', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 3, '16:00', 'jun',  v_john,   'w3', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 3, '17:00', 'jun',  v_john,   'w4', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 3, '18:00', 'nogi', v_mario,  'w5', 60, 'Adults') on conflict do nothing;

  -- Thursday (day_of_week = 4) — 6 classes
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '06:00', 'alev', v_felipe, 'h1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '12:00', 'nogi', v_mario,  'h2', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '16:00', 'jun',  v_felipe, 'h3', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '17:00', 'jun',  v_felipe, 'h4', 50, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '18:00', 'alev', v_john,   'h5', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 4, '18:30', 'beg',  v_john,   'h6', 45, 'Adults') on conflict do nothing;

  -- Friday (day_of_week = 5) — 5 classes; 17:00 has both mma (Adults) and
  -- jmma (Kids) — different types so the unique index is satisfied.
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 5, '06:00', 'nogi', v_john,   'f1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 5, '12:00', 'alev', v_mario,  'f2', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 5, '17:00', 'mma',  v_mario,  'f3', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 5, '17:00', 'jmma', v_felipe, 'f4', 60, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 5, '18:00', 'adv',  v_mario,  'f5', 60, 'Adults') on conflict do nothing;

  -- Saturday (day_of_week = 6) — 5 classes
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 6, '07:30', 'nogi', v_mario,  's1', 60, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 6, '08:30', 'adv',  v_felipe, 's2', 90, 'Adults') on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 6, '09:30', 'omat', v_mario,  's3', 60, 'All')    on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 6, '10:00', 'mini', v_felipe, 's4', 30, 'Kids')   on conflict do nothing;
  insert into public.classes (unit_id, day_of_week, time, type, instructor_id, legacy_id, duration_minutes, audience)
       values (v_unit, 6, '10:30', 'jun',  v_john,   's5', 50, 'Kids')   on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- Sanity assertion
-- ---------------------------------------------------------------------------
do $$
declare
  v_count   int;
  v_unit_id uuid;
begin
  select id into v_unit_id from public.units where legacy_id = 'nb';
  select count(*) into v_count
    from public.classes
   where unit_id = v_unit_id and active = true;
  raise notice 'Migration 36: % classes seeded in Neutral Bay', v_count;
  if v_count <> 32 then
    raise warning 'Migration 36: expected 32 classes, got %', v_count;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select day_of_week, time, type, audience, duration_minutes, legacy_id,
--        (select full_name from public.staff where id = c.instructor_id) as ins
--   from public.classes c
--   where unit_id = (select id from public.units where legacy_id='nb')
--   order by day_of_week, time, type;
-- -- Expect 32 rows in order Mon→Sat.
