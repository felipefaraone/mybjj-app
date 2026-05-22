-- 57_phase8_kids_summary.sql
-- Kids-privacy aggregate: parents (and staff/admin) get a NON-identifying summary
-- of the kids program in their unit. Parents cannot SELECT other kids' rows (RLS);
-- this SECURITY DEFINER fn returns counts only, never rows / names / photos.

create or replace function public.kids_unit_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit uuid := current_unit();
  v_total int;
  v_by_belt jsonb;
begin
  if not is_approved() then
    raise exception 'not authorized';
  end if;
  if not ("current_role"() = 'parent' or is_staff() or is_admin()) then
    raise exception 'not authorized';
  end if;

  if v_unit is null then
    return jsonb_build_object('total', 0, 'by_belt', '[]'::jsonb);
  end if;

  select count(*) into v_total
  from public.students
  where prog = 'kids' and active and unit_id = v_unit;

  select coalesce(
    jsonb_agg(jsonb_build_object('belt', belt, 'count', c) order by c desc, belt),
    '[]'::jsonb
  )
  into v_by_belt
  from (
    select belt, count(*)::int as c
    from public.students
    where prog = 'kids' and active and unit_id = v_unit
    group by belt
  ) t;

  return jsonb_build_object('total', v_total, 'by_belt', v_by_belt);
end;
$$;

revoke all on function public.kids_unit_summary() from public;
grant execute on function public.kids_unit_summary() to authenticated;
