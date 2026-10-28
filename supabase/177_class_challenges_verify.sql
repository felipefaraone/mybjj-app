-- 177_class_challenges_verify.sql
--
-- Run AFTER 177, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/177_class_challenges_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the Zz177 units, users,
-- classes, events, challenges, TV screen and audit rows included). Every test
-- prints "PASS n ..." (NOTICE, and the rows selected at the end); the first
-- failure stops it with "FAIL n ...".
-- Dates are relative to the Sydney today T (dow X). Fixture units:
--   Zz177 A: event A active T-9..T-9+15 (ends T+6, prizes T+7), class_challenge 3;
--            classes A1 (Adults, day X, 18:00), A1k (Kids, day X, 18:00), A2 (Adults, day X+1)
--   Zz177 B: event B active T+20..T+40 (not started), class_challenge 2; class B1 (day X)
--   Zz177 C: event C active T-3..T+10, class_challenge disabled; class C1 (day X)
--   Zz177 D: event D DRAFT T-3..T+10, class_challenge 3; class D1 (day X)
--   Zz177 E: no event; class E1 (day X)
-- "Before" for the TV is the live _tv_payload as it was before 177, exactly,
-- as pg_temp.tv_payload_live (SECURITY DEFINER dropped: a pg_temp function).

begin;

create temp table v177 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v177 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- the RPCs as a user: the result, or "ERR <message>" (the role and claims of a
-- failed call are undone with its subtransaction)
create function pg_temp.as_save(u uuid, k uuid, t text, d date) returns text language plpgsql as $f$
declare v uuid;
begin
  begin
    perform pg_temp.v_as(u);
    v := public.class_challenge_save(k, t, d);
    execute 'reset role';
    return v::text;
  exception when others then return 'ERR ' || sqlerrm;
  end;
end $f$;
create function pg_temp.as_remove(u uuid, i uuid) returns text language plpgsql as $f$
begin
  begin
    perform pg_temp.v_as(u);
    perform public.class_challenge_remove(i);
    execute 'reset role';
    return 'ok';
  exception when others then return 'ERR ' || sqlerrm;
  end;
