-- ============================================================================
-- 164 — Arrival check in (QR at the door, "I'm here" in the app)
-- ============================================================================
--
-- Mario and John (Phase F). Scanning the door QR, or tapping "I'm here" on the
-- class card, records that the person ARRIVED. The coach still marks Present,
-- and only Present counts for points (163's bonus included).
--
-- 1. attendance.arrived_at timestamptz null, arrived_via text null ('qr' / 'app').
--    The existing checked_in_at is NOT arrival: 24 added it with default now(),
--    nothing writes it explicitly (the app never sends it) and nothing reads it,
--    so it is the row's creation time (the "I'm going" tap, or staff adding the
--    row). It stays as it is.
-- 2. One source for the classes of a day and the class window: _classes_on_day
--    (158's query out of _tv_payload) and _classes_in_window (30 min before the
--    start until 15 min after, Sydney). _tv_payload (163's text, changes marked
--    "164") calls them; its output is otherwise unchanged.
-- 3. checkin_arrive(unit, students, via, class) and checkin_preview(unit,
--    students, class), over one internal _checkin (see the notes there).
-- 4. _tv_payload: on Up next a person is "here" when present or arrived (plus
--    158's carryover); 'arrivals' lists who arrived for the window classes.
--
-- Rollback: 164_arrival_checkin_rollback.sql (163's _tv_payload exactly).
-- Checks: 164_arrival_checkin_verify.sql.
-- ============================================================================

begin;

do $$
declare
  v_src text;
  v_bad text;
begin
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public._tv_payload(uuid, date, time)');
  if v_src is null or (md5(v_src) <> '72450a467c4747282c786dbf9f9cb859' and position('-- 164' in v_src) = 0) then
    raise exception '164 preflight: _tv_payload is not 163''s text (apply 163 first); stop and compare';
  end if;
  if to_regprocedure('public._attendance_is_self(uuid, uuid)') is null then
    raise exception '164 preflight: apply 163 first';
  end if;
  select string_agg(x.t || '.' || x.c, ', ') into v_bad
    from (values ('attendance', 'id'), ('attendance', 'student_id'), ('attendance', 'unit_id'), ('attendance', 'class_id'),
                 ('attendance', 'class_legacy_id'), ('attendance', 'class_date'), ('attendance', 'class_time'),
                 ('attendance', 'class_type'), ('attendance', 'modality'), ('attendance', 'gi'), ('attendance', 'status'),
                 ('attendance', 'class_value'), ('attendance', 'created_by'), ('attendance', 'attended_at'),
                 ('students', 'user_id'), ('students', 'parent_user_id'), ('students', 'standing'), ('students', 'prog'),
                 ('students', 'leaderboard_hidden'), ('units', 'active'),
                 ('classes', 'unit_id'), ('classes', 'day_of_week'), ('classes', 'time'), ('classes', 'type'),
                 ('classes', 'duration_minutes'), ('classes', 'audience'), ('classes', 'active')) x(t, c)
   where not exists (select 1 from information_schema.columns i
                      where i.table_schema = 'public' and i.table_name = x.t and i.column_name = x.c);
  if v_bad is not null then
    raise exception '164 preflight: missing columns: %', v_bad;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'attendance'
                and ((column_name = 'arrived_at' and data_type <> 'timestamp with time zone')
                     or (column_name = 'arrived_via' and data_type <> 'text'))) then
    raise exception '164 preflight: attendance.arrived_at / arrived_via exist with another type; stop';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The arrival columns
-- ---------------------------------------------------------------------------
alter table public.attendance add column if not exists arrived_at  timestamptz null;
alter table public.attendance add column if not exists arrived_via text null;
alter table public.attendance drop constraint if exists attendance_arrived_via_check;
alter table public.attendance add constraint attendance_arrived_via_check check (arrived_via in ('qr', 'app'));
comment on column public.attendance.arrived_at is
  '164: when the person arrived (door QR or I''m here), server time; set once by checkin_arrive. Not presence: the coach marks present.';

-- ---------------------------------------------------------------------------
-- 2. One source for the day's classes and the window
-- ---------------------------------------------------------------------------
create or replace function public._classes_on_day(p_unit uuid, p_day date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_exc jsonb := '[]'::jsonb;
  v_c   jsonb;
begin
  -- 158's query (from _tv_payload), unchanged, plus two keys at the end of each
  -- row: legacy (the id the app's class-instance key and doCI's class_legacy_id
  -- use: classes.legacy_id, else the class id; a one-off's
  -- "<date>_<HH:MM>_oneoff_<exception id>") and ex_id (a one-off's exception).
  -- uniform / level / class_exceptions live outside the repo's migrations: read
  -- defensively.
  if to_regclass('public.class_exceptions') is not null then
    execute 'select coalesce(jsonb_agg(to_jsonb(e)), ''[]''::jsonb) from public.class_exceptions e
              where e.unit_id = $1 and e.exception_date = $2'
       into v_exc using p_unit, p_day;
  end if;
  select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) into v_c from (
    select k.id as class_id, k.time as t, coalesce(k.duration_minutes, 60) as dur,
           nullif(to_jsonb(k) ->> 'uniform', '') as uni, nullif(to_jsonb(k) ->> 'level', '') as lvl,
           k.type::text as typ, coalesce(nullif(k.audience, ''), 'Adults') as aud,
           coalesce(nullif(to_jsonb(k) ->> 'legacy_id', ''), k.id::text) as legacy, null::text as ex_id
      from public.classes k
     where k.unit_id = p_unit
       and k.day_of_week = extract(dow from p_day)::integer
       and k.active is not false
       and not exists (select 1 from jsonb_array_elements(v_exc) x where x ->> 'kind' = 'closed')
       and not exists (select 1 from jsonb_array_elements(v_exc) x
                        where x ->> 'kind' = 'cancelled' and x ->> 'class_id' = k.id::text)
    union all
    select null, (x ->> 'oneoff_time')::time, coalesce((x ->> 'oneoff_duration_minutes')::integer, 60),
           nullif(x ->> 'oneoff_uniform', ''), nullif(x ->> 'oneoff_level', ''), null,
           coalesce(nullif(x ->> 'oneoff_audience', ''), 'Adults'),
           to_char(p_day, 'YYYY-MM-DD') || '_' || to_char((x ->> 'oneoff_time')::time, 'HH24:MI') || '_oneoff_' || (x ->> 'id'),
           x ->> 'id'
      from jsonb_array_elements(v_exc) x
     where x ->> 'kind' = 'oneoff' and nullif(x ->> 'oneoff_time', '') is not null
  ) q;
  return v_c;
end;
$$;

-- The class window (158): from 30 minutes before a class starts until 15 minutes
-- after, on Sydney's clock. Every class of the day in its window at p_time.
create or replace function public._classes_in_window(p_unit uuid, p_day date, p_time time)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb)
    from jsonb_array_elements(public._classes_on_day(p_unit, p_day)) x
   where extract(epoch from (x ->> 't')::time) / 60 - 30 <= extract(epoch from p_time) / 60
     and extract(epoch from (x ->> 't')::time) / 60 + 15 > extract(epoch from p_time) / 60
$$;


revoke all on function public._classes_on_day(uuid, date) from public, anon, authenticated;
revoke all on function public._classes_in_window(uuid, date, time) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. _tv_payload (163's text; 164 changes marked)
-- ---------------------------------------------------------------------------
create or replace function public._tv_payload(p_screen uuid, p_today date, p_now time)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
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
    (select coalesce(jsonb_agg(jsonb_build_object(
              'sid', r.student_id, 'audience', r.audience, 'minor', r.minor, 'rank', r.rank, 'prize_rank', r.prize_rank,
              'name', r.display_name,
              'photo_path', case when r.minor then null else nullif(r.photo_url, '') end,
              'belt', r.belt, 'degree', coalesce(r.degree, 0),
              'points', r.points, 'classes', r.classes_count,
              'gi', r.gi_points, 'nogi', r.nogi_points,
              'week', coalesce((v_week ->> r.student_id::text)::numeric, 0),
              'staff', r.prize_eligible is false)
            order by r.audience, r.rank, r.display_name), '[]'::jsonb)
       from r
      where r.unit_id = v_unit and r.leaderboard_hidden is not true),
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

  -- Last month's top 3 (monthly race, first 7 days of a month).
  if c.kind = 'monthly' and extract(day from p_today) <= 7 then
    v_pf := (date_trunc('month', p_today) - interval '1 month')::date;
    v_pt := (date_trunc('month', p_today) - interval '1 day')::date;
    select case when count(*) = 0 then null else jsonb_build_object('month_start', v_pf,
             'adult', coalesce(jsonb_agg(q.o order by q.rank, q.nm) filter (where q.audience = 'adult'), '[]'::jsonb),
             'kids',  coalesce(jsonb_agg(q.o order by q.rank, q.nm) filter (where q.audience = 'kids'),  '[]'::jsonb)) end
      into v_last
      from (select r.audience, r.rank, r.display_name as nm,
                   jsonb_build_object('rank', r.rank, 'name', r.display_name, 'minor', r.minor,
                     'photo_path', case when r.minor then null else nullif(r.photo_url, '') end,
                     'belt', r.belt, 'degree', coalesce(r.degree, 0), 'points', r.points,
                     'staff', r.prize_eligible is false) as o,
                   row_number() over (partition by r.audience order by r.rank, r.display_name) as n
              from public._competition_ranked(c.id, v_pf, v_pt) r
             where r.unit_id = v_unit and r.leaderboard_hidden is not true and r.points > 0) q
     where q.n <= 3;
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
$$;

-- ---------------------------------------------------------------------------
-- 3. Arrival check in. _checkin does the work for one unit and its classes in
--    the window at p_at (server time); checkin_preview reads, checkin_arrive
--    writes. Per student:
--      not_allowed  not the caller's own row, nor a kid the caller manages (the
--                   attendance insert policy: students.user_id, the legacy
--                   parent_user_id, or is_guardian_of(student, 'manage'))
--      on_hold      standing on_hold: nothing written (the class card's rule)
--      no_class     no class in the window fits; opens_at = when the next
--                   fitting class today opens (start - 30 min), or null
--      invalid_class  p_class is not a fitting class in the window
--      ready / arrived / already   (preview / just set / arrived_at was set)
--    The class: p_class when valid; else the window class the student already
--    has a row for; else the nearest fitting class (start closest to now, then
--    the earlier start). Fitting = the app's class list rule: a kids programme
--    sees Kids and All, everyone else Adults and All.
--    No row yet: the row doCI inserts (same fields: student_id, unit_id = the
--    class's unit, class_id, class_legacy_id, class_date, class_time HH:MM,
--    class_type, modality, gi, status 'going'; class_value its default). The
--    caller inserts it, so 163's created_by makes the self check in bonus
--    apply once the coach marks it present. Then arrived_at / arrived_via are
--    set only while arrived_at is null; status, class_value and confirmed_by
--    are never touched.
-- ---------------------------------------------------------------------------
create or replace function public._checkin(p_unit uuid, p_student_ids uuid[], p_via text, p_class jsonb,
                                           p_at timestamptz, p_write boolean)
returns table (
  student_id      uuid,
  result          text,
  class_id        uuid,
  class_date      date,
  class_time      text,
  class_label     text,
  class_audience  text,
  class_legacy_id text,
  attendance_id   uuid,
  status          text,
  arrived_at      timestamptz,
  opens_at        text,
  options         jsonb
)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_uid  uuid := auth.uid();
  v_loc  timestamp := p_at at time zone 'Australia/Sydney';
  v_day  date := (p_at at time zone 'Australia/Sydney')::date;
  v_time time := (p_at at time zone 'Australia/Sydney')::time;
  v_nowm numeric := extract(epoch from (p_at at time zone 'Australia/Sydney')::time) / 60;
  v_cands jsonb;
  v_win   jsonb;
  v_fit   jsonb;
  v_pick  jsonb;
  v_aud   text;
  v_mod   text;
  v_id    uuid;
  v_cid   uuid;          -- the picked class (locals: the output names are also column names)
  v_t     text;
  v_done  boolean;
  st      record;
  a       record;
begin
  if p_via is null or p_via not in ('qr', 'app') then
    raise exception 'p_via must be qr or app' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.units u where u.id = p_unit and u.active is not false) then
    raise exception 'unknown unit' using errcode = 'invalid_parameter_value';
  end if;
  v_cands := public._classes_on_day(p_unit, v_day);
  v_win := public._classes_in_window(p_unit, v_day, v_time);

  for st in
    select x.sid, x.o, s.id as id, s.user_id, s.parent_user_id, s.standing::text as standing, s.prog::text as prog
      from unnest(coalesce(p_student_ids, array[]::uuid[])) with ordinality x(sid, o)
      left join public.students s on s.id = x.sid
     order by x.o
  loop
    student_id := st.sid; result := null; class_id := null; class_date := null; class_time := null;
    class_label := null; class_audience := null; class_legacy_id := null; attendance_id := null;
    status := null; arrived_at := null; opens_at := null; options := '[]'::jsonb;

    if st.id is null or v_uid is null
       or not coalesce(st.user_id = v_uid or st.parent_user_id = v_uid or public.is_guardian_of(st.id, 'manage'), false) then   -- null is never a yes
      result := 'not_allowed'; return next; continue;
    end if;
    if st.standing = 'on_hold' then
      result := 'on_hold'; return next; continue;
    end if;

    v_aud := case when st.prog = 'kids' then 'kids' else 'adults' end;
    select coalesce(jsonb_agg(w || jsonb_build_object('label', public._tv_class_label(w ->> 'uni', w ->> 'lvl', w ->> 'typ'),
                                                      'time', to_char((w ->> 't')::time, 'HH24:MI'))
                              order by abs(extract(epoch from (w ->> 't')::time) / 60 - v_nowm), (w ->> 't')::time,
                                       w ->> 'aud', w ->> 'class_id'), '[]'::jsonb)
      into v_fit
      from jsonb_array_elements(v_win) w
     where lower(w ->> 'aud') in ('all', v_aud);
    options := v_fit;

    if jsonb_array_length(v_fit) = 0 then
      select to_char((x ->> 't')::time, 'HH24:MI'), to_char((x ->> 't')::time - interval '30 minutes', 'HH24:MI')
        into class_time, opens_at
        from jsonb_array_elements(v_cands) x
       where lower(x ->> 'aud') in ('all', v_aud)
         and extract(epoch from (x ->> 't')::time) / 60 - 30 > v_nowm
       order by (x ->> 't')::time
       limit 1;
      result := 'no_class'; return next; continue;
    end if;

    v_pick := null;
    if p_class is not null then
      select f into v_pick from jsonb_array_elements(v_fit) f
       where (nullif(p_class ->> 'class_id', '') is not null and f ->> 'class_id' = p_class ->> 'class_id')
          or (nullif(p_class ->> 'class_id', '') is null and f ->> 'class_id' is null
              and f ->> 'time' = left(coalesce(p_class ->> 'time', ''), 5))
       limit 1;
      if v_pick is null then
        result := 'invalid_class'; return next; continue;
      end if;
    else
      select f into v_pick
        from jsonb_array_elements(v_fit) with ordinality f(f, n)
       where exists (select 1 from public.attendance x
                      where x.student_id = st.id and x.class_date = v_day
                        and ((f ->> 'class_id' is not null and x.class_id = (f ->> 'class_id')::uuid)
                             or (f ->> 'class_id' is null and x.class_id is null and x.unit_id = p_unit
                                 and left(x.class_time::text, 5) = f ->> 'time')))
       order by n
       limit 1;
      if v_pick is null then v_pick := v_fit -> 0; end if;
    end if;

    v_cid := (v_pick ->> 'class_id')::uuid;
    v_t := v_pick ->> 'time';
    class_id := v_cid;
    class_date := v_day;
    class_time := v_t;
    class_label := v_pick ->> 'label';
    class_audience := v_pick ->> 'aud';
    class_legacy_id := v_pick ->> 'legacy';

    select x.id, x.status::text as status, x.arrived_at into a
      from public.attendance x
     where x.student_id = st.id and x.class_date = v_day
       and ((v_cid is not null and x.class_id = v_cid)
            or (v_cid is null and x.class_id is null and x.unit_id = p_unit
                and left(x.class_time::text, 5) = v_t))
     order by (x.status = 'present') desc, x.id
     limit 1;
    v_id := a.id;

    if not p_write then
      attendance_id := v_id; status := a.status; arrived_at := a.arrived_at;
      result := case when a.arrived_at is not null then 'already' else 'ready' end;
      return next; continue;
    end if;

    if v_id is null then
      -- doCI's row: modality from the uniform (Gi / No-Gi; Mixed none), else from the type
      v_mod := case when nullif(v_pick ->> 'uni', '') is not null
                    then case v_pick ->> 'uni' when 'Gi' then 'gi' when 'No-Gi' then 'nogi' end
                    when v_pick ->> 'typ' in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'gi'
                    when v_pick ->> 'typ' in ('nogi', 'jnogi', 'mma', 'jmma') then 'nogi' end;
      insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time,
                                     class_type, modality, gi, status)
      values (st.id, p_unit, v_cid, v_pick ->> 'legacy', v_day, v_t,
              v_pick ->> 'typ', v_mod, v_mod is not distinct from 'gi', 'going')
      on conflict do nothing
      returning id into v_id;
      if v_id is null then
        select x.id into v_id from public.attendance x
         where x.student_id = st.id and x.class_date = v_day
           and ((v_cid is not null and x.class_id = v_cid)
                or (v_cid is null and x.class_id is null and x.unit_id = p_unit
                    and left(x.class_time::text, 5) = v_t))
         order by x.id limit 1;
      end if;
    end if;

    update public.attendance x set arrived_at = p_at, arrived_via = p_via
     where x.id = v_id and x.arrived_at is null;
    v_done := found;
    select x.status::text, x.arrived_at into status, arrived_at from public.attendance x where x.id = v_id;
    attendance_id := v_id;
    result := case when v_done then 'arrived' else 'already' end;
    return next;
  end loop;
