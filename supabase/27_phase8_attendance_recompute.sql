-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — attendance → cached stats recompute
-- Run AFTER 26_phase8_notification_prefs.sql. Safe to re-run.
--
-- Problem: students.total / gi_classes / nogi_classes / grade are cached
-- columns the promotion-eligibility logic reads. With persistent
-- attendance (migration 24) they can drift if anyone forgets to update
-- them — and they already have for some seed rows.
--
-- Fix: recompute_student_stats RPC + AFTER INSERT/UPDATE/DELETE trigger
-- on attendance so the cache cannot drift. Also back-fills every
-- existing students row so the v1 piloto starts consistent.
--
-- Notes vs. the spec:
--   * Journey JSON has no `type` field — we use the public.promotions
--     table for the last-promo lookup instead. Falls back to the
--     student row's earliest journey date or created_at.
--   * class_type values in TT are 'fund', 'alev', 'nogi', 'jun', ... —
--     never start with 'gi'. We bucket class_type='nogi' as no-gi and
--     everything else as gi (matches the in-app counter convention).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. recompute_student_stats(uuid)
-- ---------------------------------------------------------------------------
create or replace function public.recompute_student_stats(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total      int;
  v_gi         int;
  v_nogi       int;
  v_grade      int;
  v_gi_grade   int;
  v_last_promo timestamptz;
begin
  if p_student_id is null then
    return;
  end if;

  -- Last belt / stripe date for this student. Source of truth is
  -- public.promotions; if none exist, fall back to the student row
  -- created_at so the "since last promotion" window covers their whole
  -- training history.
  select coalesce(
    (select max(date)::timestamptz from public.promotions where student_id = p_student_id),
    (select created_at from public.students where id = p_student_id),
    now() - interval '100 years'
  ) into v_last_promo;

  -- Count present rows. Gi/nogi split uses the class_type captured at
  -- check-in time. 'nogi' goes to nogi_classes; everything else (fund,
  -- alev, jun, ...) is treated as gi.
  select
    count(*),
    count(*) filter (where coalesce(class_type,'') <> 'nogi'),
    count(*) filter (where coalesce(class_type,'') =  'nogi'),
    count(*) filter (where class_date::timestamptz > v_last_promo),
    count(*) filter (where class_date::timestamptz > v_last_promo
                       and coalesce(class_type,'') <> 'nogi')
    into v_total, v_gi, v_nogi, v_grade, v_gi_grade
   from public.attendance
   where student_id = p_student_id
     and status = 'present';

  update public.students
     set total        = coalesce(v_total,    0),
         gi_classes   = coalesce(v_gi,       0),
         nogi_classes = coalesce(v_nogi,     0),
         grade        = coalesce(v_grade,    0),
         gi_grade     = coalesce(v_gi_grade, 0)
   where id = p_student_id;
end;
$$;

grant execute on function public.recompute_student_stats(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Trigger — recompute after every attendance change (belt + suspenders)
-- ---------------------------------------------------------------------------
create or replace function public.attendance_recompute_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old uuid := case when tg_op in ('UPDATE','DELETE') then OLD.student_id else null end;
  v_new uuid := case when tg_op in ('INSERT','UPDATE') then NEW.student_id else null end;
begin
  -- If the row was reassigned across students (shouldn't happen but
  -- defensive), recompute both sides.
  if v_old is not null then
    perform public.recompute_student_stats(v_old);
  end if;
  if v_new is not null and v_new is distinct from v_old then
    perform public.recompute_student_stats(v_new);
  end if;
  return coalesce(NEW, OLD);
end;
$$;

drop trigger if exists trg_attendance_recompute on public.attendance;
create trigger trg_attendance_recompute
after insert or update or delete on public.attendance
for each row
execute function public.attendance_recompute_trigger();

-- ---------------------------------------------------------------------------
-- 3. Back-fill — bring every existing students row in line with reality.
--    Fixes Felipe's 2-present-rows / total=0 mismatch and any other
--    drift carried over from the in-memory S.ci era.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select id from public.students loop
    perform public.recompute_student_stats(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- 1. Stats match attendance reality:
-- select s.full_name, s.total,
--        (select count(*) from public.attendance a
--          where a.student_id = s.id and a.status='present') as present_rows
--   from public.students s
--   where s.total <> (
--     select count(*) from public.attendance a
--      where a.student_id = s.id and a.status='present'
--   );
-- -- Expect 0 rows.
--
-- 2. Trigger present:
-- select tgname from pg_trigger where tgrelid = 'public.attendance'::regclass;
-- -- Expect trg_attendance_recompute.