end $f$;
-- the range as "<date>/<class key>/<kind>/<text>/<points>" (class key from the map)
create temp table k177 (id uuid primary key, k text);
create function pg_temp.as_range(u uuid, un uuid, f date, t date) returns text language plpgsql as $f$
declare v text; j jsonb;
begin
  begin
    perform pg_temp.v_as(u);
    select jsonb_agg(to_jsonb(r)) into j from public.class_challenges_for_range(un, f, t) r;
    execute 'reset role';
    -- formatted as postgres (k177 is not the caller's to read), in the RPC's order
    select string_agg(r.on_date || '/' || coalesce(m.k, r.class_id::text) || '/' || r.kind || '/' || r.text || '/' || r.points, ', ' order by o)
      into v from jsonb_array_elements(coalesce(j, '[]'::jsonb)) with ordinality e(x, o)
     cross join lateral jsonb_to_record(e.x) as r(class_id uuid, on_date date, kind text, text text, points numeric)
      left join k177 m on m.id = r.class_id;
    return coalesce(v, 'none');
  exception when others then return 'ERR ' || sqlerrm;
  end;
end $f$;
-- every date in [f, t] where _class_challenge_for(k) returns a row, as "+n/kind/text" (n = days from T)
create function pg_temp.days(k uuid, f date, t date, tod date) returns text language sql stable as $f$
  select coalesce(string_agg((d::date - tod)::text || '/' || c.kind || '/' || c.text || '/' || c.points, ', ' order by d), 'none')
    from generate_series(f, t, interval '1 day') d
   cross join lateral public._class_challenge_for(k, d::date) c
$f$;
-- a payload without the up_next blocks' 'challenge' key
create function pg_temp.strip(p jsonb) returns jsonb language sql immutable as $f$
  select case when jsonb_typeof(p -> 'up_next') = 'array'
              then jsonb_set(p, '{up_next}', (select coalesce(jsonb_agg(b - 'challenge' order by o), '[]'::jsonb)
                                                from jsonb_array_elements(p -> 'up_next') with ordinality t(b, o)))
              else p end
$f$;
create function pg_temp.blocks(p jsonb) returns text language sql immutable as $f$
  select coalesce(string_agg((b ->> 'audience') || ' ' || (b ->> 'time') || ' challenge=' || coalesce(b -> 'challenge', 'null'::jsonb)::text,
                             ' ; ' order by o), 'no up_next')
    from jsonb_array_elements(p -> 'up_next') with ordinality t(b, o)
$f$;
CREATE FUNCTION pg_temp.tv_payload_live(p_screen uuid, p_today date, p_now time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c          public.competitions;
  v_unit     uuid;
  v_unit_nm  text;
  v_phase    text;
  v_from     date;
  v_to       date;
  v_places   integer := 0;
  v_week     jsonb;
  v_all      jsonb;     -- this unit's ranked rows, hidden members removed (sid internal)
  v_battle   jsonb;
  v_boards   jsonb := '{}'::jsonb;
  v_chase    jsonb := '{}'::jsonb;
  v_rules    jsonb;
  v_feed     jsonb;
  v_feed7    integer := 0;
  v_feed7a   integer := 0;     -- 157: adult items only
  v_feed7k   integer := 0;     -- 160: kids items only
  v_show_bat boolean := false; -- 157: tv_screens.show_battle
  v_cands    jsonb;            -- 157: today's classes (the next class bar's rows)
  v_focus    text;             -- 157: 'kids' / 'adult' / null (everything)
  v_bat_a    boolean;
  v_bat_k    boolean;
  v_cupc     public.competitions;   -- 161: the event that just ended here
  v_cup      jsonb;                 -- 161: its block (provisional / published)
  v_cupscr   text[] := '{}';        -- 161: its screens for this focus
  v_cupw     numeric[] := '{}';
  v_nr       integer;               -- 161: how many race screens lead the playlist
  v_nowm     numeric;          -- 158: now, minutes since midnight
  v_run      jsonb;            -- 158: classes running now
  v_wt       time;             -- 158: the window classes' start (latest start in the window)
  v_win      jsonb;            -- 158: window classes, held ones removed
  v_upnext   jsonb := '[]'::jsonb;  -- 158: one block per audience of the window classes
  v_g        record;
  v_blk      jsonb;
  v_psql     text;             -- 158: who is on a class's list, and their status
  v_state    text;             -- 158: next_class.state
  v_nc       jsonb;            -- 158: the class next_class describes
  v_ncid     uuid;
  v_nct      time;
  v_gi       jsonb;
  v_last     jsonb;
  v_next     jsonb;
  v_play     jsonb := '[]'::jsonb;
  v_list     jsonb;
  v_el       jsonb;
  v_a        jsonb;
  v_b        jsonb;
  v_gap      numeric;
  v_p        integer;
  v_aud      text;
  v_pf       date;
  v_pt       date;
  v_mc       uuid;              -- 174: the unit's Monthly race
  v_mpub     date;              -- 174: the Sydney day its last month was published
  v_exc      jsonb;
  v_arr      jsonb := '[]'::jsonb;  -- 164: who has arrived for the window classes
  v_cls      record;
  v_going    jsonb;
  v_screens  text[] := '{}';
  v_weights  numeric[] := '{}';
  v_sum      numeric;
  v_secs     integer[];
  v_left     integer;
  i          integer;
begin
  select s.unit_id, u.name::text, coalesce(s.show_battle, false) into v_unit, v_unit_nm, v_show_bat
    from public.tv_screens s join public.units u on u.id = s.unit_id
   where s.id = p_screen;
  if v_unit is null then
    return null;
  end if;

  -- The board in force (competition_for_date's choice; drafts never).
  select x.* into c
    from public.competitions x
   where x.status = 'active' and x.kind = 'event'
     and p_today between x.starts_on and x.ends_on                  -- 161: the event drives the board only while it runs
     and exists (select 1 from public.competition_divisions d where d.competition_id = x.id and d.unit_id = v_unit)
   order by x.starts_on desc, x.created_at desc
   limit 1;
  if c.id is null then
    select x.* into c
      from public.competitions x
     where x.status = 'active' and x.kind = 'monthly'
     order by x.created_at desc
     limit 1;
  end if;
  if c.id is null then
    return jsonb_build_object('generated_at', now(), 'today', p_today,
      'unit', jsonb_build_object('name', v_unit_nm), 'theme', null, 'competition', null,
      'playlist', '[]'::jsonb);
  end if;

  if c.kind = 'event' then
    v_from   := c.starts_on;
    v_to     := c.ends_on;
    v_phase  := 'live';                                              -- 161: no automatic final phase
    v_places := case when jsonb_typeof(c.prizes) = 'array' then jsonb_array_length(c.prizes) else 0 end;
  else
    v_from  := date_trunc('month', p_today)::date;
    v_to    := (date_trunc('month', p_today) + interval '1 month - 1 day')::date;
    v_phase := 'live';
  end if;

  -- Points in the last 7 days (the tale of the tape), same engine.
  select coalesce(jsonb_object_agg(w.student_id::text, w.points), '{}'::jsonb) into v_week
    from public._competition_scores(c.id, greatest(v_from, p_today - 6), least(v_to, p_today)) w
   where w.unit_id = v_unit and w.points > 0;

  -- One scoring run: this unit's rows. 159: the battle of both units comes from
  -- the one source, public._competition_battle (158's formula, same p_today).
  with r as materialized (
    select * from public._competition_ranked(c.id, v_from, v_to)
  )
  select
    -- 166: a hidden member keeps their spot as "Anonymous" (no id, name, photo or
    -- belt; 'anonymous' true); the feed, Up next and arrivals still never show them
    (select coalesce(jsonb_agg(jsonb_build_object(
              'sid', case when r.leaderboard_hidden is true then null else r.student_id end,
              'audience', r.audience, 'minor', r.minor, 'rank', r.rank, 'prize_rank', r.prize_rank,
              'name', case when r.leaderboard_hidden is true then 'Anonymous' else r.display_name end,
              'photo_path', case when r.minor or r.leaderboard_hidden is true then null else nullif(r.photo_url, '') end,
              'belt', case when r.leaderboard_hidden is true then null else r.belt end,
              'degree', case when r.leaderboard_hidden is true then 0 else coalesce(r.degree, 0) end,
              'points', r.points, 'classes', r.classes_count,
              'gi', r.gi_points, 'nogi', r.nogi_points,
              'week', coalesce((v_week ->> r.student_id::text)::numeric, 0),
              'staff', r.prize_eligible is false) || case when r.leaderboard_hidden is true then jsonb_build_object('anonymous', true) else '{}'::jsonb end
            order by r.audience, r.rank, case when r.leaderboard_hidden is true then 'Anonymous' else r.display_name end), '[]'::jsonb)
       from r
      where r.unit_id = v_unit),                                                -- 166: hidden rows kept, as Anonymous
    (select jsonb_build_object(
              'adult', coalesce(jsonb_agg(b.o order by b.nm) filter (where b.audience = 'adult'), '[]'::jsonb),
              'kids',  coalesce(jsonb_agg(b.o order by b.nm) filter (where b.audience = 'kids'),  '[]'::jsonb))
       from (select x.audience, x.unit_name as nm,                                         -- 159
                    jsonb_build_object('unit', x.unit_name, 'here', x.unit_id = v_unit,
                      'active', x.active_students,
                      'classes', x.total_classes,
                      'avg', case when x.active_students = 0 then 0::numeric else round(x.avg_classes, 2) end,
                      'points', x.points,
                      'base', x.base,
                      'per_member', x.per_member) as o
               from public._competition_battle(c.id, v_from, v_to, p_today) x
              where x.unit_name is not null) b)
    into v_all, v_battle;

  -- Boards (top 10 with points) and the chase, per audience.
  foreach v_aud in array array['adult', 'kids'] loop
    select coalesce(jsonb_agg(e order by (e ->> 'rank')::integer, e ->> 'name'), '[]'::jsonb) into v_list
      from jsonb_array_elements(v_all) e
     where e ->> 'audience' = v_aud and (e ->> 'points')::numeric > 0;
    v_boards := v_boards || jsonb_build_object(v_aud, jsonb_build_object(
      'count', jsonb_array_length(v_list),
      'rows', coalesce((select jsonb_agg(x - 'sid' order by n)
                          from jsonb_array_elements(v_list) with ordinality t(x, n) where n <= 10), '[]'::jsonb)));

    -- 175: the chase is between prize places only (staff have none). One list
    -- per audience, the one the event branch built: prize place, then name. A
    -- hidden member stays in it as Anonymous (hidden is not staff). v_list is
    -- not read after the board above, so it becomes that list.
    select coalesce(jsonb_agg(e order by (e ->> 'prize_rank')::integer, e ->> 'name'), '[]'::jsonb) into v_list
      from jsonb_array_elements(v_list) e where (e ->> 'staff')::boolean is false and e ->> 'prize_rank' is not null;
    v_el := null;
    if v_phase = 'live' and jsonb_array_length(v_list) >= 2 then
      v_a := v_list -> 0;
      v_b := v_list -> 1;
      v_gap := (v_a ->> 'points')::numeric - (v_b ->> 'points')::numeric;
      if v_gap <= greatest(3, (v_a ->> 'points')::numeric * 0.15) then
        -- place = the leader's prize place
        v_el := jsonb_build_object('kind', 'first', 'place', (v_a ->> 'prize_rank')::integer,
                  'a', v_a - 'sid', 'b', v_b - 'sid', 'gap', v_gap);
      else
        -- the fight for the last prize place; with no prizes (the monthly race),
        -- the fight for 3rd
        v_p := case when v_places > 0 then v_places else 3 end;
        v_a := v_list -> (v_p - 1);
        v_b := v_list -> v_p;
        if v_a is not null and v_b is not null then
          v_el := jsonb_build_object('kind', 'place', 'place', v_p, 'prize', v_places > 0,
                    'a', v_a - 'sid', 'b', v_b - 'sid',
                    'gap', (v_a ->> 'points')::numeric - (v_b ->> 'points')::numeric, 'lead_gap', v_gap);
        end if;
      end if;
    end if;
    v_chase := v_chase || jsonb_build_object(v_aud, v_el);
  end loop;

  -- How to score: the enabled rules that give points.
  select coalesce(jsonb_agg(jsonb_build_object('key', r.rule_key, 'label', k.label,
                    'description', k.description, 'points', r.points) order by k.sort, r.rule_key), '[]'::jsonb)
    into v_rules
    from public.competition_rules r
    join public.competition_rule_catalog k on k.key = r.rule_key
   where r.competition_id = c.id and r.enabled is true and r.points > 0;

  -- Latest points: awards that count and referral points, in the period up to
  -- today, for this unit's visible members (the scoring rules, not re-derived).
  with vis as (
    select (e ->> 'sid')::uuid as sid, e from jsonb_array_elements(v_all) e
  ),
  rl as (
    select r.rule_key, r.points, k.label, k.source
      from public.competition_rules r
      join public.competition_rule_catalog k on k.key = r.rule_key
     where r.competition_id = c.id and r.enabled is true and r.points > 0
  ),
  ev as (
    select w.student_id as sid, w.award_key as key, w.award_date as d, w.created_at as ts, rl.points, rl.label
      from public.competition_awards w
      join rl on rl.rule_key = w.award_key and rl.source = 'award'
     where w.voided_at is null
       and w.award_date between v_from and least(v_to, p_today)
       and w.student_id in (select vis.sid from vis)
       and public._competition_award_counts(w.student_id, w.class_id, w.class_date)
    union all
    select tb.referred_by_student_id, x.key, x.d, x.ts, rl.points, rl.label
      from public.trial_bookings tb
     cross join lateral (values
       ('referral_trial',      public.trial_first_attended_on(tb.id), null::timestamptz),
       ('referral_conversion', (tb.converted_at at time zone 'Australia/Sydney')::date, tb.converted_at)
     ) as x(key, d, ts)
      join rl on rl.rule_key = x.key and rl.source = 'referral'
     where tb.referred_by_student_id in (select vis.sid from vis)
       and tb.converted_student_id is distinct from tb.referred_by_student_id
       and x.d between v_from and least(v_to, p_today)
  )
  select coalesce((select jsonb_agg(jsonb_build_object(
                     'name', v.e ->> 'name', 'audience', v.e ->> 'audience', 'minor', v.e -> 'minor', 'photo_path', v.e -> 'photo_path',
                     'belt', v.e -> 'belt', 'degree', v.e -> 'degree',                 -- 158
                     'key', z.key, 'label', z.label, 'points', z.points, 'date', z.d)
                     order by z.d desc, z.ts desc nulls last, z.key)
                    from (select * from ev order by ev.d desc, ev.ts desc nulls last, ev.key limit 10) z
                    join vis v on v.sid = z.sid), '[]'::jsonb),
         (select count(*) from ev where ev.d >= p_today - 6)::integer,
         (select count(*) from ev join vis v on v.sid = ev.sid
           where ev.d >= p_today - 6 and v.e ->> 'audience' = 'adult')::integer,
         (select count(*) from ev join vis v on v.sid = ev.sid                        -- 160
           where ev.d >= p_today - 6 and v.e ->> 'audience' = 'kids')::integer
    into v_feed, v_feed7, v_feed7a, v_feed7k;

  -- Top in Gi and No-Gi (adults).
  select jsonb_build_object(
           'gi',   coalesce((select jsonb_agg(x - 'sid' order by n) from (
                      select e as x, row_number() over (order by (e ->> 'gi')::numeric desc, e ->> 'name') as n
                        from jsonb_array_elements(v_all) e
                       where e ->> 'audience' = 'adult' and (e ->> 'gi')::numeric > 0) q where n <= 3), '[]'::jsonb),
           'nogi', coalesce((select jsonb_agg(x - 'sid' order by n) from (
                      select e as x, row_number() over (order by (e ->> 'nogi')::numeric desc, e ->> 'name') as n
                        from jsonb_array_elements(v_all) e
                       where e ->> 'audience' = 'adult' and (e ->> 'nogi')::numeric > 0) q where n <= 3), '[]'::jsonb))
    into v_gi;
  if v_gi -> 'gi' = '[]'::jsonb and v_gi -> 'nogi' = '[]'::jsonb then
    v_gi := null;
  end if;

  -- 174: last month's places. Read from the frozen close (_month_title_rows) of
  -- the unit's Monthly race, whatever competition c is (an event such as the
  -- Christmas Cup included). Places 1-3 are prize_rank: staff are never placed
  -- and a tie shares its place (every tied row comes through). Shown from the
  -- Sydney day the month was published, for 7 days; before the close, nothing.
  -- 'rank' carries the place (the key tv.html reads); 'place' is the same value.
  v_pf := (date_trunc('month', p_today) - interval '1 month')::date;
  v_pt := (date_trunc('month', p_today) - interval '1 day')::date;
  select x.id into v_mc
    from public.competitions x
   where x.kind = 'monthly' and x.status = 'active'
     and exists (select 1 from public.competition_divisions d where d.competition_id = x.id and d.unit_id = v_unit)
   order by x.created_at desc
   limit 1;
  select (m.published_at at time zone 'Australia/Sydney')::date into v_mpub
    from public.competition_month_closes m
   where m.competition_id = v_mc and m.period_from = v_pf and m.period_to = v_pt;
  if v_mpub is not null and p_today between v_mpub and v_mpub + 6 then
    select case when count(*) = 0 then null else jsonb_build_object('month_start', v_pf,
             'adult', coalesce(jsonb_agg(q.o order by q.place, q.nm) filter (where q.audience = 'adult'), '[]'::jsonb),
             'kids',  coalesce(jsonb_agg(q.o order by q.place, q.nm) filter (where q.audience = 'kids'),  '[]'::jsonb)) end
      into v_last
      from (select t.audience, t.place, q0.nm,                                     -- 166: hidden = Anonymous
                   jsonb_build_object('rank', t.place, 'name', q0.nm, 'minor', t.minor,
                     'photo_path', case when t.minor or t.leaderboard_hidden then null else nullif(t.photo_url, '') end,
                     'belt', case when t.leaderboard_hidden then null else t.belt end,
                     'degree', case when t.leaderboard_hidden then 0 else coalesce(t.degree, 0) end, 'points', t.points,
                     'staff', false)                                               -- 174: staff are never placed
                   || case when t.leaderboard_hidden then jsonb_build_object('anonymous', true) else '{}'::jsonb end
                   || jsonb_build_object('place', t.place) as o
              from public._month_title_rows(v_mc, v_pf) t
             cross join lateral (select case when t.leaderboard_hidden then 'Anonymous' else t.display_name end as nm) q0
             where t.unit_id = v_unit) q;
  end if;

  -- The next class today at this unit (the one on now, until it ends) and who is
  -- going. uniform / level / class_exceptions live outside the repo's migrations:
  -- read defensively, and a failure here drops only next_class.
  begin
    v_cands := public._classes_on_day(v_unit, p_today);                         -- 164: one source
    -- 158: the class window. running: start <= now < start + duration.
    -- window: start - 30 min <= now < start + 15 min; the latest start wins (every
    -- class with that start). A window class is held while a DIFFERENT running
    -- class has the other audience (Kids vs Adults; All conflicts with nobody).
    v_nowm := extract(epoch from p_now) / 60;
    select coalesce(jsonb_agg(x order by (x ->> 't')::time desc, x ->> 'aud'), '[]'::jsonb) into v_run
      from jsonb_array_elements(v_cands) x
     where extract(epoch from (x ->> 't')::time) / 60 <= v_nowm
       and extract(epoch from (x ->> 't')::time) / 60 + (x ->> 'dur')::integer > v_nowm;
    select max((x ->> 't')::time) into v_wt                                    -- 164: one source
      from jsonb_array_elements(public._classes_in_window(v_unit, p_today, p_now)) x;
    select coalesce(jsonb_agg(w order by case lower(w ->> 'aud') when 'adults' then 1 when 'kids' then 2 else 3 end,
                                          w ->> 'class_id'), '[]'::jsonb) into v_win
      from jsonb_array_elements(v_cands) w
     where (w ->> 't')::time = v_wt
       and not exists (select 1 from jsonb_array_elements(v_run) r
                        where (r ->> 't')::time <> v_wt
                          and lower(r ->> 'aud') in ('kids', 'adults') and lower(w ->> 'aud') in ('kids', 'adults')
                          and lower(r ->> 'aud') <> lower(w ->> 'aud'));
    -- 158: focus. The running class's audience wins until it ends (Kids -> kids,
    -- Adults -> adult, All or more than one -> everything); else the window
    -- classes'; else everything.
    select case when count(distinct lower(x ->> 'aud')) = 1 and min(lower(x ->> 'aud')) = 'kids'   then 'kids'
                when count(distinct lower(x ->> 'aud')) = 1 and min(lower(x ->> 'aud')) = 'adults' then 'adult' end
      into v_focus
      from jsonb_array_elements(case when jsonb_array_length(v_run) > 0 then v_run else v_win end) x;

    -- 158: who is on a class's list ($1 = its class rows), as the going list
    -- reads them, and their status: 'here' (present; or going and present today
    -- here in a class still running or ended at most 15 minutes before this one
    -- starts), else 'on_the_way'. Here first (latest arrival first), then by name;
    -- 60 at most. The counts are for the whole list.
    v_psql := $q$
      with cls as (
        select (x ->> 'class_id')::uuid as class_id, (x ->> 't')::time as t from jsonb_array_elements($1) x
      ), att as (
        select distinct on (a.student_id)
               a.student_id, a.status::text as status, a.attended_at, c.t as ct,
               a.arrived_at,                                                   -- 164
               public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                       public._competition_minor(s.prog::text)) as name,
               public._competition_minor(s.prog::text) as minor,
               nullif(s.photo_url::text, '') as photo, s.belt::text as belt, coalesce(s.degree::integer, 0) as degree
          from public.attendance a
          join cls c on ((c.class_id is not null and a.class_id = c.class_id)
                         or (c.class_id is null and a.class_id is null and a.unit_id = $3
                             and left(a.class_time::text, 5) = to_char(c.t, 'HH24:MI')))
          join public.students s on s.id = a.student_id
         where a.class_date = $2 and a.status in ('going', 'present') and s.leaderboard_hidden is not true
         order by a.student_id, (a.status = 'present') desc, a.attended_at desc
      ), ppl as (
        select t.*,
               case when t.status = 'present' or t.arrived_at is not null then 'here'   -- 164: arrived
                    when exists (
                      select 1
                        from public.attendance a2
                        left join public.classes k2 on k2.id = a2.class_id
                       where a2.student_id = t.student_id and a2.class_date = $2 and a2.status = 'present'
                         and a2.unit_id = $3 and a2.class_time::text ~ '^\d{1,2}:\d{2}'
                         and left(a2.class_time::text, 5)::time < t.ct
                         and (extract(epoch from left(a2.class_time::text, 5)::time) / 60
                              + coalesce(k2.duration_minutes,
                                         (select (x ->> 'dur')::integer from jsonb_array_elements($5) x
                                           where x ->> 'class_id' is null
                                             and to_char((x ->> 't')::time, 'HH24:MI') = to_char(left(a2.class_time::text, 5)::time, 'HH24:MI')
                                           limit 1),
                                         60))
                             > least(extract(epoch from $4) / 60, extract(epoch from t.ct) / 60 - 15) - 0.0001
                    ) then 'here'
                    else 'on_the_way' end as st
          from att t
      )
      select jsonb_build_object(
        'here', (select count(*) from ppl where st = 'here'),
        'on_the_way', (select count(*) from ppl where st <> 'here'),
        'people', coalesce((select jsonb_agg(z.o order by z.n) from (
            select jsonb_build_object('name', p.name, 'minor', p.minor,
                     'photo_path', case when p.minor then null else p.photo end,
                     'belt', p.belt, 'degree', p.degree, 'status', p.st) as o,
                   row_number() over (order by (p.st = 'here') desc,
                                               case when p.st = 'here' then coalesce(p.arrived_at, p.attended_at) end desc nulls last,  -- 164
                                               p.name, p.student_id) as n
              from ppl p) z where z.n <= 60), '[]'::jsonb))
    $q$;

    -- 158: Up next, one block per audience of the (unheld) window classes
    for v_g in
      select lower(w ->> 'aud') as k, min(w ->> 'aud') as aud, jsonb_agg(w) as cls,
             string_agg(distinct public._tv_class_label(w ->> 'uni', w ->> 'lvl', w ->> 'typ'), ' + ') as label
        from jsonb_array_elements(v_win) w
       group by lower(w ->> 'aud')
       order by case lower(w ->> 'aud') when 'adults' then 1 when 'kids' then 2 else 3 end
    loop
      execute v_psql into v_blk using v_g.cls, p_today, v_unit, p_now, v_cands;
      v_upnext := v_upnext || jsonb_build_array(jsonb_build_object(
        'time', to_char(v_wt, 'HH24:MI'), 'label', v_g.label, 'audience', v_g.aud,
        'starts_at', to_char(v_wt, 'HH24:MI'),
        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way', 'people', v_blk -> 'people'));
    end loop;

    -- 164: arrivals for the classes in the window (the TV welcome), newest first;
    -- hidden members never appear; a row marked absent is not an arrival
    select coalesce(jsonb_agg(jsonb_build_object(
             'sid', s.id,
             'name', public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                             public._competition_minor(s.prog::text)),
             'minor', public._competition_minor(s.prog::text),
             'photo_path', case when public._competition_minor(s.prog::text) then null else nullif(s.photo_url::text, '') end,
             'belt', s.belt::text, 'degree', coalesce(s.degree::integer, 0),
             'audience', w ->> 'aud', 'class_time', to_char((w ->> 't')::time, 'HH24:MI'),
             'arrived_at', a.arrived_at)
           order by a.arrived_at desc, s.id), '[]'::jsonb)
      into v_arr
      from jsonb_array_elements(public._classes_in_window(v_unit, p_today, p_now)) w
      join public.attendance a
        on a.class_date = p_today
       and ((w ->> 'class_id' is not null and a.class_id = (w ->> 'class_id')::uuid)
            or (w ->> 'class_id' is null and a.class_id is null and a.unit_id = v_unit
                and left(a.class_time::text, 5) = to_char((w ->> 't')::time, 'HH24:MI')))
      join public.students s on s.id = a.student_id
     where a.arrived_at is not null and a.status in ('going', 'present')
       and s.leaderboard_hidden is not true;

    -- 158: the class next_class describes, and its state: 'window' (a window
    -- class), 'on' (a class running, no window class), 'far' (the next class
    -- today, outside its window); none left today: next_class null.
    v_nc := null;
    if jsonb_array_length(v_win) > 0 then
      v_state := 'window'; v_nc := v_win -> 0;
    elsif jsonb_array_length(v_run) > 0 then
      v_state := 'on'; v_nc := v_run -> 0;
    else
      select x into v_nc from jsonb_array_elements(v_cands) x
       where extract(epoch from (x ->> 't')::time) / 60 > v_nowm
       order by (x ->> 't')::time, x ->> 'aud'
       limit 1;
      v_state := 'far';
    end if;
    if v_nc is not null then
      v_ncid := (v_nc ->> 'class_id')::uuid;
      v_nct := (v_nc ->> 't')::time;
      execute v_psql into v_blk using jsonb_build_array(v_nc), p_today, v_unit, p_now, v_cands;
      -- going (the pre-158 key, read by tv.html before 158): only inside the
      -- window or while the class is on, never plans made from home hours ahead
      v_going := '[]'::jsonb;
      if v_state <> 'far' then
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', public._tv_display_name(s.first_name::text, s.last_name::text, s.full_name::text,
                                                 public._competition_minor(s.prog::text)),
                 'kid', public._competition_minor(s.prog::text),      -- 156: minor (tv.html before 156 reads 'kid')
                 'minor', public._competition_minor(s.prog::text),
                 'photo_path', case when public._competition_minor(s.prog::text) then null
                                    else nullif(s.photo_url::text, '') end,
                 'belt', s.belt::text, 'degree', coalesce(s.degree::integer, 0),
                 'here', a.status = 'present')
               order by a.attended_at desc, s.id), '[]'::jsonb)
          into v_going
          from public.attendance a
          join public.students s on s.id = a.student_id
         where a.class_date = p_today
           and a.status in ('going', 'present')
           and s.leaderboard_hidden is not true
           and ((v_ncid is not null and a.class_id = v_ncid)
                or (v_ncid is null and a.class_id is null and a.unit_id = v_unit
                    and left(a.class_time::text, 5) = to_char(v_nct, 'HH24:MI')));
      end if;
      v_next := jsonb_build_object(
        'time', to_char(v_nct, 'HH24:MI'), 'duration', (v_nc ->> 'dur')::integer,
        'label', public._tv_class_label(v_nc ->> 'uni', v_nc ->> 'lvl', v_nc ->> 'typ'),
        'uniform', coalesce(v_nc ->> 'uni', case when v_nc ->> 'typ' in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'Gi'
                                                 else 'No-Gi' end),
        'audience', v_nc ->> 'aud',
        'going', v_going,
        'state', v_state,                                                        -- 158
        'opens_at', to_char(v_nct - interval '30 minutes', 'HH24:MI'),           -- 158
        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way');           -- 158
    end if;
  exception when others then
    raise warning '155 tv next_class skipped: % (%)', sqlerrm, sqlstate;
    v_next := null;
    v_focus := null;
    v_upnext := '[]'::jsonb;                                                     -- 158
    v_arr := '[]'::jsonb;                                                        -- 164
  end;

  -- 161: the Cup that ended here: provisional until an owner publishes it, then
  -- its champions until results_until (default the last day of the month after
  -- ends_on) or until another event starts here. Kids and adults apart.
  select x.* into v_cupc
    from public.competitions x
   where x.kind = 'event' and x.status <> 'draft' and x.ends_on < p_today
     and exists (select 1 from public.competition_divisions d where d.competition_id = x.id and d.unit_id = v_unit)
     and (x.published_at is null
          or p_today <= coalesce(x.results_until, (date_trunc('month', x.ends_on) + interval '2 months' - interval '1 day')::date))
     and not exists (select 1 from public.competitions y
                      where y.kind = 'event' and y.status <> 'draft' and y.id <> x.id
                        and y.starts_on > x.ends_on and y.starts_on <= p_today
                        and exists (select 1 from public.competition_divisions d2 where d2.competition_id = y.id and d2.unit_id = v_unit))
   order by x.ends_on desc, x.created_at desc
   limit 1;
  if v_cupc.id is not null then
    if v_cupc.published_at is not null then
      select jsonb_build_object(
               'name', v_cupc.name, 'phase', 'published', 'ends_on', v_cupc.ends_on,
               'results_until', coalesce(v_cupc.results_until, (date_trunc('month', v_cupc.ends_on) + interval '2 months' - interval '1 day')::date),
               'adult', jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'adult'))[1], '{}'::jsonb),
                                           'champions', coalesce((array_agg(q.champs) filter (where q.aud = 'adult'))[1], '[]'::jsonb)),
               'kids',  jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'kids'))[1], '{}'::jsonb),
                                           'champions', coalesce((array_agg(q.champs) filter (where q.aud = 'kids'))[1], '[]'::jsonb)))
        into v_cup
        from (select cr.payload ->> 'audience' as aud,
                     jsonb_build_object('classes', coalesce(sum((cr.payload ->> 'classes_count')::integer), 0),
                                        'members', count(*) filter (where cr.points > 0),
                                        'points', coalesce(sum(cr.points), 0),
                                        -- 163: check ins are bonus points too (0 in a snapshot made before 163)
                                        'bonus', coalesce(sum((cr.payload ->> 'award_points')::numeric + (cr.payload ->> 'referral_points')::numeric
                                                              + coalesce((cr.payload ->> 'checkin_points')::numeric, 0)), 0)) as nums,
                     coalesce(jsonb_agg(jsonb_build_object(
                       'place', cr.prize_rank,
                       'anonymous', coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false),
                       'name', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then 'Anonymous' else cr.payload ->> 'display_name' end,
                       'minor', coalesce((cr.payload ->> 'minor')::boolean, false),
                       'photo_path', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false)
                                            or coalesce((cr.payload ->> 'minor')::boolean, false)
                                            or cr.payload ->> 'audience' = 'kids' then null
                                          else nullif(cr.payload ->> 'photo_url', '') end,
                       'belt', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then null else cr.payload ->> 'belt' end,
                       'degree', case when coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) then null else (cr.payload ->> 'degree')::integer end,
                       'points', cr.points)
                       order by cr.prize_rank, cr.rank, cr.payload ->> 'display_name')
                       filter (where cr.points > 0 and cr.prize_rank is not null and cr.prize_rank <= coalesce((cr.payload ->> 'places')::integer, 0)), '[]'::jsonb) as champs
                from public.competition_results cr
               where cr.competition_id = v_cupc.id and cr.period_from = v_cupc.starts_on and cr.period_to = v_cupc.ends_on
                 and (cr.payload ->> 'unit_id')::uuid = v_unit
               group by cr.payload ->> 'audience') q;
    else
      select jsonb_build_object(
               'name', v_cupc.name, 'phase', 'provisional', 'ends_on', v_cupc.ends_on, 'results_until', null,
               'adult', jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'adult'))[1], '{}'::jsonb), 'champions', '[]'::jsonb),
               'kids',  jsonb_build_object('numbers', coalesce((array_agg(q.nums) filter (where q.aud = 'kids'))[1], '{}'::jsonb), 'champions', '[]'::jsonb))
        into v_cup
        from (select s.audience as aud,
                     jsonb_build_object('classes', coalesce(sum(s.classes_count), 0),
                                        'members', count(*) filter (where s.points > 0),
                                        'points', coalesce(sum(s.points), 0),
                                        'bonus', coalesce(sum(s.award_points + s.referral_points + s.checkin_points), 0)) as nums   -- 163
                from public._competition_scores(v_cupc.id, v_cupc.starts_on, v_cupc.ends_on) s
               where s.unit_id = v_unit
               group by s.audience) q;
    end if;
    -- its screens, one audience each, following the focus
    foreach v_aud in array array['adult', 'kids'] loop
      continue when (v_focus = 'kids' and v_aud <> 'kids') or (v_focus = 'adult' and v_aud <> 'adult');
      continue when coalesce((v_cup -> v_aud -> 'numbers' ->> 'members')::integer, 0) = 0;
      if v_cup ->> 'phase' = 'published' and jsonb_array_length(v_cup -> v_aud -> 'champions') > 0 then
        v_cupscr := v_cupscr || ('cup_champions_' || v_aud)::text; v_cupw := v_cupw || 1.2;
      end if;
      v_cupscr := v_cupscr || ('cup_over_' || v_aud)::text; v_cupw := v_cupw || 1.2;
    end loop;
  end if;

  -- Playlist: 90 seconds, by importance. The races always; then last month's
  -- winners, the chases, how to score (live only), latest points (if any in the
  -- last 7 days), the battle (both units on the board, someone trained), gi /
  -- no-gi (if any).
  -- 157: a Kids class on now shows only the kids screens (race, chase, how to
  -- score, the kids battle); an Adults class only the adult screens (race,
  -- chase, how to score, adult latest points, the adult battle, gi / no-gi). The
  -- battle only on a screen with show_battle. The seconds always sum to 90.
  -- 158: the battle only when both units have a base (members to divide by)
  v_bat_a := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'adult', '[]'::jsonb)) >= 2
             and not exists (select 1 from jsonb_array_elements(v_battle -> 'adult') x where coalesce((x ->> 'base')::integer, 0) <= 0);
  v_bat_k := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'kids', '[]'::jsonb)) >= 2
             and not exists (select 1 from jsonb_array_elements(v_battle -> 'kids') x where coalesce((x ->> 'base')::integer, 0) <= 0);
  if v_focus = 'kids' then
    v_screens := array['race_kids'];
    v_weights := array[1.5];
    if v_chase -> 'kids' <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text; v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_bat_k then v_screens := v_screens || 'battle_kids'::text; v_weights := v_weights || 1.0; end if;
  elsif v_focus = 'adult' then
    v_screens := array['race_adults'];
    v_weights := array[1.5];
    if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_feed7a > 0 then v_screens := v_screens || 'feed_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_bat_a then v_screens := v_screens || 'battle_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;
  else
    v_screens := array['race_adults', 'race_kids'];
    v_weights := array[1.5, 1.5];
    -- 160: one audience per screen (kids and adults never share one)
    if jsonb_array_length(coalesce(v_last -> 'adult', '[]'::jsonb)) > 0 then v_screens := v_screens || 'last_results_adult'::text; v_weights := v_weights || 1.2; end if;
    if jsonb_array_length(coalesce(v_last -> 'kids', '[]'::jsonb)) > 0 then v_screens := v_screens || 'last_results_kids'::text; v_weights := v_weights || 1.2; end if;
    if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_chase -> 'kids'  <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text;   v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_feed7a > 0 then v_screens := v_screens || 'feed_adults'::text; v_weights := v_weights || 1.0; end if;      -- 160
    if v_feed7k > 0 then v_screens := v_screens || 'feed_kids'::text; v_weights := v_weights || 1.0; end if;        -- 160
    if v_bat_a then v_screens := v_screens || 'battle_adults'::text; v_weights := v_weights || 1.0; end if;         -- 160
    if v_bat_k then v_screens := v_screens || 'battle_kids'::text; v_weights := v_weights || 1.0; end if;           -- 160
    if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;
  end if;

  -- 161: the Cup's screens right after the races
  if array_length(v_cupscr, 1) > 0 then
    v_nr := (select count(*) from unnest(v_screens) x where x like 'race\_%');
    v_screens := v_screens[1:v_nr] || v_cupscr || v_screens[v_nr + 1:];
    v_weights := v_weights[1:v_nr] || v_cupw || v_weights[v_nr + 1:];
  end if;

  -- 158: Up next first, one screen per block (weight 1.2)
  if jsonb_array_length(v_upnext) > 0 then
    v_screens := array(select 'up_next_' || case lower(b ->> 'audience') when 'kids' then 'kids' when 'all' then 'all' else 'adult' end
                         from jsonb_array_elements(v_upnext) with ordinality u(b, o) order by o) || v_screens;
    v_weights := array(select 1.2::numeric from jsonb_array_elements(v_upnext)) || v_weights;
  end if;

  select sum(w) into v_sum from unnest(v_weights) w;
  v_secs := array(select floor(90 * w / v_sum)::integer from unnest(v_weights) w);
  v_left := 90 - (select sum(s) from unnest(v_secs) s);
  i := 1;
  while v_left > 0 loop
    v_secs[i] := v_secs[i] + 1;
    v_left := v_left - 1;
    i := i % array_length(v_secs, 1) + 1;
  end loop;
  select jsonb_agg(jsonb_build_object('screen', v_screens[n], 'seconds', v_secs[n]) order by n)
    into v_play from generate_subscripts(v_screens, 1) n;

  return jsonb_build_object(
    'generated_at', now(),
    'today', p_today,
    'unit', jsonb_build_object('name', v_unit_nm),
    'theme', nullif(c.theme ->> 'style', ''),
    'competition', jsonb_build_object('name', c.name, 'kind', c.kind, 'starts_on', c.starts_on,
                     'ends_on', c.ends_on, 'finale_on', c.finale_on, 'places', v_places,
                     'prizes', case when v_places > 0 then c.prizes else '[]'::jsonb end,
                     'phase', v_phase, 'period_from', v_from, 'period_to', v_to),
    'boards', v_boards,
    'chase', v_chase,
    'battle', v_battle,
    'rules', v_rules,
    'feed', v_feed,
    'gi_nogi', v_gi,
    'last_results', v_last,
    'next_class', v_next,
    'up_next', v_upnext,                                                         -- 158
    'cup', v_cup,                                                                -- 161
    'arrivals', v_arr,                                                           -- 164
    'playlist', v_play);
