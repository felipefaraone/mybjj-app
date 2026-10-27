-- 174_month_titles_verify.sql
--
-- Run AFTER 174, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/174_month_titles_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the close, its
-- notifications, the fixture event and attendance included). Every test prints
-- "PASS n ..." (NOTICE); the first failure stops it with "FAIL n ...". A test
-- that finds no rows fails.
-- The month is July 2001 of the REAL monthly race (the one the TV and the Wall
-- read): it has ended and no real attendance exists then. Unit A has an adult
-- and a kids division of the race, unit B an adult one. Every compared field is
-- set by the fixture (no defaults relied on); published_at is set by hand to
-- 3 Aug 2001 09:00 Sydney.
--   adults (A): Sam staff (prize_eligible false) 10 classes (rank 1, no place),
--     Ann 8 (1st), Hid hidden 7 (2nd), Tia and Tom 5 each on the same days (both
--     3rd), Ned 3 (5th, no place).
--   kids (A): Kim 6 (1st), Kit 4 (2nd), Kev 3 (3rd), Kai 2 (4th, no place).
--     Guardian G of Kim and Kai.
--   adults (B): Kay, a kid on a blue belt (prog kids: minor, adult audience)
--     with a photo, 6 (1st); Bee 2 (2nd).
-- Test 9 (the rollback parses) is NOT run here, by design: the rollback is never
-- executed against production. It was compiled on a scratch Postgres 17 (see
-- the commit that added 174).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- the TV's last month, one audience: "name:rank=place[/staff]" in order
create function pg_temp.tv_last(p jsonb, aud text) returns text language sql immutable as $f$
  select string_agg((x ->> 'name') || ':' || (x ->> 'rank') || '=' || coalesce(x ->> 'place', '?')
                    || case when (x ->> 'staff')::boolean then '/staff' else '' end, ', ' order by o)
    from jsonb_array_elements(p -> 'last_results' -> aud) with ordinality t(x, o)
$f$;
create function pg_temp.tv_screens(p jsonb) returns text language sql immutable as $f$
  select string_agg(x ->> 'screen', ',' order by o) from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;
-- 172's _month_champions, exactly (the "before" of test 2)
create function pg_temp.mc172(p_competition uuid, p_from date)
returns table (
  competition_id   uuid,
  competition_name text,
  period_from      date,
  title            text,
  published_at     timestamptz,
  division_id      uuid,
  division_label   text,
  unit_id          uuid,
  place            integer,
  student_id       uuid,
  display_name     text,
  anonymous        boolean,
  minor            boolean,
  photo_url        text,
  belt             text,
  degree           integer,
  points           numeric,
  target_id        uuid
)
language sql
stable
set search_path = public
as $$
  select c.id, c.name::text, m.period_from, to_char(m.period_from, 'FMMonth') || ' champions', m.published_at,
         cr.division_id, (cr.payload ->> 'division_label')::text, (cr.payload ->> 'unit_id')::uuid,
         cr.prize_rank,
         case when z.anon then null::uuid else cr.student_id end,
         (case when z.anon then 'Anonymous' else cr.payload ->> 'display_name' end)::text,
         z.anon,
         coalesce((cr.payload ->> 'minor')::boolean, false),
         (case when z.anon or coalesce((cr.payload ->> 'minor')::boolean, false) then null else cr.payload ->> 'photo_url' end)::text,
         (case when z.anon then null else cr.payload ->> 'belt' end)::text,
         (case when z.anon then null else (cr.payload ->> 'degree')::integer end)::integer,
         cr.points,
         public._month_champions_target(cr.division_id, m.period_from)
    from public.competition_month_closes m
    join public.competitions c on c.id = m.competition_id
    join public.competition_results cr
      on cr.competition_id = m.competition_id and cr.period_from = m.period_from and cr.period_to = m.period_to
   cross join lateral (select coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) as anon) z
   where m.competition_id = p_competition and m.period_from = p_from
     and cr.payload ->> 'audience' = 'adult' and cr.points > 0
     and cr.prize_rank is not null and cr.prize_rank <= 3
   order by 7, cr.prize_rank, cr.rank, 11
