-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — attendance v2 (date+time+status)
-- Run AFTER 23_phase8_student_full_fields.sql. Safe to re-run.
--
-- The existing public.attendance table (01_schema.sql) keys off
-- attended_at + class_id which never fit the in-memory TT timetable.
-- The check-in flow has been writing to an in-memory S.ci map and
-- never persisting. This migration extends attendance with the columns
-- the new persistent flow needs:
--
--   unit_id     uuid   (which academy)
--   class_date  date   (which day)
--   class_time  text   ('HH:MM' from the timetable)
--   class_type  text   ('alev' / 'nogi' / 'jun' / ...)
--   status      text   'going' | 'present' | 'absent'
--   checked_in_at timestamptz
--   confirmed_by   uuid (auth.uid of staff who confirmed)
--   confirmed_at  timestamptz
--
-- + a partial unique index (student_id, class_date, class_time) so a
--   student can't double-check-in to the same slot.
--
-- + permissive RLS so the linked student can self-INSERT/DELETE their
--   own row; staff (admin / instructor) can confirm = UPDATE status.
-- =============================================================================

alter table public.attendance
  add column if not exists unit_id       uuid references public.units(id),
  add column if not exists class_date    date,
  add column if not exists class_time    text,
  add column if not exists class_type    text,
  add column if not exists status        text default 'going',
  add column if not exists checked_in_at timestamptz default now(),
  add column if not exists confirmed_by  uuid references public.users(id),
  add column if not exists confirmed_at  timestamptz;

alter table public.attendance drop constraint if exists attendance_status_check;
alter table public.attendance add  constraint attendance_status_check
  check (status in ('going','present','absent'));

create unique index if not exists idx_attendance_class_unique
  on public.attendance (student_id, class_date, class_time)
  where class_date is not null and class_time is not null;
create index if not exists idx_attendance_class_date on public.attendance (class_date);
create index if not exists idx_attendance_class_time on public.attendance (class_time);

-- ---------------------------------------------------------------------------
-- RLS — open up SELECT/INSERT/DELETE for self, keep UPDATE staff-only.
-- ---------------------------------------------------------------------------
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
          or (s.unit_id = public.current_unit() and public.current_role() = 'student')
        )
    )
  );

drop policy if exists attendance_insert on public.attendance;
create policy attendance_insert on public.attendance
  for insert to authenticated
  with check (
    public.is_staff()
    or exists (
      select 1 from public.students s
      where s.id = attendance.student_id
        and (s.user_id = auth.uid() or s.parent_user_id = auth.uid())
    )
  );

drop policy if exists attendance_update on public.attendance;
create policy attendance_update on public.attendance
  for update to authenticated
  using  (public.is_staff() and (
    select unit_id from public.students s where s.id = attendance.student_id
  ) = public.current_unit())
  with check (public.is_staff());

drop policy if exists attendance_delete on public.attendance;
create policy attendance_delete on public.attendance
  for delete to authenticated
  using (
    public.is_staff()
    or exists (
      select 1 from public.students s
      where s.id = attendance.student_id
        and (s.user_id = auth.uid() or s.parent_user_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select column_name from information_schema.columns
--   where table_schema='public' and table_name='attendance';
-- select policyname, cmd from pg_policies
--   where schemaname='public' and tablename='attendance';
