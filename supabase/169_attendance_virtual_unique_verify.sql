-- 169_attendance_virtual_unique_verify.sql
--
-- Run AFTER 169, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/169_attendance_virtual_unique_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic rows only: one zz169 student and one zz169 class at the first unit
-- by name, all attendance on Wednesday 23 Jul 2031.

begin;

do $$
declare
  ua uuid; st uuid; cl uuid; n int; v text;
  leg text := '2031-07-23_14:00_oneoff_' || gen_random_uuid()::text;
begin
  -- 0. the columns the inserts below use exist, and the index is the one 169 defines
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'attendance'
     and column_name in ('student_id', 'unit_id', 'class_id', 'class_legacy_id', 'class_date', 'class_time', 'class_type', 'status', 'class_value');
  if n <> 9 then raise exception 'FAIL 0: expected 9 attendance columns, found %', n; end if;
  select indexdef into v from pg_indexes where schemaname = 'public' and indexname = 'attendance_virtual_occurrence_uq';
  if v is null then raise exception 'FAIL 0: attendance_virtual_occurrence_uq is missing'; end if;
  if v not like 'CREATE UNIQUE INDEX attendance_virtual_occurrence_uq ON public.attendance USING btree (student_id, class_legacy_id, class_date) WHERE ((class_id IS NULL) AND (class_legacy_id IS NOT NULL))'
    then raise exception 'FAIL 0: unexpected definition: %', v; end if;
  raise notice 'PASS 0: columns present; index is %', v;

  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz169 Ann A', 'Ann', 'A', 'adult', ua, true, 'ok') returning id into st;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '14:00', 'omat', 60, 'All', true, 'Mixed', 'Open Mat', 'zz169o') returning id into cl;

  -- 1. same student + one-off legacy id + date twice: the second is a unique_violation on 169's index
  insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value)
    values (st, ua, null, leg, '2031-07-23', '14:00', null, 'going', 1.00);
  begin
    insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value)
      values (st, ua, null, leg, '2031-07-23', '14:00', null, 'going', 1.00);
    raise exception 'FAIL 1: second one-off row for the same student/occurrence/date was accepted';
  exception when unique_violation then
    get stacked diagnostics v = constraint_name;
    if v is distinct from 'attendance_virtual_occurrence_uq' then raise exception 'FAIL 1: unique_violation from % instead', v; end if;
  end;
  select count(*) into n from public.attendance where student_id = st and class_legacy_id = leg and class_id is null;
  if n <> 1 then raise exception 'FAIL 1: expected 1 one-off row, found %', n; end if;
  raise notice 'PASS 1: second one-off insert rejected by % (1 row kept)', v;

  -- 2. a row with class_id set is outside the index, even with the same student, legacy id and date
  insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value)
    values (st, ua, cl, leg, '2031-07-23', '14:00', 'omat', 'going', 1.00);
  select count(*) into n from public.attendance where student_id = st and class_id = cl and class_date = '2031-07-23';
  if n <> 1 then raise exception 'FAIL 2: class_id row not written (found %)', n; end if;
  raise notice 'PASS 2: row with class_id set accepted alongside the one-off row';

  -- 3. two privates (class_id and class_legacy_id NULL) for the same student and date are both accepted
  insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value)
    values (st, ua, null, null, '2031-07-23', null, 'private', 'present', 1.00);
  insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value)
    values (st, ua, null, null, '2031-07-23', null, 'private', 'present', 1.00);
  select count(*) into n from public.attendance where student_id = st and class_type = 'private' and class_date = '2031-07-23';
  if n <> 2 then raise exception 'FAIL 3: expected 2 private rows, found %', n; end if;
  raise notice 'PASS 3: two private rows with class_legacy_id NULL both accepted';
end $$;

rollback;
