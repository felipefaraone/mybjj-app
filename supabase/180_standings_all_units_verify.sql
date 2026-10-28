-- 180_standings_all_units_verify.sql
--
-- Run AFTER 180, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/180_standings_all_units_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS n ..." (NOTICE, and the rows selected at the end); the first failure stops
-- it with "FAIL n ...".
-- Fixtures (Zz180): units A and B; event E (published, so competition_standings
-- returns its frozen competition_results rows) with divisions A adults, B adults,
-- A kids:
--   A adults: A1 20 pts/10 cl, SA staff 18/9, A2 15/8, A3 15/8 (tied with A2),
--             A4 hidden 12/6, A5 12/5
--   B adults: B1 20/11, B3 18/3, B2 15/8 (same keys as A2/A3)
--   A kids:   K1 30
-- monthly M (archived) with a CLOSED month (competition_month_closes) and its frozen
-- rows; draft event D with frozen rows. Viewers: instructor i (unit A), owner o
-- (admin), member m (student in A, not on the board), h (A4's own login).
-- Then live, read-only: October on the Monthly race and the Christmas Cup period,
-- as a real member and as a real owner (each live row carries its gym's code).
-- Last, units.short_code: NB / CD on the two gyms by id, its check and unique
-- index, and unit_short = the code, else the unit's name.

begin;

create temp table v180 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v180 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
create function pg_temp.as_json(u uuid, q text) returns jsonb language plpgsql as $f$
declare j jsonb;
begin
  begin
    perform pg_temp.v_as(u);
    execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (' || q || ') x' into j;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return j;
  exception when others then
    return jsonb_build_object('err', sqlerrm);
  end;
end $f$;
-- the combined board as "name:combined_rank:combined_place" in its order
create function pg_temp.board(j jsonb) returns text language sql immutable as $f$
  select string_agg(x.display_name || ':' || x.combined_rank || ':' || coalesce(x.combined_place::text, '-'), ' ' order by o)
    from jsonb_array_elements(j) with ordinality e(v, o)
   cross join lateral jsonb_to_record(e.v) as x(display_name text, combined_rank int, combined_place int)
$f$;
-- pairs of rows of the same unit whose per-unit rank and combined rank disagree
-- (order or tie): 0 means the combined order keeps every unit's own order
create function pg_temp.disorder(j jsonb) returns bigint language sql immutable as $f$
  with x as (
    select o, r.unit_id, r.rank, r.combined_rank
      from jsonb_array_elements(j) with ordinality e(v, o)
     cross join lateral jsonb_to_record(e.v) as r(unit_id uuid, rank int, combined_rank int)
  )
  select count(*) from x a join x b on a.unit_id = b.unit_id and a.o < b.o
   where sign(a.rank - b.rank) <> sign(a.combined_rank - b.combined_rank)
$f$;
-- adult rows per unit as "unit:all/on-board" (on the board = points > 0)
create function pg_temp.per_unit(j jsonb) returns text language sql immutable as $f$
  select coalesce(string_agg(t, ' ' order by t), '')
    from (select r.unit_id::text || ':' || count(*) || '/' || count(*) filter (where r.points > 0) as t
            from jsonb_to_recordset(j) as r(unit_id uuid, audience text, points numeric)
           where r.audience = 'adult'
           group by r.unit_id) z
$f$;
-- a frozen row
create function pg_temp.res(c uuid, pf date, pt date, d uuid, s uuid, u uuid, aud text, nm text,
                            pts numeric, cls int, last date, elig boolean, hid boolean, rk int, pr int)
returns void language sql as $f$
  insert into public.competition_results (competition_id, period_from, period_to, division_id, student_id, points, rank, prize_rank, payload)
  values (c, pf, pt, d, s, pts, rk, pr, jsonb_build_object(
    'unit_id', u, 'audience', aud, 'display_name', nm, 'photo_url', null,
    'class_points', pts, 'gi_points', 0, 'nogi_points', 0, 'award_points', 0, 'referral_points', 0,
    'classes_count', cls, 'last_scored_on', last, 'prize_eligible', elig, 'leaderboard_hidden', hid,
    'belt', 'white', 'degree', 0, 'minor', false, 'checkin_points', 0));
$f$;

do $$
declare
  T date := (now() at time zone 'Australia/Sydney')::date;
  ua uuid; ub uuid; e uuid; m_c uuid; d_c uuid;
  dA uuid; dB uuid; dK uuid; mA uuid; mB uuid; xA uuid;
  i uuid := gen_random_uuid(); o uuid := gen_random_uuid(); m uuid := gen_random_uuid(); h uuid := gen_random_uuid();
  sA1 uuid; sSA uuid; sA2 uuid; sA3 uuid; sA4 uuid; sA5 uuid; sB1 uuid; sB2 uuid; sB3 uuid; sK1 uuid; sM uuid;
  ef date; et date; mf date; mt date;
  j jsonb; j2 jsonb; v text; w text;
  q text;
  real_member uuid; real_owner uuid; mon uuid; cup uuid; p uuid; pq text;
begin
  -- fixtures ----------------------------------------------------------------
  insert into public.units (name) values ('Zz180 A') returning id into ua;
  insert into public.units (name) values ('Zz180 B') returning id into ub;
  insert into auth.users (id, email) select y, 'zz180-' || y::text || '@example.invalid' from unnest(array[i, o, m, h]) y;
  insert into public.users (id, email, full_name, role, status, unit_id, active_unit_id)
  select z.id, 'zz180-' || z.id::text || '@example.invalid', z.nm, z.role, 'approved', ua, ua
    from (values (i, 'Zz180 Instructor', 'instructor'), (o, 'Zz180 Owner', 'instructor'),
                 (m, 'Zz180 Member', 'student'), (h, 'Zz180 Hidden', 'student')) z(id, nm, role)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id, active_unit_id = excluded.active_unit_id;
  update public.units set owner_user_id = o where id = ua;
  insert into public.students (full_name, unit_id) values ('Zz180 A1', ua) returning id into sA1;
  insert into public.students (full_name, unit_id) values ('Zz180 SA', ua) returning id into sSA;
  insert into public.students (full_name, unit_id) values ('Zz180 A2', ua) returning id into sA2;
  insert into public.students (full_name, unit_id) values ('Zz180 A3', ua) returning id into sA3;
  insert into public.students (full_name, unit_id, user_id, leaderboard_hidden) values ('Zz180 A4', ua, h, true) returning id into sA4;
  insert into public.students (full_name, unit_id) values ('Zz180 A5', ua) returning id into sA5;
  insert into public.students (full_name, unit_id) values ('Zz180 B1', ub) returning id into sB1;
  insert into public.students (full_name, unit_id) values ('Zz180 B2', ub) returning id into sB2;
  insert into public.students (full_name, unit_id) values ('Zz180 B3', ub) returning id into sB3;
  insert into public.students (full_name, unit_id) values ('Zz180 K1', ua) returning id into sK1;
  insert into public.students (full_name, unit_id, user_id) values ('Zz180 Member', ua, m) returning id into sM;

  ef := T - 40; et := T - 20;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes, published_at)
    values ('Zz180 Event', 'event', ef, et, 'active', '[]', now()) returning id into e;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (e, ua, 'adult', 'Zz180 A Adults') returning id into dA;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (e, ub, 'adult', 'Zz180 B Adults') returning id into dB;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (e, ua, 'kids', 'Zz180 A Kids') returning id into dK;
  perform pg_temp.res(e, ef, et, dA, sA1, ua, 'adult', 'Zz180 A1', 20, 10, T - 30, true,  false, 1, 1);
  perform pg_temp.res(e, ef, et, dA, sSA, ua, 'adult', 'Zz180 SA', 18,  9, T - 30, false, false, 2, null);
  perform pg_temp.res(e, ef, et, dA, sA2, ua, 'adult', 'Zz180 A2', 15,  8, T - 31, true,  false, 3, 2);
  perform pg_temp.res(e, ef, et, dA, sA3, ua, 'adult', 'Zz180 A3', 15,  8, T - 31, true,  false, 3, 2);
  perform pg_temp.res(e, ef, et, dA, sA4, ua, 'adult', 'Zz180 A4', 12,  6, T - 32, true,  true,  5, 4);
  perform pg_temp.res(e, ef, et, dA, sA5, ua, 'adult', 'Zz180 A5', 12,  5, T - 32, true,  false, 6, 5);
  perform pg_temp.res(e, ef, et, dB, sB1, ub, 'adult', 'Zz180 B1', 20, 11, T - 30, true,  false, 1, 1);
  perform pg_temp.res(e, ef, et, dB, sB3, ub, 'adult', 'Zz180 B3', 18,  3, T - 30, true,  false, 2, 2);
  perform pg_temp.res(e, ef, et, dB, sB2, ub, 'adult', 'Zz180 B2', 15,  8, T - 31, true,  false, 3, 3);
  perform pg_temp.res(e, ef, et, dK, sK1, ua, 'kids',  'Zz180 K1', 30, 12, T - 30, true,  false, 1, 1);

  q := format('select * from public.competition_standings_all_units(%L)', e);

  -- 1. combined order, ranks and places (staff see every key) ------------------
  j := pg_temp.as_json(i, q);
  v := pg_temp.board(j);
  if v is distinct from 'Zz180 B1:1:1 Zz180 A1:2:2 Zz180 SA:3:- Zz180 B3:4:3 Zz180 A2:5:4 Zz180 A3:5:4 Zz180 B2:5:4 Zz180 A4:8:7 Zz180 A5:9:8' then
    raise exception 'FAIL 1 combined board (staff): %', v;
  end if;
  perform pg_temp.ok('PASS 1 combined board: points, then classes, then first to score (B1 20/11 over A1 20/10); equal keys tie across units (A2 = A3 = B2 = 5th); ' || v);

  -- 2. within each unit the order and ties are competition_standings' own -------
  if pg_temp.disorder(j) <> 0 then raise exception 'FAIL 2 staff: per-unit order broken'; end if;
  j2 := pg_temp.as_json(m, q);
  if pg_temp.disorder(j2) <> 0 then raise exception 'FAIL 2 member: per-unit order broken'; end if;
  if (select string_agg(x.rank::text, ',' order by x.rank) from jsonb_to_recordset(j) x(unit_id uuid, rank int) where x.unit_id = ua)
     <> (select string_agg(x.rank::text, ',' order by x.rank) from jsonb_to_recordset(pg_temp.as_json(i, format('select * from public.competition_standings(%L) where audience = ''adult''', e))) x(unit_id uuid, rank int) where x.unit_id = ua) then
    raise exception 'FAIL 2 per-unit rank differs from competition_standings';
  end if;
  perform pg_temp.ok('PASS 2 inside each unit, combined order and ties = competition_standings rank (staff and member views); per-unit rank / prize_rank passed through unchanged');

  -- 3. staff: no place, the next person inherits it across units ---------------
  if (select x.combined_place from jsonb_to_recordset(j) x(display_name text, combined_place int) where x.display_name = 'Zz180 SA') is not null
     or (select x.combined_place from jsonb_to_recordset(j) x(display_name text, combined_place int) where x.display_name = 'Zz180 B3') <> 3 then
    raise exception 'FAIL 3 staff place';
  end if;
  perform pg_temp.ok('PASS 3 staff (SA, 3rd overall) has no place; B3 of the other unit takes place 3; ties share a place (A2 / A3 / B2 = 4) and the next takes 7');

  -- 4. a hidden member: Anonymous to others, exact spot ------------------------
  v := pg_temp.board(j2);
  if v is distinct from 'Zz180 B1:1:1 Zz180 A1:2:2 Zz180 SA:3:- Zz180 B3:4:3 Zz180 A2:5:4 Zz180 A3:5:4 Zz180 B2:5:4 Anonymous:8:7 Zz180 A5:9:8' then
    raise exception 'FAIL 4 member view: %', v;
  end if;
  if (select count(*) from jsonb_to_recordset(j2) x(display_name text, student_id uuid, is_anonymous boolean, classes_count int, belt text)
       where x.display_name = 'Anonymous' and x.student_id is null and x.is_anonymous and x.classes_count is null and x.belt is null) <> 1 then
    raise exception 'FAIL 4 Anonymous row not anonymous';
  end if;
  if pg_temp.board(pg_temp.as_json(h, q)) not like '%Zz180 A4:8:7%' then raise exception 'FAIL 4 own row'; end if;
  perform pg_temp.ok('PASS 4 hidden A4: "Anonymous" with no id / classes / belt for a member, in the same spot (8th, place 7) as staff see it; A4 sees their own name');

  -- 5. kids never ---------------------------------------------------------------
  if (select count(*) from jsonb_to_recordset(pg_temp.as_json(i, format('select * from public.competition_standings(%L)', e))) x(audience text) where x.audience = 'kids') <> 1
     or exists (select 1 from jsonb_to_recordset(j) x(audience text, display_name text) where x.audience <> 'adult' or x.display_name = 'Zz180 K1') then
    raise exception 'FAIL 5 kids';
  end if;
  perform pg_temp.ok('PASS 5 kids rows never returned (K1, 30 pts, is on competition_standings for staff and not here)');

  -- 6. a draft: the admin's alone ---------------------------------------------
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes, published_at)
    values ('Zz180 Draft', 'event', ef, et, 'draft', '[]', now()) returning id into d_c;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (d_c, ua, 'adult', 'Zz180 D A') returning id into xA;
  perform pg_temp.res(d_c, ef, et, xA, sA1, ua, 'adult', 'Zz180 A1', 7, 2, T - 30, true, false, 1, 1);
  q := format('select * from public.competition_standings_all_units(%L)', d_c);
  if jsonb_array_length(pg_temp.as_json(m, q)) <> 0 or jsonb_array_length(pg_temp.as_json(i, q)) <> 0 or jsonb_array_length(pg_temp.as_json(o, q)) <> 1 then
    raise exception 'FAIL 6 draft: member % instructor % owner %', pg_temp.as_json(m, q), pg_temp.as_json(i, q), pg_temp.as_json(o, q);
  end if;
  perform pg_temp.ok('PASS 6 a draft competition returns nothing to a member or an instructor; the admin (owner) sees it');

  -- 7. a closed month returns its frozen rows ---------------------------------
  mf := (date_trunc('month', T) - interval '1 month')::date; mt := (date_trunc('month', T) - interval '1 day')::date;
  insert into public.competitions (name, kind, status, prizes) values ('Zz180 Monthly', 'monthly', 'archived', '[]') returning id into m_c;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (m_c, ua, 'adult', 'Zz180 M A') returning id into mA;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (m_c, ub, 'adult', 'Zz180 M B') returning id into mB;
  insert into public.competition_month_closes (competition_id, period_from, period_to) values (m_c, mf, mt);
  perform pg_temp.res(m_c, mf, mt, mA, sA2, ua, 'adult', 'Zz180 A2', 9.5, 4, mf + 3, true, false, 1, 1);
  perform pg_temp.res(m_c, mf, mt, mB, sB2, ub, 'adult', 'Zz180 B2', 11,  5, mf + 2, true, false, 1, 1);
  v := pg_temp.board(pg_temp.as_json(m, format('select * from public.competition_standings_all_units(%L, %L, %L)', m_c, mf, mt)));
  if v is distinct from 'Zz180 B2:1:1 Zz180 A2:2:2' then raise exception 'FAIL 7 closed month: %', v; end if;
  perform pg_temp.ok('PASS 7 a closed month returns its frozen rows (competition_results), combined: ' || v);

  -- 8. grants --------------------------------------------------------------------
  if has_function_privilege('anon', 'public.competition_standings_all_units(uuid,date,date)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_standings_all_units(uuid,date,date)', 'execute')
     or (select prosecdef from pg_proc where oid = 'public.competition_standings_all_units(uuid,date,date)'::regprocedure) then
    raise exception 'FAIL 8 grants / invoker';
  end if;
  perform pg_temp.ok('PASS 8 SECURITY INVOKER; execute for authenticated, not anon / public');

  -- 9. live, read-only: October and the Christmas Cup ---------------------------
  select id into mon from public.competitions where kind = 'monthly' and status = 'active' and name = 'Monthly race';
  select id into cup from public.competitions where kind = 'event' and name = 'Christmas Cup 2026';
  select s.user_id into real_member from public.students s join public.users u on u.id = s.user_id
   where u.role = 'student' and u.status = 'approved' and s.active is not false
     and not exists (select 1 from public.unit_owners x where x.user_id = u.id)
   order by s.created_at limit 1;
  select id into real_owner from auth.users where lower(email) = 'me@johnluhr.com.au';
  foreach p in array array[real_member, real_owner] loop
    foreach pq in array array[format('%L, %L, %L', mon, '2026-10-01', '2026-10-31'), format('%L, null, null', cup)] loop
      j  := pg_temp.as_json(p, 'select * from public.competition_standings_all_units(' || pq || ')');
      j2 := pg_temp.as_json(p, 'select * from public.competition_standings(' || pq || ')');
      if j ? 'err' or j2 ? 'err' then raise exception 'FAIL 9 live error % %', j, j2; end if;
      v := pg_temp.per_unit(j); w := pg_temp.per_unit(j2);
      if v <> w or pg_temp.disorder(j) <> 0
         or exists (select 1 from jsonb_to_recordset(j) x(audience text) where x.audience <> 'adult') then
        raise exception 'FAIL 9 live % %: all units % per-unit boards %', p, pq, v, w;
      end if;
      perform pg_temp.ok('PASS 9 live ' || case when p = real_owner then 'owner' else 'member' end || ' '
        || case when pq like '%2026-10-01%' then 'October' else 'Christmas Cup' end
        || ': rows per unit (all/on board) = the per-unit boards: '
        || (select string_agg(u.name || ' ' || split_part(z.tok, ':', 2), ', ' order by u.name)
              from unnest(string_to_array(v, ' ')) z(tok) join public.units u on u.id::text = split_part(z.tok, ':', 1))
        || '; per-unit order kept; tags '
        || (select string_agg(distinct x.unit_short, '/' order by x.unit_short) from jsonb_to_recordset(j) x(unit_short text)));
      if exists (select 1 from jsonb_to_recordset(j) x(unit_id uuid, unit_short text)
                  where x.unit_short is distinct from case x.unit_id when 'c851cef5-d5b7-4d5b-b400-11f6ca760970' then 'NB'
                                                                     when '3654625a-a157-4392-966a-7be69d4b0c6e' then 'CD' end) then
        raise exception 'FAIL 9 live % %: unit_short is not NB / CD', p, pq;
      end if;
    end loop;
  end loop;

  -- 10. units.short_code ----------------------------------------------------------
  v := (select string_agg(u.id || '=' || coalesce(u.short_code, '-'), ' ' order by u.id) from public.units u
         where u.id in ('c851cef5-d5b7-4d5b-b400-11f6ca760970', '3654625a-a157-4392-966a-7be69d4b0c6e'));
  if v is distinct from '3654625a-a157-4392-966a-7be69d4b0c6e=CD c851cef5-d5b7-4d5b-b400-11f6ca760970=NB' then
    raise exception 'FAIL 10 live codes: %', v;
  end if;
  foreach pq in array array['X', 'ABCDE', 'NB'] loop
    begin
      update public.units set short_code = pq where id = ua;
      raise exception 'FAIL 10 short_code % accepted', pq;
    exception when check_violation or unique_violation then null;
    end;
  end loop;
  update public.units set short_code = 'ZA' where id = ua;   -- B keeps none: falls back to its name
  w := (select string_agg(distinct x.display_name || '=' || x.unit_short, ' ' order by x.display_name || '=' || x.unit_short)
          from jsonb_to_recordset(pg_temp.as_json(m, format('select * from public.competition_standings_all_units(%L)', e))) x(display_name text, unit_short text)
         where x.display_name in ('Zz180 A1', 'Zz180 B1'));
  if w is distinct from 'Zz180 A1=ZA Zz180 B1=Zz180 B' then raise exception 'FAIL 10 unit_short: %', w; end if;
  if (select attnum from pg_attribute where attrelid = 'public.units'::regclass and attname = 'short_code') is null
     or (select proargnames[array_upper(proargnames, 1)] from pg_proc
          where oid = 'public.competition_standings_all_units(uuid,date,date)'::regprocedure) <> 'unit_short' then
    raise exception 'FAIL 10 unit_short is not the last column';
  end if;
  perform pg_temp.ok('PASS 10 units.short_code: ' || v || ' (by id); 1 or 5 characters and a duplicate rejected; '
    || 'unit_short last column: ' || w);
end $$;

select n, line from v180 order by n;

rollback;
