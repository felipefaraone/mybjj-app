-- 182_champion_share_verify.sql
--
-- Run AFTER 182, with psql, on live:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/182_champion_share_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS n ..." (NOTICE, and the rows selected at the end); the first failure stops
-- it with "FAIL n ...". Real October 2026 data (competition
-- 3d66c81b-6f7e-456c-9077-403067db093f), real accounts impersonated through
-- request.jwt.claims + role authenticated:
--   winners   the 6 adult podium accounts (NB Alison Lee, David Wood, Adriano
--             Martins Pinto; CD Melina Bilota, Brian Luhr, George Hatzi)
--   non-winner Brock Ashby (approved adult member, not on the podium)
--   parents   6441a7c5 (Charlotte L.'s guardian, no students row of their own)
--             d71f204e (Charlotte L.'s other guardian, who also trains)
--  1  preview: the 6 recipients the backfill targets, each with an account
--  2  the backfill's rows: 6, the expected title / body / key, own accounts only
--  3  a second run of the backfill (the same block as 182) inserts 0
--  4  the RPC as each winner: their own row only; classes = the standings' count
--  5  the RPC as a non-winner: empty
--  6  the RPC as a kid's parents: empty
--  7  the RPC: wrong month / wrong competition: empty
--  8  the RPC's grants and settings: authenticated only, definer, search_path
--  9  monthly_close: the new body, owner / grants / security / search_path unchanged
-- 10  monthly_close copy, end to end: October's close removed (rolled back) and
--     run again: the 6 adult winners get the share line, kids and guardians the
--     old text; a second call publishes nothing (idempotency unchanged)

begin;

create temp table v182 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v182 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
create function pg_temp.as_json(u uuid, q text) returns jsonb language plpgsql as $f$
declare j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (' || q || ') x' into j;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return j;
end $f$;

create temp table w182 as   -- the October adult podium and its own accounts
  select cr.id, cr.student_id, cr.prize_rank, u.name::text as unit_name, cr.payload ->> 'display_name' as display_name,
         (cr.payload ->> 'classes_count')::integer as classes, s.user_id
    from public.competition_results cr
    join public.students s on s.id = cr.student_id
    left join public.units u on u.id = (cr.payload ->> 'unit_id')::uuid
   where cr.competition_id = '3d66c81b-6f7e-456c-9077-403067db093f' and cr.period_from = '2026-10-01'
     and cr.points > 0 and cr.prize_rank between 1 and 3
     and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
     and cr.payload ->> 'audience' = 'adult' and not coalesce((cr.payload ->> 'minor')::boolean, false);
grant select on w182 to authenticated;

do $$
declare
  C   constant uuid := '3d66c81b-6f7e-456c-9077-403067db093f';
  w   record;
  j   jsonb;
  n   integer;
  n0  integer;
  t   text;
  sc  integer;
begin
  -- 1 preview
  select string_agg(unit_name || ' ' || prize_rank || ' ' || display_name || ' (' || coalesce(user_id::text, 'NO ACCOUNT') || ')', '; '
                    order by unit_name, prize_rank), count(*), count(user_id)
    into t, n, n0 from w182;
  if n <> 6 or n0 <> 6 then raise exception 'FAIL 1 preview: % winners, % with an account', n, n0; end if;
  perform pg_temp.ok('PASS 1 preview, 6 recipients: ' || t);

  -- 2 the backfill's rows
  select count(*) into n from public.notifications x join w182 on x.related_entity_id = w182.id
   where x.type = 'competition_result' and x.related_entity_type = 'competition_result' and coalesce((x.metadata ->> 'share')::boolean, false)
     and x.user_id = w182.user_id
     and x.title = 'Your October champion card is ready to share'
     and x.body = 'You finished ' || public._competition_ord(w182.prize_rank) || ' in October at ' || w182.unit_name || '.'
     and x.metadata ->> 'month' = '2026-10-01';
  select count(*) into n0 from public.notifications x where x.related_entity_type = 'competition_result' and coalesce((x.metadata ->> 'share')::boolean, false);
  if n <> 6 or n0 <> 6 then raise exception 'FAIL 2 share notifications: % matching, % in all', n, n0; end if;
  perform pg_temp.ok('PASS 2 backfill: 6 share notifications, one per winner''s own account, none to anyone else');

  -- 3 a second run inserts 0
  select count(*) into n0 from public.notifications;
end $$;

do $$
declare
  v_comp   constant uuid := '3d66c81b-6f7e-456c-9077-403067db093f';
  v_from   constant date := '2026-10-01';
  v_mon    text := to_char(v_from, 'FMMonth');
  r        record;
  rc       record;
  v_new    integer := 0;
  v_had    integer := 0;
  v_noacct integer := 0;
  v_prefs  integer := 0;
begin
  for r in
    select cr.id, cr.student_id, cr.prize_rank, u.name::text as unit_name
      from public.competition_month_closes m
      join public.competition_results cr
        on cr.competition_id = m.competition_id and cr.period_from = m.period_from and cr.period_to = m.period_to
      left join public.units u on u.id = (cr.payload ->> 'unit_id')::uuid
     where m.competition_id = v_comp and m.period_from = v_from
       and cr.points > 0 and cr.prize_rank between 1 and 3
       and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
       and cr.payload ->> 'audience' = 'adult'
       and not coalesce((cr.payload ->> 'minor')::boolean, false)
     order by u.name, cr.prize_rank, cr.student_id
  loop
    if not exists (select 1 from public._competition_notify_recipients(r.student_id) x where not x.is_guardian) then
      v_noacct := v_noacct + 1;
      continue;
    end if;
    for rc in select x.user_id from public._competition_notify_recipients(r.student_id) x where not x.is_guardian loop
      if exists (select 1 from public.notifications n
                  where n.user_id = rc.user_id and n.type = 'competition_result'
                    and n.related_entity_type = 'competition_result' and n.related_entity_id = r.id
                    and coalesce((n.metadata ->> 'share')::boolean, false)) then
        v_had := v_had + 1;
        continue;
      end if;
      if not public.user_wants_notification_type(rc.user_id, 'competition_result') then
        v_prefs := v_prefs + 1;
        continue;
      end if;
      insert into public.notifications (user_id, type, title, body, related_entity_type, related_entity_id, metadata)
      values (rc.user_id, 'competition_result',
              'Your ' || v_mon || ' champion card is ready to share',
              'You finished ' || public._competition_ord(r.prize_rank) || ' in ' || v_mon || coalesce(' at ' || r.unit_name, '') || '.',
              'competition_result', r.id,
              jsonb_build_object('competition_id', v_comp, 'student_id', r.student_id, 'kind', 'monthly',
                                 'month', v_from, 'prize_rank', r.prize_rank, 'share', true));
      v_new := v_new + 1;
    end loop;
  end loop;
  raise notice '182 backfill: % inserted, % already there, % skipped (no account), % skipped (notifications off)',
    v_new, v_had, v_noacct, v_prefs;
end $$;

do $$
declare
  C   constant uuid := '3d66c81b-6f7e-456c-9077-403067db093f';
  w   record;
  j   jsonb;
  n   integer;
  t   text := '';
  sc  integer;
begin
  select count(*) into n from public.notifications x where x.related_entity_type = 'competition_result' and coalesce((x.metadata ->> 'share')::boolean, false);
  if n <> 6 then raise exception 'FAIL 3 second run: % share notifications (expected still 6)', n; end if;
  perform pg_temp.ok('PASS 3 second run of the backfill: 0 inserted (still 6)');

  -- 4 the RPC as each winner
  for w in select * from w182 order by unit_name, prize_rank loop
    j := pg_temp.as_json(w.user_id, format('select * from public.my_month_title_share(%L, %L)', C, '2026-10-15'));
    if jsonb_array_length(j) <> 1 then raise exception 'FAIL 4 % got % rows: %', w.display_name, jsonb_array_length(j), j; end if;
    if (j -> 0 ->> 'place')::int <> w.prize_rank or j -> 0 ->> 'display_name' <> w.display_name
       or j -> 0 ->> 'unit_name' <> w.unit_name or j -> 0 ->> 'title_month' <> 'October'
       or (j -> 0 ->> 'period_from')::date <> '2026-10-01' then
      raise exception 'FAIL 4 % wrong row: %', w.display_name, j;
    end if;
    -- the standings' own count for the same person, as they see the board
    select (e ->> 'classes_count')::int into sc
      from jsonb_array_elements(pg_temp.as_json(w.user_id,
             format('select student_id, classes_count from public.competition_standings(%L, %L, %L)', C, '2026-10-01', '2026-10-31'))) e
     where (e ->> 'student_id')::uuid = w.student_id;
    if (j -> 0 ->> 'classes')::int is distinct from sc or sc is distinct from w.classes then
      raise exception 'FAIL 4 % classes: card %, standings %, frozen %', w.display_name, j -> 0 ->> 'classes', sc, w.classes;
    end if;
    t := t || w.unit_name || ' ' || w.prize_rank || ' ' || w.display_name || ' = ' || sc || '; ';
  end loop;
  perform pg_temp.ok('PASS 4 RPC as each winner: own row only, classes card = standings: ' || t);

  -- 5 a non-winner
  j := pg_temp.as_json('00bb95bc-1ad3-4e52-8312-e70c422bab93', format('select * from public.my_month_title_share(%L, %L)', C, '2026-10-01'));
  if jsonb_array_length(j) <> 0 then raise exception 'FAIL 5 non-winner got %', j; end if;
  perform pg_temp.ok('PASS 5 RPC as a non-winner (Brock Ashby): empty');

  -- 6 a kid's parents
  for w in select x::uuid as u from unnest(array['6441a7c5-2112-4f32-b8ec-bfb20a4b8199', 'd71f204e-9cff-4338-9e47-997202633733']) x loop
    j := pg_temp.as_json(w.u, format('select * from public.my_month_title_share(%L, %L)', C, '2026-10-01'));
    if jsonb_array_length(j) <> 0 then raise exception 'FAIL 6 parent % got %', w.u, j; end if;
  end loop;
  perform pg_temp.ok('PASS 6 RPC as Charlotte L.''s two guardians (one also trains): empty');

  -- 7 wrong month / competition
  select user_id into w from w182 order by unit_name, prize_rank limit 1;
  j := pg_temp.as_json(w.user_id, format('select * from public.my_month_title_share(%L, %L)', C, '2026-09-01'))
       || pg_temp.as_json(w.user_id, format('select * from public.my_month_title_share(%L, %L)', gen_random_uuid(), '2026-10-01'));
  if jsonb_array_length(j) <> 0 then raise exception 'FAIL 7 got %', j; end if;
  perform pg_temp.ok('PASS 7 RPC for September or another competition: empty');

  -- 8 grants and settings
  if has_function_privilege('anon', 'public.my_month_title_share(uuid, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.my_month_title_share(uuid, date)', 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                 where p.oid = 'public.my_month_title_share(uuid, date)'::regprocedure and a.grantee = 0)
     or not (select prosecdef and provolatile = 's' and proconfig = array['search_path=public']
               from pg_proc where oid = 'public.my_month_title_share(uuid, date)'::regprocedure) then
    raise exception 'FAIL 8 grants/settings: %', (select proacl::text || ' ' || proconfig::text from pg_proc
                                                  where oid = 'public.my_month_title_share(uuid, date)'::regprocedure);
  end if;
  perform pg_temp.ok('PASS 8 RPC: execute for authenticated only (not anon, not public), security definer, stable, search_path=public: '
                     || (select proacl::text from pg_proc where oid = 'public.my_month_title_share(uuid, date)'::regprocedure));

  -- 9 monthly_close
  select md5(p.prosrc) || ' owner ' || p.proowner::regrole || ' secdef ' || p.prosecdef || ' cfg ' || p.proconfig::text
         || ' acl ' || p.proacl::text into t
    from pg_proc p where p.oid = 'public.monthly_close(date)'::regprocedure;
  if t <> 'c0bb9c3000385b6668e84eab4e6844d3 owner postgres secdef true cfg {search_path=public} acl {postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'FAIL 9 monthly_close: %', t;
  end if;
  perform pg_temp.ok('PASS 9 monthly_close: ' || t);
end $$;

-- 10 the close's copy, end to end (all rolled back)
create temp table n182 as select id from public.notifications;
delete from public.competition_results where competition_id = '3d66c81b-6f7e-456c-9077-403067db093f' and period_from = '2026-10-01';
delete from public.competition_month_closes where competition_id = '3d66c81b-6f7e-456c-9077-403067db093f' and period_from = '2026-10-01';
select public.monthly_close('2026-10-01');

do $$
declare
  n  integer;
  na integer;
  nk integer;
  j  jsonb;
begin
  select count(*) filter (where x.body ~ ' You finished (1st|2nd|3rd) in October at (Neutral Bay|Camperdown)\. Your champion card is ready to share\.$'
                            and x.title ~ '^You finished (1st|2nd|3rd) in the October race$'),
         count(*) filter (where x.body like '%champion card%' and x.title !~ '^You finished')
    into na, nk
    from public.notifications x
   where x.type = 'competition_result' and x.id not in (select id from n182);
  select jsonb_agg(jsonb_build_object('t', x.title, 'b', x.body) order by x.title, x.body) into j
    from public.notifications x where x.type = 'competition_result' and x.id not in (select id from n182);
  raise notice 'new close notifications: %', j;
  if na <> 6 or nk <> 0
     or exists (select 1 from public.notifications x where x.type = 'competition_result' and x.id not in (select id from n182)
                   and x.title !~ '^You finished' and x.body !~ '^[A-Za-z ]+ Kids, [0-9.]+ points?\. Well done [A-Za-z]+!$')
     or exists (select 1 from public.notifications x join w182 on w182.user_id = x.user_id
                 where x.type = 'competition_result' and x.id not in (select id from n182)
                   and x.body not like '% You finished ' || public._competition_ord(w182.prize_rank) || ' in October at '
                                       || w182.unit_name || '. Your champion card is ready to share.') then
    raise exception 'FAIL 10 copy: % adult share lines, % non-adult with it: %', na, nk, j;
  end if;
  select count(*) into n from public.notifications x where x.id not in (select id from n182);
  perform public.monthly_close('2026-10-01');
  if (select count(*) from public.notifications x where x.id not in (select id from n182)) <> n then
    raise exception 'FAIL 10 a second close call sent more notifications';
  end if;
  perform pg_temp.ok('PASS 10 close copy: the 6 adult winners get "You finished Nth in October at <gym>. Your champion card is ready to share.", '
                     || 'the guardians'' kids text unchanged; a second call publishes nothing (' || n || ' notifications, unchanged)');
end $$;

select line from v182 order by n;

rollback;
