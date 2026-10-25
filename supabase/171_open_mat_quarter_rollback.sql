-- 171_open_mat_quarter_rollback.sql
--
-- Undoes 171: drops the trigger and its functions, and puts back the class_value
-- each backed-up row had before the backfill (only where the row is still
-- present at 0.25: a row a coach has since changed or unmarked keeps its value),
-- then recomputes those students. Present open-mat rows marked AFTER 171 are not
-- in the backup and keep 0.25.
-- The backup table public._bak_attendance_openmat_20261025 is kept; drop it by
-- hand once it is no longer needed.

begin;

drop trigger if exists trg_attendance_open_mat_value on public.attendance;

do $$
declare v_ids uuid[]; n int; v uuid;
begin
  if to_regclass('public._bak_attendance_openmat_20261025') is null then
    raise notice '171 rollback: no backup table, no class_value restored';
    return;
  end if;
  execute $q$
    with res as (
      update public.attendance a set "class_value" = b."class_value"
        from public._bak_attendance_openmat_20261025 b
       where a."id" = b."id" and a."status" = 'present' and a."class_value" = 0.25
         and b."class_value" is distinct from 0.25
      returning a."student_id")
    select array_agg(distinct res."student_id"), count(*) from res
  $q$ into v_ids, n;
  foreach v in array coalesce(v_ids, '{}'::uuid[]) loop
    perform public.recompute_student_stats(v);
  end loop;
  raise notice '171 rollback: % row(s) restored from the backup', n;
end $$;

drop function if exists public._attendance_open_mat_backfill();
drop function if exists public._attendance_open_mat_value();
drop function if exists public._is_open_mat(uuid, text);

commit;
