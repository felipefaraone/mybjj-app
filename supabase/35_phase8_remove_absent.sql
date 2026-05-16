-- =============================================================================
-- Migration 35: Remove 'absent' attendance status
-- Run AFTER 34_phase8_staff_name_cleanup.sql. Idempotent.
--
-- 'absent' adds no actionable insight in practice — a 'going' that never
-- became 'present' already conveys "student committed but did not
-- attend". Simplifies the status model from ('going','present','absent')
-- to ('going','present').
-- =============================================================================

delete from public.attendance where status = 'absent';

alter table public.attendance
  drop constraint if exists attendance_status_check;

alter table public.attendance
  add constraint attendance_status_check
  check (status in ('going','present'));

do $$
declare v_absent int; v_constraint text;
begin
  select count(*) into v_absent from public.attendance where status='absent';
  if v_absent > 0 then
    raise warning 'Still % rows with status=absent after delete', v_absent;
  end if;

  select pg_get_constraintdef(oid) into v_constraint
    from pg_constraint
   where conname = 'attendance_status_check'
     and conrelid = 'public.attendance'::regclass;

  raise notice 'Migration 35: absent remaining = %, check = %', v_absent, v_constraint;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select status, count(*) from public.attendance group by status;
-- -- Expect: only going + present buckets.
-- select pg_get_constraintdef(oid) from pg_constraint
--  where conname='attendance_status_check' and conrelid='public.attendance'::regclass;
-- -- Expect: check (status in ('going','present'))
