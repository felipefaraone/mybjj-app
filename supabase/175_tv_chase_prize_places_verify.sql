-- 175_tv_chase_prize_places_verify.sql
--
-- Run AFTER 175, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/175_tv_chase_prize_places_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the fixture users,
-- students, attendance, event and TV screen included). Every test prints
-- "PASS n ..." (NOTICE, and the rows selected at the end); the first failure
-- stops it with "FAIL n ...".
-- "Before" is the live _tv_payload as it was before 175, exactly, as
-- pg_temp.tv_payload_live (SECURITY DEFINER dropped: a pg_temp function).
-- Fixture: 2001 (no real attendance, closes or events then), the REAL monthly
-- race, adults and kids of one of its units, a TV screen there. Classes:
--                July (race)  August (race)  September (Zz175 Cup, 3 prizes)
--   Sam (staff)      10            8              12
--   Ann               9           20              20
--   Bob               8           12              10
--   Cal               5            9               8
--   Dee               4            6               6
--   Eve               -            3               -
--   kids: Kim (hidden) 6, Kit 5, Kev 2 in July and in September.

begin;

create temp table v175 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v175 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
-- one chase as "kind/place[ prize]: A vs B gap G" (first word of each name; "(staff)" when staff)
create function pg_temp.ch(p jsonb, aud text) returns text language sql immutable as $f$
  select case when p -> 'chase' -> aud is null or jsonb_typeof(p -> 'chase' -> aud) = 'null' then 'none'
    else format('%s/%s%s: %s%s vs %s%s gap %s',
           c ->> 'kind', c ->> 'place', case when (c ->> 'prize')::boolean then ' prize' else '' end,
           split_part(c -> 'a' ->> 'name', ' ', 1), case when (c -> 'a' ->> 'staff')::boolean then '(staff)' else '' end,
           split_part(c -> 'b' ->> 'name', ' ', 1), case when (c -> 'b' ->> 'staff')::boolean then '(staff)' else '' end,
           c ->> 'gap') end
    from (select p -> 'chase' -> aud as c) x
$f$;
create function pg_temp.screens(p jsonb) returns text language sql immutable as $f$
  select coalesce(string_agg(x ->> 'screen', ',' order by o), '') from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;

-- the live _tv_payload before 175, exactly (the "before" of tests 1 to 7)
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

    v_el := null;
    if v_phase = 'live' and jsonb_array_length(v_list) >= 2 then
      v_a := v_list -> 0;
      v_b := v_list -> 1;
      v_gap := (v_a ->> 'points')::numeric - (v_b ->> 'points')::numeric;
      if v_gap <= greatest(3, (v_a ->> 'points')::numeric * 0.15) then
        -- place = the leader's real rank (a hidden member above keeps 1st)
        v_el := jsonb_build_object('kind', 'first', 'place', (v_a ->> 'rank')::integer,
                  'a', v_a - 'sid', 'b', v_b - 'sid', 'gap', v_gap);
      else
        -- the fight for the last prize place (prize places skip staff); with no
        -- prizes (the monthly race), the fight for 3rd on the board
        if v_places > 0 then
          v_p := v_places;
          select coalesce(jsonb_agg(e order by (e ->> 'prize_rank')::integer, e ->> 'name'), '[]'::jsonb) into v_b
            from jsonb_array_elements(v_list) e where (e ->> 'staff')::boolean is false and e ->> 'prize_rank' is not null;
          v_a := v_b -> (v_p - 1);
          v_b := v_b -> v_p;
        else
          v_p := 3;
          v_a := v_list -> (v_p - 1);
          v_b := v_list -> v_p;
        end if;
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
  mc uuid; ua uuid; scr uuid; ev uuid; u_sam uuid := gen_random_uuid();
  s_sam uuid; s_ann uuid; s_bob uuid; s_cal uuid; s_dee uuid; s_eve uuid; s_kim uuid; s_kit uuid; s_kev uuid;
  p jsonb; q jsonb; v text; w text; r record; v_tod date; v_now time;