end;
$$;

revoke all on function public._checkin(uuid, uuid[], text, jsonb, timestamptz, boolean) from public, anon, authenticated;

create or replace function public.checkin_arrive(p_unit uuid, p_student_ids uuid[], p_via text, p_class jsonb default null)
returns table (student_id uuid, result text, class_id uuid, class_date date, class_time text, class_label text,
               class_audience text, class_legacy_id text, attendance_id uuid, status text, arrived_at timestamptz,
               opens_at text, options jsonb)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from public._checkin(p_unit, p_student_ids, p_via, p_class, now(), true);
end;
$$;

create or replace function public.checkin_preview(p_unit uuid, p_student_ids uuid[], p_class jsonb default null)
returns table (student_id uuid, result text, class_id uuid, class_date date, class_time text, class_label text,
               class_audience text, class_legacy_id text, attendance_id uuid, status text, arrived_at timestamptz,
               opens_at text, options jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from public._checkin(p_unit, p_student_ids, 'app', p_class, now(), false);
end;
$$;

revoke all on function public.checkin_arrive(uuid, uuid[], text, jsonb) from public, anon;
revoke all on function public.checkin_preview(uuid, uuid[], jsonb) from public, anon;
grant execute on function public.checkin_arrive(uuid, uuid[], text, jsonb) to authenticated;
grant execute on function public.checkin_preview(uuid, uuid[], jsonb) to authenticated;

commit;
