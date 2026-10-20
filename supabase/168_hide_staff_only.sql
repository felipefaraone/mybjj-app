-- ============================================================================
-- 168 — Only staff hide someone from the leaderboard
-- ============================================================================
--
-- John (20 Oct): members can no longer hide themselves, "so everyone always
-- shows". Felipe: staff and admin keep the ability to hide someone on request
-- (rare: privacy or safety); 166's rule (a hidden member shows as "Anonymous"
-- to other members) stays for those cases.
--
-- set_leaderboard_hidden (149): is_staff() or is_admin() only, for any member;
-- a member, or a guardian for a kid, gets insufficient_privilege. Same
-- signature and grants (create or replace). No data change.
--
-- Rollback: 168_hide_staff_only_rollback.sql (149's text exactly).
-- Checks: 168_hide_staff_only_verify.sql.
-- ============================================================================

begin;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.set_leaderboard_hidden(uuid, boolean)');
  if v_src is null then
    raise exception '168 preflight: set_leaderboard_hidden(uuid, boolean) not found';
  end if;
  -- production must still be 149's text (or 168's: a re-run)
  if md5(v_src) <> 'a04fc3c2c3a9d33d8a8472027c75c856' and position('-- 168' in v_src) = 0 then
    raise exception '168 preflight: set_leaderboard_hidden is not 149''s text; stop and compare';
  end if;
  if to_regprocedure('public.is_staff()') is null or to_regprocedure('public.is_admin()') is null then
    raise exception '168 preflight: is_staff() / is_admin() missing';
  end if;
end $$;

-- 149's text; 168 changes marked.
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
  -- 168: staff and admin only (John, 20 Oct: members can no longer hide
  -- themselves; staff hide someone on request, for privacy or safety). A member,
  -- or a guardian for a kid, is refused.
  if not (coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  update public.students set leaderboard_hidden = p_hidden where id = p_student;
  if not found then
    raise exception 'student % not found', p_student using errcode = 'no_data_found';
  end if;
end;
$$;

commit;