$$;

do $$
declare
  mc uuid; ua uuid; ub uuid; dva uuid; dvk uuid; dvb uuid; scr uuid; ty jsonb; ev uuid;
  u_sam uuid := gen_random_uuid(); u_ann uuid := gen_random_uuid(); u_hid uuid := gen_random_uuid();
  u_tia uuid := gen_random_uuid(); u_gk uuid := gen_random_uuid(); u_bee uuid := gen_random_uuid();
  s_sam uuid; s_ann uuid; s_hid uuid; s_tia uuid; s_tom uuid; s_ned uuid;
  s_kim uuid; s_kit uuid; s_kev uuid; s_kai uuid; s_kay uuid; s_bee uuid;
  p jsonb; v text; w text; x text; n int; m int; k int; k2 int; k3 int; v_frz numeric; v_cf date; v_ct date; v_tod date;
begin
  select id into mc from public.competitions where kind = 'monthly' and status = 'active' order by created_at desc, id limit 1;
  if mc is null then raise exception 'FAIL setup: no active monthly competition'; end if;
  select d.unit_id into ua from public.competition_divisions d where d.competition_id = mc
   group by d.unit_id having count(distinct d.audience) = 2 order by d.unit_id limit 1;
  select d.unit_id into ub from public.competition_divisions d where d.competition_id = mc and d.audience = 'adult' and d.unit_id <> ua
   order by d.unit_id limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: the monthly race needs a unit with adults and kids and a second unit'; end if;
  select id into dva from public.competition_divisions where competition_id = mc and unit_id = ua and audience = 'adult';
  select id into dvk from public.competition_divisions where competition_id = mc and unit_id = ua and audience = 'kids';
  select id into dvb from public.competition_divisions where competition_id = mc and unit_id = ub and audience = 'adult';
  if exists (select 1 from public.competition_month_closes where period_from in ('2001-06-01', '2001-07-01')) then
    raise exception 'FAIL setup: 2001 months already published';
  end if;
  if exists (select 1 from public.competitions where kind = 'event' and starts_on <= '2001-08-31' and ends_on >= '2001-08-01') then
    raise exception 'FAIL setup: an event already covers August 2001';
  end if;

  insert into auth.users (id, email)
  select y, 'zz174-' || y::text || '@example.invalid' from unnest(array[u_sam, u_ann, u_hid, u_tia, u_gk, u_bee]) y;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select y.id, 'zz174-' || y.id::text || '@example.invalid', y.nm, y.role, 'approved', y.u
    from (values (u_sam, 'Zz Sam', 'instructor', ua), (u_ann, 'Zz Ann', 'student', ua), (u_hid, 'Zz Hid', 'student', ua),
                 (u_tia, 'Zz Tia', 'student', ua), (u_gk, 'Zz Guardian', 'parent', ua), (u_bee, 'Zz Bee', 'student', ub)) y(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id;

  -- every field the tests compare, stated (no defaults)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Sam Staff','Sam','Staff','adult',ua,true,'ok','black',2,u_sam,'zz174/sam.jpg',false,false) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Ann Alpha','Ann','Alpha','adult',ua,true,'ok','purple',1,u_ann,'zz174/ann.jpg',false,true) returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Hid Den','Hid','Den','adult',ua,true,'ok','brown',3,u_hid,'zz174/hid.jpg',true,true) returning id into s_hid;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Tia Tie','Tia','Tie','adult',ua,true,'ok','blue',0,u_tia,null,false,true) returning id into s_tia;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Tom Tie','Tom','Tie','adult',ua,true,'ok','blue',0,null,null,false,true) returning id into s_tom;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Ned Five','Ned','Five','adult',ua,true,'ok','white',0,null,null,false,true) returning id into s_ned;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Kim Kid','Kim','Kid','kids',ua,true,'ok','grey/white',0,null,'zz174/kim.jpg',false,true) returning id into s_kim;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Kit Kid','Kit','Kid','kids',ua,true,'ok','yellow',0,null,null,false,true) returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Kev Kid','Kev','Kid','kids',ua,true,'ok','white',0,null,null,false,true) returning id into s_kev;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Kai Kid','Kai','Kid','kids',ua,true,'ok','white',0,null,null,false,true) returning id into s_kai;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Kay Blue','Kay','Blue','kids',ub,true,'ok','blue',0,null,'zz174/kay.jpg',false,true) returning id into s_kay;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz174 Bee Bunit','Bee','Bunit','adult',ub,true,'ok','white',0,u_bee,null,false,true) returning id into s_bee;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kim, u_gk, 'active', 'legacy_sync', 'manage'), (s_kai, u_gk, 'active', 'legacy_sync', 'manage');
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select y.sid, null, date '2001-07-01' + g, '18:00', 'alev', 'present', 1.00, 'gi', y.u
    from (values (s_sam, 10, ua), (s_ann, 8, ua), (s_hid, 7, ua), (s_tia, 5, ua), (s_tom, 5, ua), (s_ned, 3, ua),
                 (s_kim, 6, ua), (s_kit, 4, ua), (s_kev, 3, ua), (s_kai, 2, ua), (s_kay, 6, ub), (s_bee, 2, ub)) y(sid, k, u)
   cross join generate_series(0, 29) g
   where g < y.k;

  -- July closed by 172's own close, published 3 Aug 2001 09:00 Sydney (AEST)
  perform public.monthly_close('2001-07-15');
  update public.competition_month_closes set published_at = '2001-08-03 09:00:00+10'
   where period_from = '2001-07-01';
  select string_agg(format('%s:%s/%s', s.first_name, cr.rank, coalesce(cr.prize_rank::text, '-')), ' | ' order by cr.rank, s.first_name)
    into v from public.competition_results cr join public.students s on s.id = cr.student_id
   where cr.competition_id = mc and cr.period_from = '2001-07-01' and cr.division_id = dva and s.full_name like 'Zz174 %';
  if v is distinct from 'Sam:1/- | Ann:2/1 | Hid:3/2 | Tia:4/3 | Tom:4/3 | Ned:6/5' then
    raise exception 'FAIL setup: July close %', v;
  end if;

  -- TV days with no class at unit A (nothing focuses the playlist)
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind)
                  select $1::text::%s, d::text::%s, ''closed''::text::%s from unnest(array[''2001-08-02'', ''2001-08-05'', ''2001-08-10'']) d',
                 ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind') using ua;
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz174 tv', ua, encode(sha256('zz174'::bytea), 'hex')) returning id into scr;

  -- 0. grants and search_path
  if has_function_privilege('anon', 'public.competition_month_titles()', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_month_titles()', 'execute')
     or exists (select 1 from pg_proc pp, aclexplode(pp.proacl) a where pp.oid = 'public.competition_month_titles()'::regprocedure and a.grantee = 0)
     or has_function_privilege('authenticated', 'public._month_title_rows(uuid, date)', 'execute')
     or has_function_privilege('anon', 'public._month_title_rows(uuid, date)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_division_visible(text, uuid, boolean, uuid[])', 'execute')
     or has_function_privilege('authenticated', 'public._month_champions(uuid, date)', 'execute')
     or has_function_privilege('authenticated', 'public._tv_payload(uuid, date, time)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_standings(uuid, date, date)', 'execute')
     or has_function_privilege('anon', 'public.competition_standings(uuid, date, date)', 'execute') then
    raise exception 'FAIL 0: grants';
  end if;
  select count(*) into n from pg_proc pp
   where pp.oid in ('public._month_title_rows(uuid, date)'::regprocedure, 'public._month_champions(uuid, date)'::regprocedure,
                    'public.competition_month_titles()'::regprocedure, 'public.competition_standings(uuid, date, date)'::regprocedure,
                    'public._tv_payload(uuid, date, time)'::regprocedure,
                    'public._competition_division_visible(text, uuid, boolean, uuid[])'::regprocedure)
     and 'search_path=public' = any (pp.proconfig);
  if n <> 6 then raise exception 'FAIL 0: search_path set on % of 6', n; end if;
  raise notice 'PASS 0: grants (titles: authenticated only; internals: none), search_path=public on all 6';

  -- 1. the one source: staff absent, the tie on 3rd both there, kids there
  select string_agg(format('%s %s %s', case when t.unit_id = ua then 'A' else 'B' end || '/' || t.audience, s.first_name, t.place),
                    ' | ' order by (t.unit_id = ua) desc, t.audience, t.place, s.first_name),
         count(*)
    into v, n
    from public._month_title_rows(mc, '2001-07-01') t join public.students s on s.id = t.student_id;
  if v is distinct from 'A/adult Ann 1 | A/adult Hid 2 | A/adult Tia 3 | A/adult Tom 3 | A/kids Kim 1 | A/kids Kit 2 | A/kids Kev 3 | B/adult Kay 1 | B/adult Bee 2'
     or n <> 9
     or exists (select 1 from public._month_title_rows(mc, '2001-07-01') t where t.student_id in (s_sam, s_ned, s_kai))
     or (select place from public._month_title_rows(mc, '2001-07-01') t where t.student_id = s_ann) <> 1
     or not (select minor and audience = 'adult' from public._month_title_rows(mc, '2001-07-01') t where t.student_id = s_kay) then
    raise exception 'FAIL 1: %', v;
  end if;
  raise notice 'PASS 1: _month_title_rows: %', v;

  -- 2. _month_champions and competition_month_champions(): the same rows as 172's
  select count(*), count(*) filter (where q.a is distinct from q.b) into n, m
    from (select (select array_agg(x0::text) from pg_temp.mc172(cl.competition_id, cl.period_from) x0) as a,
                 (select array_agg(x1::text) from public._month_champions(cl.competition_id, cl.period_from) x1) as b
            from public.competition_month_closes cl) q;
  select count(*) into k from public._month_champions(mc, '2001-07-01');
  if n = 0 or m <> 0 or k <> 5 then raise exception 'FAIL 2: % closed month(s), % differ, July adult rows %', n, m, k; end if;
  select md5(coalesce(string_agg(y::text, '|' order by y::text), '')), count(*) into w, n
    from (select x0.* from (select m0.competition_id, max(m0.period_from) as period_from
                              from public.competition_month_closes m0
                              join public.competitions c0 on c0.id = m0.competition_id and c0.kind = 'monthly' and c0.status <> 'draft'
                             group by m0.competition_id) l
           cross join lateral pg_temp.mc172(l.competition_id, l.period_from) x0) y;
  perform pg_temp.v_as(u_bee);
  select md5(coalesce(string_agg(y::text, '|' order by y::text), '')) into x from public.competition_month_champions() y;
  execute 'reset role';
  if n = 0 or w is distinct from x then raise exception 'FAIL 2: competition_month_champions() differs (% rows before)', n; end if;
  raise notice 'PASS 2: _month_champions identical (rows and order) to 172''s for every closed month (July: % adult rows); competition_month_champions() identical (% rows)', k, n;

  -- 3. an adult member of unit A: adults yes, kids no, hidden absent, Kay without photo
  -- (each caller's rows are captured as they get them, then named as postgres:
  -- RLS would hide other units' students rows from the caller)
  perform pg_temp.v_as(u_ann);
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into p from public.competition_month_titles() t;
  execute 'reset role';
  select string_agg(format('%s %s %s', case when t.unit_id = ua then 'A' else 'B' end || '/' || t.audience,
                           coalesce(s.first_name, '?'), t.place) || case when t.photo_url is null then '' else '+photo' end,
                    ' | ' order by (t.unit_id = ua) desc, t.audience, t.place, s.first_name)
    into v
    from jsonb_to_recordset(p) t(competition_id uuid, period_from date, unit_id uuid, audience text, place int, student_id uuid, photo_url text)
    left join public.students s on s.id = t.student_id
   where t.competition_id = mc and t.period_from = '2001-07-01';
  select count(*) into n from jsonb_array_elements(p) e where (e ->> 'minor')::boolean and e ->> 'photo_url' is not null;
  if v is distinct from 'A/adult Ann 1+photo | A/adult Tia 3 | A/adult Tom 3 | B/adult Kay 1 | B/adult Bee 2' or n <> 0 then
    raise exception 'FAIL 3: % (minor photos %)', v, n;
  end if;
  raise notice 'PASS 3: as Ann (adult, unit A): % (no kids, no Hid, no Sam; Kay is minor, no photo)', v;

  -- 4. a guardian of a kid in the kids division: that division's kids
  perform pg_temp.v_as(u_gk);
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into p from public.competition_month_titles() t;
  execute 'reset role';
  select string_agg(format('%s %s', s.first_name, t.place), ' | ' order by t.place, s.first_name),
         count(*) filter (where t.photo_url is not null)
    into v, n
    from jsonb_to_recordset(p) t(competition_id uuid, period_from date, audience text, place int, student_id uuid, photo_url text)
    join public.students s on s.id = t.student_id
   where t.competition_id = mc and t.period_from = '2001-07-01' and t.audience = 'kids';
  if v is distinct from 'Kim 1 | Kit 2 | Kev 3' or n <> 0 then raise exception 'FAIL 4: % / photos %', v, n; end if;
  raise notice 'PASS 4: as Kim''s guardian: kids %', v;

  -- 5. the hidden member sees their own place; staff see it (and the kids); another member does not
  perform pg_temp.v_as(u_hid);
  select count(*) into n from public.competition_month_titles() t where t.student_id = s_hid and t.place = 2;
  execute 'reset role';
  perform pg_temp.v_as(u_sam);
  select count(*) filter (where t.student_id = s_hid and t.place = 2),
         count(*) filter (where t.audience = 'kids' and t.unit_id = ua),
         count(*) filter (where t.student_id = s_sam)
    into m, k, k2
    from public.competition_month_titles() t where t.competition_id = mc and t.period_from = '2001-07-01';
  execute 'reset role';
  perform pg_temp.v_as(u_tia);
  select count(*) into k3 from public.competition_month_titles() t where t.student_id = s_hid or t.display_name = 'Anonymous';
  execute 'reset role';
  if n <> 1 or m <> 1 or k <> 3 or k2 <> 0 or k3 <> 0 then
    raise exception 'FAIL 5: self % / staff: Hid %, kids %, Sam % / Tia sees Hid %', n, m, k, k2, k3;
  end if;
  raise notice 'PASS 5: Hid sees their 2nd place; staff see Hid and the 3 kids (and never a place for Sam); Tia gets no row for Hid, not even Anonymous';

  -- 6. anon cannot execute it
  begin
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
    perform * from public.competition_month_titles();
    v := 'executed';
  exception when insufficient_privilege then v := 'refused: ' || sqlerrm;
  end;
  execute 'reset role';
  if v not like 'refused: permission denied%' then raise exception 'FAIL 6: anon %', v; end if;
  raise notice 'PASS 6: anon %', v;

  -- 7. the TV: inside the 7 days (5 Aug), the places; before the publication and after the 7 days, nothing
  p := public._tv_payload(scr, '2001-08-05', '10:00');
  v := pg_temp.tv_last(p, 'adult');
  w := pg_temp.tv_last(p, 'kids');
  if v is distinct from 'Ann Alpha:1=1, Anonymous:2=2, Tia Tie:3=3, Tom Tie:3=3'
     or (select count(*) from jsonb_array_elements(p -> 'last_results' -> 'kids')) <> 3
     or w not like '%:1=1, %:2=2, %:3=3'
     or p -> 'last_results' ->> 'month_start' <> '2001-07-01'
     or position('last_results_adult' in pg_temp.tv_screens(p)) = 0
     or position('last_results_kids' in pg_temp.tv_screens(p)) = 0
     or p -> 'competition' ->> 'kind' <> 'monthly' then
    raise exception 'FAIL 7: adult % kids % playlist %', v, w, pg_temp.tv_screens(p);
  end if;
  if public._tv_payload(scr, '2001-08-02', '10:00') -> 'last_results' <> 'null'::jsonb
     or public._tv_payload(scr, '2001-08-10', '10:00') -> 'last_results' <> 'null'::jsonb then
    raise exception 'FAIL 7: last_results outside the window: 2 Aug % / 10 Aug %',
      public._tv_payload(scr, '2001-08-02', '10:00') -> 'last_results', public._tv_payload(scr, '2001-08-10', '10:00') -> 'last_results';
  end if;
  raise notice 'PASS 7: 5 Aug: adults % ; kids % ; none on 2 Aug (before the publication) or 10 Aug (after 7 days)', v, w;

  -- 7b. an active event covering 5 Aug at unit A: the Monthly race's places stay
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes, theme)
    values ('Zz174 Cup', 'event', '2001-08-01', '2001-08-31', null, 'active', '[]'::jsonb, '{}'::jsonb) returning id into ev;
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
    values (ev, ua, 'adult', 'Zz174 Adults', 0), (ev, ua, 'kids', 'Zz174 Kids', 1);
  p := public._tv_payload(scr, '2001-08-05', '10:00');
  v := pg_temp.tv_last(p, 'adult');
  if p -> 'competition' ->> 'name' <> 'Zz174 Cup'
     or v is distinct from 'Ann Alpha:1=1, Anonymous:2=2, Tia Tie:3=3, Tom Tie:3=3'
     or position('last_results_adult' in pg_temp.tv_screens(p)) = 0 then
    raise exception 'FAIL 7b: competition % last % playlist %', p -> 'competition' ->> 'name', v, pg_temp.tv_screens(p);
  end if;
  raise notice 'PASS 7b: with the Zz174 Cup live: last_results %; playlist %', v, pg_temp.tv_screens(p);

  -- 8. competition_standings: the closed month is frozen, the current month live
  select points into v_frz from public.competition_results
   where competition_id = mc and period_from = '2001-07-01' and student_id = s_ned;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select s_ned, null, date '2001-07-10' + g, '07:00', 'alev', 'present', 1.00, 'gi', ua from generate_series(0, 19) g;
  v_tod := (now() at time zone 'Australia/Sydney')::date;
  v_cf := date_trunc('month', v_tod)::date;
  v_ct := (v_cf + interval '1 month' - interval '1 day')::date;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s_ann, null, v_tod, '06:00', 'alev', 'present', 1.00, 'gi', ua);
  if (select rank from public._competition_ranked(mc, '2001-07-01', '2001-07-31') where student_id = s_ned) <> 1 then
    raise exception 'FAIL 8: setup, Ned is not live 1st';
  end if;
  perform pg_temp.v_as(u_ann);
  select format('%s/%s', st.points, st.rank) into v from public.competition_standings(mc, '2001-07-01', '2001-07-31') st where st.student_id = s_ned;
  select count(*) filter (where st.is_anonymous and st.rank = 3 and st.student_id is null and st.display_name = 'Anonymous'),
         count(*) filter (where st.audience = 'kids')
    into n, m from public.competition_standings(mc, '2001-07-01', '2001-07-31') st;
  select st.points::text into w from public.competition_standings(mc, v_cf, v_ct) st where st.student_id = s_ann;
  execute 'reset role';
  select points::text into x from public._competition_ranked(mc, v_cf, v_ct) where student_id = s_ann;
  if v is distinct from format('%s/%s', v_frz, 6) or n <> 1 or m <> 0
     or w is null or w is distinct from x or w::numeric <= 0 then
    raise exception 'FAIL 8: July Ned % (frozen %/6), Anonymous %, kids %, current month Ann % live %', v, v_frz, n, m, w, x;
  end if;
  raise notice 'PASS 8: July (closed): Ned % (frozen, live is 1st); Hid Anonymous; no kids for Ann. Current month: Ann % = live %', v, w, x;
end $$;

rollback;