begin
  -- 0. same function: signature, SECURITY DEFINER, owner, grants, search_path; body is 175's
  if not exists (select 1 from pg_proc p
                  where p.oid = to_regprocedure('public._tv_payload(uuid, date, time)')
                    and p.prosecdef and p.proowner::regrole::text = 'postgres'
                    and p.proacl::text = '{postgres=X/postgres}' and p.proconfig::text = '{search_path=public}'
                    and p.provolatile = 's' and pg_get_function_result(p.oid) = 'jsonb'
                    and md5(p.prosrc) = '4efc44fbbcb7da876f2b26b72f7bd6e8') then
    raise exception 'FAIL 0: _tv_payload(uuid, date, time) is not 175''s (security definer, owner postgres, execute postgres only, search_path public)';
  end if;
  perform pg_temp.ok('PASS 0: _tv_payload(uuid, date, time without time zone) returns jsonb, STABLE SECURITY DEFINER, owner postgres, '
                     || 'grants {postgres=X/postgres}, search_path=public (as before 175); body md5 4efc44fbbcb7da876f2b26b72f7bd6e8');

  -- 5. live, read-only: the real payload now, both units (before any fixture row)
  v_tod := (now() at time zone 'Australia/Sydney')::date;
  v_now := (now() at time zone 'Australia/Sydney')::time;
  for r in select u.name::text as nm, (select s.id from public.tv_screens s where s.unit_id = u.id order by s.id limit 1) as sid
             from public.units u where u.name in ('Neutral Bay', 'Camperdown') order by u.name desc loop
    if r.sid is null then raise exception 'FAIL 5: no TV screen at %', r.nm; end if;
    p := public._tv_payload(r.sid, v_tod, v_now);
    q := pg_temp.tv_payload_live(r.sid, v_tod, v_now);
    if (p - 'chase' - 'playlist') is distinct from (q - 'chase' - 'playlist') then
      raise exception 'FAIL 7: % live payload differs outside the chase and the playlist', r.nm;
    end if;
    if exists (select 1 from jsonb_each(p -> 'chase') e where jsonb_typeof(e.value) = 'object'
                and ((e.value -> 'a' ->> 'staff')::boolean or (e.value -> 'b' ->> 'staff')::boolean)) then
      raise exception 'FAIL 5: % has a staff fighter: adults % / kids %', r.nm, pg_temp.ch(p, 'adult'), pg_temp.ch(p, 'kids');
    end if;
    perform pg_temp.ok(format('PASS 5: %s %s %s: adults %s ; kids %s ; playlist %s  [before 175: adults %s ; kids %s ; playlist %s]',
                              r.nm, v_tod, to_char(v_now, 'HH24:MI'), pg_temp.ch(p, 'adult'), pg_temp.ch(p, 'kids'), pg_temp.screens(p),
                              pg_temp.ch(q, 'adult'), pg_temp.ch(q, 'kids'), pg_temp.screens(q)));
  end loop;
  perform pg_temp.ok('PASS 7a: live payloads of both units identical to the pre-175 ones outside chase and playlist');

  -- fixture
  select id into mc from public.competitions where kind = 'monthly' and status = 'active' order by created_at desc limit 1;
  if mc is null then raise exception 'FAIL setup: no active monthly competition'; end if;
  select d.unit_id into ua from public.competition_divisions d where d.competition_id = mc
   group by d.unit_id having count(distinct d.audience) = 2 order by d.unit_id limit 1;
  if ua is null then raise exception 'FAIL setup: the monthly race needs a unit with adults and kids'; end if;
  if exists (select 1 from public.competitions where kind = 'event' and starts_on <= '2001-09-30' and ends_on >= '2001-07-01')
     or exists (select 1 from public.attendance where class_date between '2001-07-01' and '2001-09-30') then
    raise exception 'FAIL setup: July to September 2001 are not empty';
  end if;

  insert into auth.users (id, email) values (u_sam, 'zz175-' || u_sam::text || '@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id)
  values (u_sam, 'zz175-' || u_sam::text || '@example.invalid', 'Zz Sam', 'instructor', 'approved', ua)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Sam Staff','Sam','Staff','adult',ua,true,'ok','black',2,u_sam,null,false,false) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Ann Alpha','Ann','Alpha','adult',ua,true,'ok','purple',1,null,null,false,true) returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Bob Beta','Bob','Beta','adult',ua,true,'ok','blue',1,null,null,false,true) returning id into s_bob;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Cal Gamma','Cal','Gamma','adult',ua,true,'ok','blue',0,null,null,false,true) returning id into s_cal;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Dee Delta','Dee','Delta','adult',ua,true,'ok','white',2,null,null,false,true) returning id into s_dee;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Eve Eps','Eve','Eps','adult',ua,true,'ok','white',0,null,null,false,true) returning id into s_eve;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Kim Kid','Kim','Kid','kids',ua,true,'ok','grey/white',0,null,null,true,true) returning id into s_kim;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Kit Kid','Kit','Kid','kids',ua,true,'ok','yellow',0,null,null,false,true) returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree,
                               user_id, photo_url, leaderboard_hidden, prize_eligible)
  values ('Zz175 Kev Kid','Kev','Kid','kids',ua,true,'ok','white',0,null,null,false,true) returning id into s_kev;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select y.sid, null, y.m + g, '18:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_sam, date '2001-07-01', 10), (s_ann, date '2001-07-01', 9), (s_bob, date '2001-07-01', 8),
                 (s_cal, date '2001-07-01', 5), (s_dee, date '2001-07-01', 4),
                 (s_sam, date '2001-08-01', 8), (s_ann, date '2001-08-01', 20), (s_bob, date '2001-08-01', 12),
                 (s_cal, date '2001-08-01', 9), (s_dee, date '2001-08-01', 6), (s_eve, date '2001-08-01', 3),
                 (s_sam, date '2001-09-01', 12), (s_ann, date '2001-09-01', 20), (s_bob, date '2001-09-01', 10),
                 (s_cal, date '2001-09-01', 8), (s_dee, date '2001-09-01', 6),
                 (s_kim, date '2001-07-01', 6), (s_kit, date '2001-07-01', 5), (s_kev, date '2001-07-01', 2),
                 (s_kim, date '2001-09-01', 6), (s_kit, date '2001-09-01', 5), (s_kev, date '2001-09-01', 2)) y(sid, m, k)
   cross join generate_series(0, 29) g
   where g < y.k;
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz175 tv', ua, encode(sha256('zz175'::bytea), 'hex')) returning id into scr;

  -- 1 and 4. July (monthly race): Sam (staff) 1st on raw points; Ann and Bob within the gap
  p := public._tv_payload(scr, '2001-07-30', '10:00');
  q := pg_temp.tv_payload_live(scr, '2001-07-30', '10:00');
  v := pg_temp.ch(p, 'adult');
  if p -> 'competition' ->> 'kind' <> 'monthly' or (p -> 'boards' -> 'adult' -> 'rows' -> 0 ->> 'staff')::boolean is not true
     or v not like 'first/1: Ann vs Bob gap %' then
    raise exception 'FAIL 1: July adults % (board leader staff: %)', v, p -> 'boards' -> 'adult' -> 'rows' -> 0 ->> 'staff';
  end if;
  perform pg_temp.ok(format('PASS 1: monthly race, staff 1st on the board (%s): chase %s, no staff  [before 175: %s]',
                            split_part(p -> 'boards' -> 'adult' -> 'rows' -> 0 ->> 'name', ' ', 1), v, pg_temp.ch(q, 'adult')));
  if (p -> 'chase' -> 'adult' ->> 'place')::integer <> 1 or (p -> 'chase' -> 'adult' -> 'a' ->> 'prize_rank')::integer <> 1
     or (p -> 'chase' -> 'adult' -> 'a' ->> 'rank')::integer <> 2 then
    raise exception 'FAIL 4: place % for a leader of prize place % and rank %', p -> 'chase' -> 'adult' ->> 'place',
      p -> 'chase' -> 'adult' -> 'a' ->> 'prize_rank', p -> 'chase' -> 'adult' -> 'a' ->> 'rank';
  end if;
  perform pg_temp.ok('PASS 4: ''first'' with staff above the leader: place 1 (the leader''s prize place; raw rank 2)');
  -- 6. a hidden member keeps their place as Anonymous, exactly as before (kids, no staff)
  w := pg_temp.ch(p, 'kids');
  if p -> 'chase' -> 'kids' is distinct from q -> 'chase' -> 'kids' or w not like 'first/1: Anonymous vs Kit gap %' then
    raise exception 'FAIL 6: July kids % (before %)', w, pg_temp.ch(q, 'kids');
  end if;
  perform pg_temp.ok(format('PASS 6: hidden leader stays Anonymous, kids chase identical to before: %s', w));
  if (p - 'chase' - 'playlist') is distinct from (q - 'chase' - 'playlist') then raise exception 'FAIL 7: July payload differs outside the chase'; end if;

  -- 2. August (monthly race): Sam (staff) between prize 3rd (Cal) and prize 4th (Dee)
  p := public._tv_payload(scr, '2001-08-30', '10:00');
  q := pg_temp.tv_payload_live(scr, '2001-08-30', '10:00');
  v := pg_temp.ch(p, 'adult');
  if v not like 'place/3: Cal vs Dee gap %' or (p -> 'chase' -> 'adult' ->> 'prize')::boolean
     or (select string_agg(split_part(x ->> 'name', ' ', 1) || coalesce('=' || (x ->> 'prize_rank'), '/staff'), ' ' order by o)
           from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') with ordinality t(x, o)) <> 'Ann=1 Bob=2 Cal=3 Sam/staff Dee=4 Eve=5' then
    raise exception 'FAIL 2: August adults %', v;
  end if;
  perform pg_temp.ok(format('PASS 2: monthly race, staff between prize 3rd and 4th: chase %s (no prize wording), no staff  [before 175: %s]',
                            v, pg_temp.ch(q, 'adult')));
  if (p - 'chase' - 'playlist') is distinct from (q - 'chase' - 'playlist') then raise exception 'FAIL 7: August payload differs outside the chase'; end if;

  -- 3. September: an event with 3 prizes, Sam (staff) 2nd on raw points: same a, b and place as before
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes, theme)
    values ('Zz175 Cup', 'event', '2001-09-01', '2001-09-30', null, 'active',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]'::jsonb, '{}'::jsonb) returning id into ev;
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
    values (ev, ua, 'adult', 'Zz175 Adults', 0), (ev, ua, 'kids', 'Zz175 Kids', 1);
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values (ev, 'class_attended', 1, true);
  p := public._tv_payload(scr, '2001-09-29', '10:00');
  q := pg_temp.tv_payload_live(scr, '2001-09-29', '10:00');
  v := pg_temp.ch(p, 'adult');
  if p -> 'competition' ->> 'name' <> 'Zz175 Cup' or v not like 'place/3 prize: Cal vs Dee gap %'
     or (p -> 'chase' -> 'adult') - 'lead_gap' is distinct from (q -> 'chase' -> 'adult') - 'lead_gap'
     or p -> 'chase' -> 'kids' is distinct from q -> 'chase' -> 'kids' then
    raise exception 'FAIL 3: event adults % (before %), kids % (before %)', v, pg_temp.ch(q, 'adult'), pg_temp.ch(p, 'kids'), pg_temp.ch(q, 'kids');
  end if;
  perform pg_temp.ok(format('PASS 3: event with 3 prizes: adults %s, same a, b, place, prize and gap as before; lead_gap %s (before %s: '
                            || 'prize 1st minus prize 2nd, was minus the staff 2nd); kids chase identical (%s)',
                            v, p -> 'chase' -> 'adult' ->> 'lead_gap', q -> 'chase' -> 'adult' ->> 'lead_gap', pg_temp.ch(p, 'kids')));
  if (p - 'chase' - 'playlist') is distinct from (q - 'chase' - 'playlist') then raise exception 'FAIL 7: event payload differs outside the chase'; end if;
  perform pg_temp.ok('PASS 7: July, August and the event: payload identical to the pre-175 one outside chase and playlist');
end $$;

select n, line from v175 order by n;

rollback;
