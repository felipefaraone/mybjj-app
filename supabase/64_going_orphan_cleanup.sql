-- 64_going_orphan_cleanup.sql

create or replace function public.cleanup_orphan_going(p_user_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_today date := (now() at time zone 'Australia/Sydney')::date;
  v_now_time time := (now() at time zone 'Australia/Sydney')::time;
begin
  with stu as (
    select id from public.students where user_id = p_user_id
  )
  update public.attendance a
  set status = 'absent'
  where a.status = 'going'
    and a.student_id in (select id from stu)
    and (
      a.class_date < v_today
      or (
        a.class_date = v_today
        and (a.class_time::time + interval '90 minutes') < v_now_time
      )
    );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.cleanup_orphan_going(uuid) to authenticated;

-- One-shot cleanup of legacy orphan 'going' rows across all users.
update public.attendance
set status = 'absent'
where status = 'going'
  and (
    class_date < (now() at time zone 'Australia/Sydney')::date
    or (
      class_date = (now() at time zone 'Australia/Sydney')::date
      and (class_time::time + interval '90 minutes') < (now() at time zone 'Australia/Sydney')::time
    )
  );
