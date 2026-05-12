-- =============================================================================
-- myBJJ V1 — ROW LEVEL SECURITY (Phase 1)
-- Run AFTER 01_schema.sql.
-- Safe to re-run: every policy DROPs before CREATE.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helper functions (security definer so they bypass RLS on public.users)
-- -----------------------------------------------------------------------------
create or replace function public.current_role()
returns text
language sql stable security definer set search_path = public
as $$
  select role from public.users where id = auth.uid()
$$;

create or replace function public.current_unit()
returns uuid
language sql stable security definer set search_path = public
as $$
  select unit_id from public.users where id = auth.uid()
$$;

create or replace function public.current_status()
returns text
language sql stable security definer set search_path = public
as $$
  select status from public.users where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_role() in ('admin','owner'), false)
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_role() in ('admin','owner','instructor'), false)
$$;

create or replace function public.is_approved()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_status() = 'approved', false)
$$;

-- -----------------------------------------------------------------------------
-- Enable RLS on every table
-- -----------------------------------------------------------------------------
alter table public.units            enable row level security;
alter table public.users            enable row level security;
alter table public.students         enable row level security;
alter table public.staff            enable row level security;
alter table public.classes          enable row level security;
alter table public.attendance       enable row level security;
alter table public.promotions       enable row level security;
alter table public.events           enable row level security;
alter table public.programme_weeks  enable row level security;
alter table public.feedback         enable row level security;
alter table public.photo_approvals  enable row level security;
alter table public.whitelist        enable row level security;

-- -----------------------------------------------------------------------------
-- UNITS — everyone authenticated can read; only admin/owner can write
-- -----------------------------------------------------------------------------
drop policy if exists units_select on public.units;
create policy units_select on public.units
  for select to authenticated using (true);

drop policy if exists units_write on public.units;
create policy units_write on public.units
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- USERS — read own row; admin reads all; admin writes all; anyone can insert own row at signup
-- -----------------------------------------------------------------------------
drop policy if exists users_select_self on public.users;
create policy users_select_self on public.users
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists users_insert_self on public.users;
create policy users_insert_self on public.users
  for insert to authenticated
  with check (id = auth.uid() or public.is_admin());

drop policy if exists users_update_self on public.users;
create policy users_update_self on public.users
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

drop policy if exists users_delete_admin on public.users;
create policy users_delete_admin on public.users
  for delete to authenticated
  using (public.is_admin());

-- -----------------------------------------------------------------------------
-- STUDENTS — admin all; staff sees own unit; student sees self + own unit roster; parent sees own child
-- -----------------------------------------------------------------------------
drop policy if exists students_select on public.students;
create policy students_select on public.students
  for select to authenticated
  using (
    public.is_admin()
    or (public.is_staff() and unit_id = public.current_unit())
    or (user_id = auth.uid())
    or (unit_id = public.current_unit() and public.current_role() = 'student')
    or (parent_user_id = auth.uid())
  );

drop policy if exists students_write on public.students;
create policy students_write on public.students
  for all to authenticated
  using (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()))
  with check (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()));

-- -----------------------------------------------------------------------------
-- STAFF — anyone in same unit can read; admin writes
-- -----------------------------------------------------------------------------
drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff
  for select to authenticated
  using (public.is_admin() or unit_id = public.current_unit());

drop policy if exists staff_write on public.staff;
create policy staff_write on public.staff
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- CLASSES — read by same unit; write by staff of unit / admin
-- -----------------------------------------------------------------------------
drop policy if exists classes_select on public.classes;
create policy classes_select on public.classes
  for select to authenticated
  using (public.is_admin() or unit_id = public.current_unit());

drop policy if exists classes_write on public.classes;
create policy classes_write on public.classes
  for all to authenticated
  using (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()))
  with check (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()));

-- -----------------------------------------------------------------------------
-- ATTENDANCE — student sees own; staff sees own unit; admin all; insert by staff only
-- -----------------------------------------------------------------------------
drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.students s
      where s.id = attendance.student_id
        and (
          s.user_id = auth.uid()
          or s.parent_user_id = auth.uid()
          or (public.is_staff() and s.unit_id = public.current_unit())
        )
    )
  );

drop policy if exists attendance_insert on public.attendance;
create policy attendance_insert on public.attendance
  for insert to authenticated
  with check (public.is_staff());

drop policy if exists attendance_update on public.attendance;
create policy attendance_update on public.attendance
  for update to authenticated
  using (public.is_staff())
  with check (public.is_staff());

drop policy if exists attendance_delete on public.attendance;
create policy attendance_delete on public.attendance
  for delete to authenticated
  using (public.is_admin());

-- -----------------------------------------------------------------------------
-- PROMOTIONS — same visibility model as students; staff write
-- -----------------------------------------------------------------------------
drop policy if exists promotions_select on public.promotions;
create policy promotions_select on public.promotions
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.students s
      where s.id = promotions.student_id
        and (
          s.user_id = auth.uid()
          or s.parent_user_id = auth.uid()
          or s.unit_id = public.current_unit()
        )
    )
  );

drop policy if exists promotions_write on public.promotions;
create policy promotions_write on public.promotions
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- -----------------------------------------------------------------------------
-- EVENTS — readable when user's unit is in unit_ids (or admin); admin writes
-- -----------------------------------------------------------------------------
drop policy if exists events_select on public.events;
create policy events_select on public.events
  for select to authenticated
  using (public.is_admin() or public.current_unit() = any(unit_ids));

drop policy if exists events_write on public.events;
create policy events_write on public.events
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- PROGRAMME WEEKS — read by same unit; write by staff
-- -----------------------------------------------------------------------------
drop policy if exists programme_select on public.programme_weeks;
create policy programme_select on public.programme_weeks
  for select to authenticated
  using (public.is_admin() or unit_id = public.current_unit());

drop policy if exists programme_write on public.programme_weeks;
create policy programme_write on public.programme_weeks
  for all to authenticated
  using (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()))
  with check (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()));

-- -----------------------------------------------------------------------------
-- FEEDBACK — student/parent reads own; staff reads same unit; staff writes
-- -----------------------------------------------------------------------------
drop policy if exists feedback_select on public.feedback;
create policy feedback_select on public.feedback
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.students s
      where s.id = feedback.student_id
        and (
          s.user_id = auth.uid()
          or s.parent_user_id = auth.uid()
          or (public.is_staff() and s.unit_id = public.current_unit())
        )
    )
  );

drop policy if exists feedback_write on public.feedback;
create policy feedback_write on public.feedback
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- -----------------------------------------------------------------------------
-- PHOTO APPROVALS — user reads/inserts own; admin reads/updates all
-- -----------------------------------------------------------------------------
drop policy if exists photo_select on public.photo_approvals;
create policy photo_select on public.photo_approvals
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists photo_insert on public.photo_approvals;
create policy photo_insert on public.photo_approvals
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists photo_update on public.photo_approvals;
create policy photo_update on public.photo_approvals
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- WHITELIST — admin only (also readable anon during signup check via RPC, handled in Phase 2)
-- -----------------------------------------------------------------------------
drop policy if exists whitelist_admin on public.whitelist;
create policy whitelist_admin on public.whitelist
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());
