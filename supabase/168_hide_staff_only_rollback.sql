-- ============================================================================
-- 168 rollback — members (and guardians) may hide themselves again (149)
-- ============================================================================

begin;

do $$
begin
  if position('-- 168' in coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.set_leaderboard_hidden(uuid, boolean)')), '')) = 0 then
    raise exception '168 rollback: 168 is not applied; stop';
  end if;
end $$;

-- 149's text, exactly.
create or replace function public.set_leaderboard_hidden(p_student uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_hidden is null then
    raise exception 'p_hidden required' using errcode = 'invalid_parameter_value';
  end if;
  if not (exists (select 1 from public.students s where s.id = p_student and s.user_id = auth.uid())
          or coalesce(public.is_guardian_of(p_student, 'manage'), false)
          or coalesce(public.is_admin(), false)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  update public.students set leaderboard_hidden = p_hidden where id = p_student;
  if not found then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
end;
$$;

commit;
