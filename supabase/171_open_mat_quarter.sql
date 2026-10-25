-- ============================================================================
-- 171 — An open mat always counts 0.25
-- ============================================================================
--
-- Head instructor's decision, 25 Oct: ANY open mat counts 0.25 towards
-- progression, with no effort choice. attendance.class_value is otherwise the
-- coach's effort tier (index.html CLASS_VALUE_TIERS: 1.00 / 0.50 / 0.25 / 0.00),
-- unchanged for every other class.
--
-- What is an open mat (one source, mirrored by index.html _isOpenMatOcc):
--   * a recurring class whose classes.level = 'Open Mat'
--     (NB ef90a1e9-cb34-4767-a595-39e111ac766d, CD 7cb48635-c46a-4f78-a817-3242c372004b;
--      both uniform 'Mixed', type 'omat'), by attendance.class_id;
--   * a one-off whose class_exceptions.oneoff_level = 'Open Mat'. Its attendance
--     rows have class_id NULL and class_legacy_id '<date>_<HH:MM>_oneoff_<exception id>'.
--   classes.level and class_exceptions are not created by any file in supabase/
--   (applied to the live database directly, see 155): the preflight checks every
--   column used here in information_schema.
--
-- 1. public._is_open_mat(class_id, legacy id) -> boolean.
-- 2. trg_attendance_open_mat_value, BEFORE INSERT OR UPDATE on attendance: a
--    'present' open-mat row gets class_value 0.25 whatever was sent. 'going' and
--    'absent' rows are not touched.
--    The other attendance triggers in the repo, and how this one fits:
--      trg_attendance_created_by  (163) BEFORE INSERT OR UPDATE, sets created_by
--                                 only. BEFORE triggers fire in name order, so it
--                                 runs first; the two write different columns.
--      trg_attendance_recompute   (27)  AFTER INSERT OR UPDATE OR DELETE, calls
--                                 recompute_student_stats (123's text: sums
--                                 class_value, grade = the day's MAX), so it
--                                 always sees the final 0.25.
--    The preflight prints every trigger the live table has, so one applied
--    outside the repo shows up before anything changes.
-- 3. Backfill: every present open-mat row whose class_value is not 0.25 is first
--    copied to public._bak_attendance_openmat_20261025 (RLS on, no policies),
--    then set to 0.25, and recompute_student_stats runs for each affected
--    student (the AFTER trigger already did per row; this is the guarantee).
--
-- Unchanged: the self check-in bonus (163: one per own row with class_value > 0,
-- and 0.25 > 0), the tiers of every other class, ranking, private lessons.
-- Competitions: a PUBLISHED event (161 competition_publish) and a finalized
-- monthly race (149) read their frozen snapshot in competition_results, which
-- 171 never writes: those results do not move. Live boards and provisional
-- events read attendance through _competition_scores, so they show the new
-- values at once.
--
-- Preview first (read only): 171_preview.sql.
-- Rollback: 171_open_mat_quarter_rollback.sql. Checks: 171_open_mat_quarter_verify.sql.
-- ============================================================================

begin;

do $$
declare
  v_bad text; v_trg text;
begin
  select string_agg(x.t || '.' || x.c, ', ') into v_bad
    from (values ('attendance', 'id'), ('attendance', 'student_id'), ('attendance', 'class_id'),
                 ('attendance', 'class_legacy_id'), ('attendance', 'class_date'), ('attendance', 'status'),
                 ('attendance', 'class_value'), ('classes', 'id'), ('classes', 'level'),
                 ('class_exceptions', 'id'), ('class_exceptions', 'oneoff_level')) x(t, c)
   where not exists (select 1 from information_schema.columns i
                      where i.table_schema = 'public' and i.table_name = x.t and i.column_name = x.c);
  if v_bad is not null then raise exception '171 preflight: missing column(s): %', v_bad; end if;
  if to_regprocedure('public.recompute_student_stats(uuid)') is null then
    raise exception '171 preflight: recompute_student_stats(uuid) is missing';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.attendance'::regclass and tgname = 'trg_attendance_recompute') then
    raise exception '171 preflight: trg_attendance_recompute is missing';
  end if;
  select string_agg(t.tgname || ' -> ' || t.tgfoid::regproc::text, '; ' order by t.tgname) into v_trg
    from pg_trigger t where t.tgrelid = 'public.attendance'::regclass and not t.tgisinternal;
  raise notice '171: attendance triggers before 171: %', coalesce(v_trg, '(none)');
end $$;

-- 1. one source: is this attendance row's class an open mat?
create or replace function public._is_open_mat(p_class_id uuid, p_legacy text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.classes c
                  where c."id" = p_class_id and c."level" = 'Open Mat')
      or (strpos(coalesce(p_legacy, ''), '_oneoff_') > 0
          and exists (select 1 from public.class_exceptions e
                       where e."id"::text = substr(p_legacy, strpos(p_legacy, '_oneoff_') + length('_oneoff_'))
                         and e."oneoff_level" = 'Open Mat'))
$$;

-- 2. a present open-mat row counts 0.25
create or replace function public._attendance_open_mat_value()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW."status" = 'present' and public._is_open_mat(NEW."class_id", NEW."class_legacy_id") then
    NEW."class_value" := 0.25;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_attendance_open_mat_value on public.attendance;
create trigger trg_attendance_open_mat_value
  before insert or update on public.attendance
  for each row execute function public._attendance_open_mat_value();

-- 3. the backfill, as a function so the verify runs the same code. Returns the
--    number of rows changed.
create or replace function public._attendance_open_mat_backfill()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[]; n int; v uuid;
begin
  with upd as (
    update public.attendance a set "class_value" = 0.25
     where a."status" = 'present' and a."class_value" is distinct from 0.25
       and public._is_open_mat(a."class_id", a."class_legacy_id")
    returning a."student_id")
  select array_agg(distinct upd."student_id"), count(*) into v_ids, n from upd;
  foreach v in array coalesce(v_ids, '{}'::uuid[]) loop
    perform public.recompute_student_stats(v);
  end loop;
  return n;
end;
$$;

create table if not exists public._bak_attendance_openmat_20261025 as
  select a.* from public.attendance a
   where a."status" = 'present' and a."class_value" is distinct from 0.25
     and public._is_open_mat(a."class_id", a."class_legacy_id");
alter table public._bak_attendance_openmat_20261025 enable row level security;
revoke all on public._bak_attendance_openmat_20261025 from anon, authenticated;

do $$
declare n int; m int;
begin
  select count(distinct "student_id") into m from public._bak_attendance_openmat_20261025;
  n := public._attendance_open_mat_backfill();
  raise notice '171: % present open-mat row(s) set to 0.25, % student(s) recomputed (backup: _bak_attendance_openmat_20261025)', n, m;
end $$;

revoke all on function public._is_open_mat(uuid, text) from public, anon, authenticated;
revoke all on function public._attendance_open_mat_value() from public, anon, authenticated;
revoke all on function public._attendance_open_mat_backfill() from public, anon, authenticated;

commit;
