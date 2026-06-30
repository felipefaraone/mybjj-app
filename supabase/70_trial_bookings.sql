-- ============================================================
-- Migration 70: Trial bookings + student standing
-- Module 1: trial booking & waiver-as-data
-- NOTE: migration 69 (attendance UNIQUE incl class_date,
--   constraint attendance_student_class_date_uniq) was applied
--   directly in the SQL Editor and never versioned as a file.
--   It is live in the DB. This file picks up the series at 70.
-- ============================================================

-- 1. trial_bookings table (public write surface, isolated from students)
create table if not exists public.trial_bookings (
  id                    uuid primary key default gen_random_uuid(),
  unit_id               uuid references public.units(id),
  first_name            text not null,
  last_name             text not null,
  email                 text not null,
  phone                 text not null,
  how_heard             text,
  preferred_day         text,
  trial_status          text not null default 'booked',
  booked_at             timestamptz not null default now(),
  attended_at           timestamptz,
  lapsed_at             timestamptz,
  waiver_signed_at      timestamptz,
  waiver_signed_by_name text,
  waiver_text_version   text,
  is_kid                boolean not null default false,
  kid_name              text,
  converted_at          timestamptz,
  converted_student_id  uuid references public.students(id),
  admin_note            text,
  created_at            timestamptz not null default now(),
  constraint trial_status_valid check (trial_status in ('booked','attended','lapsed'))
);

create index if not exists idx_trial_bookings_unit   on public.trial_bookings(unit_id);
create index if not exists idx_trial_bookings_status on public.trial_bookings(trial_status);

-- 2. students: standing (ortho to lifecycle) + conversion marker
alter table public.students
  add column if not exists standing     text not null default 'ok',
  add column if not exists hold_note    text,
  add column if not exists converted_at timestamptz;

alter table public.students
  drop constraint if exists students_standing_valid;
alter table public.students
  add constraint students_standing_valid check (standing in ('ok','on_hold'));

-- 3. RLS on trial_bookings
alter table public.trial_bookings enable row level security;

drop policy if exists trial_bookings_public_insert on public.trial_bookings;
create policy trial_bookings_public_insert
  on public.trial_bookings for insert
  to anon, authenticated
  with check (
    trial_status = 'booked'
    and attended_at is null
    and converted_at is null
    and converted_student_id is null
    and lapsed_at is null
  );

drop policy if exists trial_bookings_staff_select on public.trial_bookings;
create policy trial_bookings_staff_select
  on public.trial_bookings for select
  to authenticated
  using (public.is_admin() or unit_id = public.current_unit());

drop policy if exists trial_bookings_staff_update on public.trial_bookings;
create policy trial_bookings_staff_update
  on public.trial_bookings for update
  to authenticated
  using (public.is_admin() or unit_id = public.current_unit())
  with check (public.is_admin() or unit_id = public.current_unit());