end;
$function$;

do $$
declare
  T date := (now() at time zone 'Australia/Sydney')::date;
  v_x integer;
  ua uuid; ub uuid; uc uuid; ud uuid; ue uuid; eA uuid; eB uuid; eC uuid; eD uuid; scr uuid;
  kA1 uuid; kA1k uuid; kA2 uuid; kB1 uuid; kC1 uuid; kD1 uuid; kE1 uuid;
  u_own uuid := gen_random_uuid(); u_ins uuid := gen_random_uuid(); u_stu uuid := gen_random_uuid();
  u_par uuid := gen_random_uuid(); u_stb uuid := gen_random_uuid(); u_nbi uuid := gen_random_uuid(); u_nbs uuid := gen_random_uuid();
  w_id uuid; d_id uuid; b_id uuid; v text; w text; x2 text; p jsonb; q jsonb; r record; n int;
  nb uuid; cup uuid; knb uuid; knb_t time;
begin
  v_x := extract(dow from T)::integer;

  -- 0. objects, RLS, grants, the audit trigger, _tv_payload's one hunk
  if to_regclass('public.class_challenges') is null
     or not (select relrowsecurity from pg_class where oid = 'public.class_challenges'::regclass)
     or exists (select 1 from pg_policy where polrelid = 'public.class_challenges'::regclass) then
    raise exception 'FAIL 0: class_challenges missing, RLS off or a policy exists';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.class_challenges'::regclass and not t.tgisinternal
                  and t.tgfoid = 'public.audit_row()'::regprocedure and t.tgname = 'trg_audit_class_challenges')
     or not exists (select 1 from pg_indexes where tablename = 'class_challenges' and indexname = 'class_challenges_weekly')
     or not exists (select 1 from pg_indexes where tablename = 'class_challenges' and indexname = 'class_challenges_date') then
    raise exception 'FAIL 0: audit trigger or unique indexes missing';
  end if;
  if has_table_privilege('anon', 'public.class_challenges', 'select,insert,update,delete')
     or has_table_privilege('authenticated', 'public.class_challenges', 'select,insert,update,delete')
     or has_function_privilege('anon', 'public._class_challenge_for(uuid, date)', 'execute')
     or has_function_privilege('authenticated', 'public._class_challenge_for(uuid, date)', 'execute')
     or has_function_privilege('anon', 'public.class_challenges_for_range(uuid, date, date)', 'execute')
     or has_function_privilege('anon', 'public.class_challenge_save(uuid, text, date)', 'execute')
     or has_function_privilege('anon', 'public.class_challenge_remove(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.class_challenges_for_range(uuid, date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.class_challenge_save(uuid, text, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.class_challenge_remove(uuid)', 'execute') then
    raise exception 'FAIL 0: grants';
  end if;
  if not exists (select 1 from pg_proc p
                  where p.oid = to_regprocedure('public._tv_payload(uuid, date, time)') and p.prosecdef and p.proowner::regrole::text = 'postgres'
                    and p.proacl::text = '{postgres=X/postgres}' and p.proconfig::text = '{search_path=public}'
                    and md5(p.prosrc) = '7d368116d535d573abeb2f00f3a2773d'
                    and md5(replace(p.prosrc, $h$        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way', 'people', v_blk -> 'people',
        -- 177: the class challenge set ahead ({text, points}), one source; null when none
        'challenge', (select jsonb_build_object('text', ch.text, 'points', ch.points)
                        from jsonb_array_elements(v_g.cls) cw
                       cross join lateral public._class_challenge_for((cw ->> 'class_id')::uuid, p_today) ch
                       where cw ->> 'class_id' is not null
                       order by cw ->> 'class_id' limit 1)));
$h$, $h$        'here', v_blk -> 'here', 'on_the_way', v_blk -> 'on_the_way', 'people', v_blk -> 'people'));
$h$)) = '4efc44fbbcb7da876f2b26b72f7bd6e8') then
    raise exception 'FAIL 0: _tv_payload is not 175''s text plus the one up_next hunk (or its owner, grants or settings changed)';
  end if;
  perform pg_temp.ok('PASS 0: class_challenges (RLS on, no policies, audit_row trigger, weekly and date unique indexes); '
                     || 'grants: RPCs authenticated only, table and _class_challenge_for closed; _tv_payload md5 7d368116d535d573abeb2f00f3a2773d = 4efc44fbbcb7da876f2b26b72f7bd6e8 + the up_next hunk only');

  -- 9a. live, read-only: both units' payloads now and at 17:45 equal the pre-177 ones but for 'challenge'
  for r in select u.name::text as nm, (select s.id from public.tv_screens s where s.unit_id = u.id order by s.id limit 1) as sid, tm
             from public.units u cross join (values ((now() at time zone 'Australia/Sydney')::time), (time '17:45')) z(tm)
            where u.name in ('Neutral Bay', 'Camperdown') order by u.name desc, tm loop
    if r.sid is null then raise exception 'FAIL 9: no TV screen at %', r.nm; end if;
    p := public._tv_payload(r.sid, T, r.tm);
    q := pg_temp.tv_payload_live(r.sid, T, r.tm);
    if pg_temp.strip(p) is distinct from q
       or exists (select 1 from jsonb_array_elements(p -> 'up_next') b where not (b ? 'challenge')) then
      raise exception 'FAIL 9: % % live payload differs from the pre-177 one outside up_next.challenge', r.nm, r.tm;
    end if;
    perform pg_temp.ok(format('PASS 9a: live %s %s %s: identical to before 177 but for challenge; up_next: %s',
                              r.nm, T, to_char(r.tm, 'HH24:MI'), pg_temp.blocks(p)));
  end loop;

  -- fixtures
  insert into public.units (name) values ('Zz177 A') returning id into ua;
  insert into public.units (name) values ('Zz177 B') returning id into ub;
  insert into public.units (name) values ('Zz177 C') returning id into uc;
  insert into public.units (name) values ('Zz177 D') returning id into ud;
  insert into public.units (name) values ('Zz177 E') returning id into ue;
  select id into nb from public.units where name = 'Neutral Bay';
  insert into auth.users (id, email)
  select x, 'zz177-' || x::text || '@example.invalid' from unnest(array[u_own, u_ins, u_stu, u_par, u_stb, u_nbi, u_nbs]) x;
  insert into public.users (id, email, full_name, role, status, unit_id, active_unit_id)
  select x.id, 'zz177-' || x.id::text || '@example.invalid', x.nm, x.role, 'approved', x.u, x.u
    from (values (u_own, 'Zz177 Owner', 'owner', ua), (u_ins, 'Zz177 Instructor', 'instructor', ua),
                 (u_stu, 'Zz177 Student', 'student', ua), (u_par, 'Zz177 Parent', 'parent', ua),
                 (u_stb, 'Zz177 Student B', 'student', ub),
                 (u_nbi, 'Zz177 NB Instructor', 'instructor', nb), (u_nbs, 'Zz177 NB Student', 'student', nb)) x(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id, active_unit_id = excluded.active_unit_id;
  update public.units set owner_user_id = u_own where id = ua;

  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ua, v_x, '18:00', 'gi', 'Adults') returning id into kA1;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ua, v_x, '18:00', 'gi', 'Kids') returning id into kA1k;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ua, (v_x + 1) % 7, '18:00', 'gi', 'Adults') returning id into kA2;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ub, v_x, '18:00', 'gi', 'Adults') returning id into kB1;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (uc, v_x, '18:00', 'gi', 'Adults') returning id into kC1;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ud, v_x, '18:00', 'gi', 'Adults') returning id into kD1;
  insert into public.classes (unit_id, day_of_week, time, type, audience) values (ue, v_x, '18:00', 'gi', 'Adults') returning id into kE1;
  insert into k177 values (kA1, 'A1'), (kA1k, 'A1k'), (kA2, 'A2'), (kB1, 'B1'), (kC1, 'C1'), (kD1, 'D1'), (kE1, 'E1');

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz177 A', 'event', T - 9, T + 6, T + 7, 'active', '[]') returning id into eA;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz177 B', 'event', T + 20, T + 40, 'active', '[]') returning id into eB;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz177 C', 'event', T - 3, T + 10, 'active', '[]') returning id into eC;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz177 D', 'event', T - 3, T + 10, 'draft', '[]') returning id into eD;
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
    values (eA, ua, 'adult', 'Zz177 A Adults', 0), (eA, ua, 'kids', 'Zz177 A Kids', 1), (eB, ub, 'adult', 'Zz177 B Adults', 0),
           (eC, uc, 'adult', 'Zz177 C Adults', 0), (eD, ud, 'adult', 'Zz177 D Adults', 0);
  insert into public.competition_rules (competition_id, rule_key, points, enabled)
    values (eA, 'class_challenge', 3, true), (eB, 'class_challenge', 2, true), (eC, 'class_challenge', 3, false), (eD, 'class_challenge', 3, true);

  -- 1. weekly during an active event: every day-X occurrence inside it, no other weekday, not after ends_on
  v := pg_temp.as_save(u_ins, kA1, '  Ten clean guard passes  ', null);
  if v like 'ERR%' then raise exception 'FAIL 1: instructor weekly save: %', v; end if;
  w_id := v::uuid;
  if (select competition_id from public.class_challenges where id = w_id) <> eA
     or (select text from public.class_challenges where id = w_id) <> 'Ten clean guard passes' then
    raise exception 'FAIL 1: weekly row not bound to event A or text not trimmed';
  end if;
  v := pg_temp.days(kA1, T - 14, T + 21, T);
  w := pg_temp.days(kA2, T - 14, T + 21, T);
  if v <> '-7/weekly/Ten clean guard passes/3, 0/weekly/Ten clean guard passes/3' or w <> 'none' then
    raise exception 'FAIL 1: A1 %, A2 %', v, w;
  end if;
  x2 := pg_temp.as_range(u_stu, ua, T - 9, T + 4);
  if x2 <> (T - 7) || '/A1/weekly/Ten clean guard passes/3, ' || T || '/A1/weekly/Ten clean guard passes/3' then
    raise exception 'FAIL 1: range T-9..T+4: %', x2;
  end if;
  if pg_temp.as_range(u_stu, ua, T + 1, T + 14) <> 'none' then
    raise exception 'FAIL 1: range after ends_on: %', pg_temp.as_range(u_stu, ua, T + 1, T + 14);
  end if;
  perform pg_temp.ok('PASS 1: weekly on A1 (event A T-9..T+6, prizes T+7): days from T with a challenge ' || v
                     || ' (T+7 is prize day, after ends_on: none); A2 (other weekday): none; range T-9..T+4 as a member: ' || x2);

  -- 2. a one-date challenge wins on its date only (saved by the owner)
  v := pg_temp.as_save(u_own, kA1, 'Sweep from closed guard', T);
  if v like 'ERR%' then raise exception 'FAIL 2: owner date save: %', v; end if;
  d_id := v::uuid;
  v := pg_temp.days(kA1, T - 14, T + 21, T);
  if v <> '-7/weekly/Ten clean guard passes/3, 0/date/Sweep from closed guard/3' then
    raise exception 'FAIL 2: %', v;
  end if;
  w := pg_temp.as_save(u_own, kA1, 'Wrong day', T + 1);
  if w not like 'ERR the class does not run on%' then raise exception 'FAIL 2: a date off the class''s weekday: %', w; end if;
  perform pg_temp.ok('PASS 2: one date on T wins there only: ' || v || '; a date off its weekday refused (' || w || ')');

  -- 6. who may save and remove: the competition_award_add rule (staff or admin)
  v := pg_temp.as_save(u_stu, kA1, 'Student try', null);
  w := pg_temp.as_save(u_par, kA1, 'Parent try', T);
  x2 := pg_temp.as_remove(u_stu, w_id) || ' / ' || pg_temp.as_remove(u_par, d_id);
  if v <> 'ERR not allowed' or w <> 'ERR not allowed' or x2 <> 'ERR not allowed / ERR not allowed'
     or (select count(*) from public.class_challenges where class_id = kA1) <> 2 then
    raise exception 'FAIL 6: student save %, parent save %, removes %', v, w, x2;
  end if;
  perform pg_temp.ok('PASS 6: student and parent: save and remove refused (not allowed); instructor (1) and owner (2) saved');

  -- 5. weekly saved before the event starts binds to it and shows from starts_on
  v := pg_temp.as_save(u_ins, kB1, 'Pass the guard three times', null);
  if v like 'ERR%' then raise exception 'FAIL 5: %', v; end if;
  b_id := v::uuid;
  w := pg_temp.days(kB1, T, T + 50, T);
  if (select competition_id from public.class_challenges where id = b_id) <> eB
     or w <> '21/weekly/Pass the guard three times/2, 28/weekly/Pass the guard three times/2, 35/weekly/Pass the guard three times/2' then
    raise exception 'FAIL 5: bound to %, days %', (select competition_id from public.class_challenges where id = b_id), w;
  end if;
  perform pg_temp.ok('PASS 5: weekly on B1 saved before event B (T+20..T+40) binds to it; shows on ' || w || ' (none before T+20, none after T+40)');

  -- 3. class_challenge disabled, then points 0: save refused, nothing returned (even with a row present)
  v := pg_temp.as_save(u_ins, kC1, 'Disabled', null) || ' | ' || pg_temp.as_save(u_ins, kC1, 'Disabled', T);
  insert into public.class_challenges (class_id, competition_id, on_date, text) values (kC1, eC, null, 'Present but off');
  w := pg_temp.days(kC1, T - 3, T + 10, T) || ' | ' || pg_temp.as_range(u_own, uc, T - 3, T + 10);
  update public.competition_rules set enabled = true, points = 0 where competition_id = eC and rule_key = 'class_challenge';
  x2 := pg_temp.as_save(u_ins, kC1, 'Zero points', null) || ' | ' || pg_temp.days(kC1, T - 3, T + 10, T) || ' | ' || pg_temp.as_range(u_own, uc, T - 3, T + 10);
  if v <> 'ERR no challenge with class challenges in this unit | ERR no challenge with class challenges on ' || T
     or w <> 'none | none' or x2 <> 'ERR no challenge with class challenges in this unit | none | none' then
    raise exception 'FAIL 3: disabled: % ; read % ; points 0: %', v, w, x2;
  end if;
  perform pg_temp.ok('PASS 3: class_challenge disabled: save refused (' || v || '), nothing returned (' || w || '); points 0: ' || x2);

  -- 4. a draft event, or no event: save refused
  v := pg_temp.as_save(u_ins, kD1, 'Draft', null) || ' | ' || pg_temp.as_save(u_ins, kD1, 'Draft', T)
       || ' | ' || pg_temp.as_save(u_ins, kE1, 'No event', null) || ' | ' || pg_temp.as_save(u_ins, kA1, 'After the event', T + 14);
  if v <> 'ERR no challenge with class challenges in this unit | ERR no challenge with class challenges on ' || T
          || ' | ERR no challenge with class challenges in this unit | ERR no challenge with class challenges on ' || (T + 14) then
    raise exception 'FAIL 4: %', v;
  end if;
  perform pg_temp.ok('PASS 4: draft event (weekly, date), no event, a date after event A: all refused: ' || v);

  -- 7. the range follows the classes' visibility, at most 14 days
  v := pg_temp.as_range(u_stb, ua, T - 9, T + 4);
  w := pg_temp.as_range(u_stu, ua, T - 9, T + 5);
  x2 := pg_temp.as_range(u_own, ua, T - 9, T + 4);
  if v <> 'none' or w <> 'ERR at most 14 days' or x2 = 'none' then
    raise exception 'FAIL 7: other unit %, 15 days %, owner %', v, w, x2;
  end if;
  perform pg_temp.ok('PASS 7: a member of Zz177 B reading A: none; 15 days: ' || w || '; A''s owner (admin): ' || x2);

  -- 8. upsert replaces the text, remove deletes, audit rows written
  v := pg_temp.as_save(u_ins, kA1, 'Five guard passes, then a sweep', null);
  w := pg_temp.as_save(u_own, kA1, 'Sweep from half guard', T);
  if v <> w_id::text or w <> d_id::text
     or (select string_agg(coalesce(on_date::text, 'weekly') || '=' || text, ', ' order by on_date nulls first) from public.class_challenges where class_id = kA1)
        <> 'weekly=Five guard passes, then a sweep, ' || T || '=Sweep from half guard' then
    raise exception 'FAIL 8: upsert % / %', v, w;
  end if;
  x2 := pg_temp.as_remove(u_ins, d_id);
  if x2 <> 'ok' or exists (select 1 from public.class_challenges where id = d_id)
     or pg_temp.as_remove(u_ins, d_id) not like 'ERR class challenge % not found' then
    raise exception 'FAIL 8: remove %', x2;
  end if;
  select string_agg(a.op, ',' order by a.id) into v from public.audit_log a where a.table_name = 'class_challenges' and a.row_id = w_id;
  select string_agg(a.op || ':' || coalesce(a.actor_user_id::text = u_own::text or a.actor_user_id::text = u_ins::text, false)::text, ',' order by a.id)
    into w from public.audit_log a where a.table_name = 'class_challenges' and a.row_id = d_id;
  if v <> 'INSERT,UPDATE' or w <> 'INSERT:true,UPDATE:true,DELETE:true' then
    raise exception 'FAIL 8: audit weekly %, date %', v, w;
  end if;
  perform pg_temp.ok('PASS 8: same scope saved again keeps the id and replaces the text; remove deletes (twice: not found); audit_log weekly '
                     || v || ', date ' || w || ' (actor = the caller)');

  -- 9b. the TV at a fixture screen in A on T at 17:45: Adults block carries A1's challenge, Kids block null
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz177 tv', ua, encode(sha256('zz177'::bytea), 'hex')) returning id into scr;
  p := public._tv_payload(scr, T, '17:45');
  q := pg_temp.tv_payload_live(scr, T, '17:45');
  v := pg_temp.blocks(p);
  if pg_temp.strip(p) is distinct from q
     or v <> 'Adults 18:00 challenge={"text": "Five guard passes, then a sweep", "points": 3} ; Kids 18:00 challenge=null' then
    raise exception 'FAIL 9: %', v;
  end if;
  perform pg_temp.ok('PASS 9b: Zz177 A screen T 17:45: ' || v || '; the rest identical to the pre-177 payload');

  -- 10. live, read-only data: the Christmas Cup in both units, a weekly on a real NB class
  select c.id into cup from public.competitions c
   where c.name = 'Christmas Cup 2026' and c.kind = 'event' and c.status = 'active'
     and c.starts_on = '2026-11-02' and c.ends_on = '2026-12-18'
     and exists (select 1 from public.competition_rules cr where cr.competition_id = c.id and cr.rule_key = 'class_challenge' and cr.enabled and cr.points > 0)
     and (select count(distinct d.unit_id) from public.competition_divisions d join public.units u on u.id = d.unit_id
           where d.competition_id = c.id and u.name in ('Neutral Bay', 'Camperdown')) = 2;
  if cup is null then raise exception 'FAIL 10: the Christmas Cup is not active 2026-11-02..2026-12-18 with class_challenge in both units'; end if;
  select k.id, k.time into knb, knb_t from public.classes k
   where k.unit_id = nb and k.active is not false and k.audience = 'Adults' and k.day_of_week = extract(dow from date '2026-11-03')::integer
   order by k.time, k.id limit 1;
  if knb is null then raise exception 'FAIL 10: no NB Adults class on Tuesdays'; end if;
  insert into k177 values (knb, 'NB ' || to_char(knb_t, 'HH24:MI'));
  v := pg_temp.as_save(u_nbi, knb, 'Zz177 three takedowns', null);
  if v like 'ERR%' or (select competition_id from public.class_challenges where id = v::uuid) <> cup then
    raise exception 'FAIL 10: save %', v;
  end if;
  w := pg_temp.as_range(u_nbs, nb, '2026-11-03', '2026-11-09');
  if w not like '%2026-11-03/NB ' || to_char(knb_t, 'HH24:MI') || '/weekly/Zz177 three takedowns/3%' then
    raise exception 'FAIL 10: range %', w;
  end if;
  perform pg_temp.ok('PASS 10: Christmas Cup 2026 active 2026-11-02..2026-12-18, class_challenge 3 in Neutral Bay and Camperdown; '
                     || 'weekly on the NB Tuesday ' || to_char(knb_t, 'HH24:MI') || ' Adults class binds to the Cup; range 2026-11-03..09 as an NB member: ' || w);
end $$;

select n, line from v177 order by n;

rollback;
