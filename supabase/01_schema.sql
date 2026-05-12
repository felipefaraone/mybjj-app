-- =============================================================================
-- myBJJ V1 — SCHEMA (Phase 1)
-- Paste this into Supabase SQL Editor and run.
-- Safe to re-run: every CREATE uses IF NOT EXISTS.
-- =============================================================================

-- Required extensions
create extension if not exists "pgcrypto";

-- -----------------------------------------------------------------------------
-- UNITS
-- -----------------------------------------------------------------------------
create table if not exists public.units (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  country    text,
  city       text,
  address    text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- USERS (profile row; 1-to-1 with auth.users)
-- -----------------------------------------------------------------------------
create table if not exists public.users (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null unique,
  full_name  text,
  role       text not null check (role in ('admin','owner','instructor','student','parent')),
  unit_id    uuid references public.units(id) on delete set null,
  status     text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
create index if not exists idx_users_unit on public.users(unit_id);

-- -----------------------------------------------------------------------------
-- STUDENTS
-- -----------------------------------------------------------------------------
create table if not exists public.students (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references public.users(id) on delete cascade,
  full_name      text not null,
  belt           text,
  degree         int  default 0,
  prog           int  default 0,
  gi_classes     int  default 0,
  nogi_classes   int  default 0,
  journey        jsonb default '[]'::jsonb,
  notes          text,
  unit_id        uuid references public.units(id) on delete set null,
  parent_user_id uuid references public.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists idx_students_unit   on public.students(unit_id);
create index if not exists idx_students_user   on public.students(user_id);
create index if not exists idx_students_parent on public.students(parent_user_id);

-- -----------------------------------------------------------------------------
-- STAFF
-- -----------------------------------------------------------------------------
create table if not exists public.staff (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.users(id) on delete cascade,
  full_name  text not null,
  belt       text,
  degree     int default 0,
  role_title text,
  journey    jsonb default '[]'::jsonb,
  unit_id    uuid references public.units(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_staff_unit on public.staff(unit_id);
create index if not exists idx_staff_user on public.staff(user_id);

-- -----------------------------------------------------------------------------
-- CLASSES (recurring schedule slots)
-- -----------------------------------------------------------------------------
create table if not exists public.classes (
  id            uuid primary key default gen_random_uuid(),
  unit_id       uuid not null references public.units(id) on delete cascade,
  day_of_week   smallint not null check (day_of_week between 0 and 6),
  time          time not null,
  type          text,
  instructor_id uuid references public.staff(id) on delete set null,
  programme_id  uuid,
  created_at    timestamptz not null default now()
);
create index if not exists idx_classes_unit on public.classes(unit_id);

-- -----------------------------------------------------------------------------
-- ATTENDANCE
-- -----------------------------------------------------------------------------
create table if not exists public.attendance (
  id                         uuid primary key default gen_random_uuid(),
  class_id                   uuid references public.classes(id)  on delete set null,
  student_id                 uuid not null references public.students(id) on delete cascade,
  confirmed_by_instructor_id uuid references public.staff(id)    on delete set null,
  attended_at                timestamptz not null default now(),
  gi                         boolean not null default true
);
create index if not exists idx_attendance_student on public.attendance(student_id);
create index if not exists idx_attendance_when    on public.attendance(attended_at desc);

-- -----------------------------------------------------------------------------
-- PROMOTIONS
-- -----------------------------------------------------------------------------
create table if not exists public.promotions (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references public.students(id) on delete cascade,
  from_belt      text,
  to_belt        text,
  from_deg       int,
  to_deg         int,
  type           text not null check (type in ('belt','stripe')),
  date           date not null default current_date,
  promoted_by_id uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists idx_promotions_student on public.promotions(student_id);
create index if not exists idx_promotions_date    on public.promotions(date desc);

-- -----------------------------------------------------------------------------
-- EVENTS
-- -----------------------------------------------------------------------------
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  unit_ids    uuid[] not null default '{}',
  title       text not null,
  date        date not null,
  type        text,
  description text,
  link        text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_events_date on public.events(date);

-- -----------------------------------------------------------------------------
-- PROGRAMME WEEKS
-- -----------------------------------------------------------------------------
create table if not exists public.programme_weeks (
  id           uuid primary key default gen_random_uuid(),
  unit_id      uuid references public.units(id) on delete cascade,
  week_start   date not null,
  theme        text,
  fundamentals jsonb default '[]'::jsonb,
  mixed        jsonb default '[]'::jsonb,
  advanced     jsonb default '[]'::jsonb,
  kids         jsonb default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  unique (unit_id, week_start)
);

-- -----------------------------------------------------------------------------
-- FEEDBACK
-- -----------------------------------------------------------------------------
create table if not exists public.feedback (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students(id) on delete cascade,
  instructor_id uuid references public.staff(id) on delete set null,
  text          text not null,
  date          date not null default current_date,
  created_at    timestamptz not null default now()
);
create index if not exists idx_feedback_student on public.feedback(student_id);

-- -----------------------------------------------------------------------------
-- PHOTO APPROVALS
-- -----------------------------------------------------------------------------
create table if not exists public.photo_approvals (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.users(id) on delete cascade,
  photo_url      text not null,
  status         text not null default 'pending' check (status in ('pending','approved','rejected')),
  submitted_at   timestamptz not null default now(),
  approved_by_id uuid references public.users(id) on delete set null,
  approved_at    timestamptz
);
create index if not exists idx_photo_status on public.photo_approvals(status);

-- -----------------------------------------------------------------------------
-- WHITELIST (admin pre-approves emails before they sign in)
-- -----------------------------------------------------------------------------
create table if not exists public.whitelist (
  email      text primary key,
  role       text not null check (role in ('admin','owner','instructor','student','parent')),
  unit_id    uuid references public.units(id) on delete set null,
  student_id uuid references public.students(id) on delete set null,
  invited_by uuid references public.users(id) on delete set null,
  invited_at timestamptz not null default now()
);
