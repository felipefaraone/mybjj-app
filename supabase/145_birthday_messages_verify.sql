-- 145_birthday_messages_verify.sql
--
-- One DO block that ENDS WITH RAISE EXCEPTION carrying its results: the
-- "ERROR:  V145 ..." message IS the report, and nothing in the block persists
-- (the inactive test row and the role switch are rolled back with it).
-- Expected: every line "pass".

do $$
declare
  out text := ''; n int; g record; bad int; v boolean; pol int; vis int; tot int;
begin
  -- 1. 28 rows in total
  select count(*) into n from public.birthday_messages;
  out := out || format(E'\n  1 total rows = %s: %s', n, case when n = 28 then 'pass' else 'FAIL (expected 28)' end);

  -- 2. exactly 4 per group, all 7 groups present
  select count(*) into bad from (
    select x.grp, count(m.id) as c
      from unnest(array['kids_beginner','kids_colour','white','blue','purple','brown','black']) as x(grp)
      left join public.birthday_messages m on m.belt_group = x.grp
     group by x.grp) q
   where q.c <> 4;
  out := out || format(E'\n  2 groups without exactly 4 rows = %s: %s', bad, case when bad = 0 then 'pass' else 'FAIL' end);

  -- 3. anon cannot select (no table privilege)
  v := has_table_privilege('anon', 'public.birthday_messages', 'SELECT');
  out := out || format(E'\n  3 anon SELECT privilege = %s: %s', v, case when v is false then 'pass' else 'FAIL' end);

  -- 4. RLS on, and the authenticated SELECT policy exists (and is the only policy)
  select count(*) into pol from pg_policies
   where schemaname = 'public' and tablename = 'birthday_messages'
     and policyname = 'birthday_messages_select' and cmd = 'SELECT' and 'authenticated' = any(roles);
  select count(*) into n from pg_policies where schemaname = 'public' and tablename = 'birthday_messages';
  v := (select relrowsecurity from pg_class where oid = 'public.birthday_messages'::regclass);
  out := out || format(E'\n  4 rls=%s, select policy=%s, policies total=%s: %s', v, pol, n,
    case when v and pol = 1 and n = 1 then 'pass' else 'FAIL' end);

  -- 5. authenticated cannot write or truncate
  v := has_table_privilege('authenticated', 'public.birthday_messages', 'INSERT')
    or has_table_privilege('authenticated', 'public.birthday_messages', 'UPDATE')
    or has_table_privilege('authenticated', 'public.birthday_messages', 'DELETE')
    or has_table_privilege('authenticated', 'public.birthday_messages', 'TRUNCATE');
  out := out || format(E'\n  5 authenticated write/truncate privilege = %s: %s', v, case when v is false then 'pass' else 'FAIL' end);

  -- 6. an inactive row is hidden from authenticated (evaluated AS authenticated)
  insert into public.birthday_messages (belt_group, body, active)
    values ('white', 'zz v145 inactive test row', false);
  select count(*) into tot from public.birthday_messages;
  set local role authenticated;
  select count(*) into vis from public.birthday_messages;
  select count(*) into n from public.birthday_messages where body = 'zz v145 inactive test row';
  reset role;
  out := out || format(E'\n  6 as authenticated: visible %s of %s, inactive test row visible %s: %s', vis, tot, n,
    case when n = 0 and vis = tot - 1 then 'pass' else 'FAIL' end);

  raise exception 'V145 results (rolled back):%', out;
end $$;
