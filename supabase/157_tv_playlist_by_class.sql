-- ============================================================================
-- 157 — TV playlist by the class on now, and the battle per screen
-- ============================================================================
--
-- Felipe, 16 Oct. In _tv_payload's playlist (the one source; tv.html follows it):
--   * the class on now at the screen's unit = running, or starting within the
--     next 30 minutes (Sydney), from the same class rows the next class bar reads;
--   * a Kids class: only kids screens (race_kids, chase_kids when it qualifies,
--     rules) plus the kids battle where allowed; an Adults class: only adult
--     screens (race_adults, chase_adults, rules, feed_adults = adult items only,
--     gi_nogi) plus the adult battle where allowed; All, Kids and Adults at once,
--     or no class: everything, as before;
--   * the battle (NB vs CD) only on screens with tv_screens.show_battle (default
--     false), set here for the Neutral Bay screen(s). A per screen setting, never
--     a unit name check in the payload;
--   * the seconds still sum to 90, spread over the screens that remain.
-- New playlist names: battle_adults, battle_kids, feed_adults (tv.html renders
-- them; a tv.html from before this skips names it does not know).
--
-- _tv_payload is 156's text with only these changes (marked "157").
-- Rollback: 157_tv_playlist_by_class_rollback.sql. Checks: 157_..._verify.sql.
-- ============================================================================

begin;

do $$
begin
  if to_regprocedure('public._competition_minor(text)') is null then
    raise exception '157 preflight: apply 156 first';
  end if;
end $$;

alter table public.tv_screens add column if not exists show_battle boolean not null default false;
comment on column public.tv_screens.show_battle is
  'Show the unit battle (NB vs CD) on this screen (157). Default false.';

-- the Neutral Bay screen(s) show the battle
update public.tv_screens set show_battle = true
 where unit_id = 'c851cef5-d5b7-4d5b-b400-11f6ca760970' and show_battle is false;

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
  v_show_bat boolean := false; -- 157: tv_screens.show_battle
  v_cands    jsonb;            -- 157: today's classes (the next class bar's rows)
  v_focus    text;             -- 157: 'kids' / 'adult' / null (everything)
  v_bat_a    boolean;
  v_bat_k    boolean;
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
     and p_today between x.starts_on and greatest(x.ends_on, coalesce(x.finale_on, x.ends_on))
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
    v_phase  := case when p_today > c.ends_on then 'final' else 'live' end;
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

  -- One scoring run: this unit's rows and the battle of both units.
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
       from (select r.audience, u.name::text as nm,
                    jsonb_build_object('unit', u.name, 'here', r.unit_id = v_unit,
                      'active', (count(*) filter (where r.classes_count > 0))::integer,
                      'classes', coalesce(sum(r.classes_count) filter (where r.classes_count > 0), 0)::integer,
                      'avg', case when count(*) filter (where r.classes_count > 0) = 0 then 0::numeric
                                  else round(sum(r.classes_count) filter (where r.classes_count > 0)::numeric
                                             / (count(*) filter (where r.classes_count > 0)), 2) end) as o
               from r join public.units u on u.id = r.unit_id
              group by r.audience, r.unit_id, u.name) b)
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
                     'key', z.key, 'label', z.label, 'points', z.points, 'date', z.d)
                     order by z.d desc, z.ts desc nulls last, z.key)
                    from (select * from ev order by ev.d desc, ev.ts desc nulls last, ev.key limit 10) z
                    join vis v on v.sid = z.sid), '[]'::jsonb),
         (select count(*) from ev where ev.d >= p_today - 6)::integer,
         (select count(*) from ev join vis v on v.sid = ev.sid
           where ev.d >= p_today - 6 and v.e ->> 'audience' = 'adult')::integer
    into v_feed, v_feed7, v_feed7a;

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
    v_exc := '[]'::jsonb;
    if to_regclass('public.class_exceptions') is not null then
      execute 'select coalesce(jsonb_agg(to_jsonb(e)), ''[]''::jsonb) from public.class_exceptions e
                where e.unit_id = $1 and e.exception_date = $2'
         into v_exc using v_unit, p_today;
    end if;
    select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) into v_cands from (
      select k.id as class_id, k.time as t, coalesce(k.duration_minutes, 60) as dur,
             nullif(to_jsonb(k) ->> 'uniform', '') as uni, nullif(to_jsonb(k) ->> 'level', '') as lvl,
             k.type::text as typ, coalesce(nullif(k.audience, ''), 'Adults') as aud
        from public.classes k
       where k.unit_id = v_unit
         and k.day_of_week = extract(dow from p_today)::integer
         and k.active is not false
         and not exists (select 1 from jsonb_array_elements(v_exc) x where x ->> 'kind' = 'closed')
         and not exists (select 1 from jsonb_array_elements(v_exc) x
                          where x ->> 'kind' = 'cancelled' and x ->> 'class_id' = k.id::text)
      union all
      select null, (x ->> 'oneoff_time')::time, coalesce((x ->> 'oneoff_duration_minutes')::integer, 60),
             nullif(x ->> 'oneoff_uniform', ''), nullif(x ->> 'oneoff_level', ''), null,
             coalesce(nullif(x ->> 'oneoff_audience', ''), 'Adults')
        from jsonb_array_elements(v_exc) x
       where x ->> 'kind' = 'oneoff' and nullif(x ->> 'oneoff_time', '') is not null
    ) q;
    select q.* into v_cls
      from jsonb_to_recordset(v_cands) as q(class_id uuid, t time, dur integer, uni text, lvl text, typ text, aud text)
     where extract(epoch from q.t) / 60 + q.dur > extract(epoch from p_now) / 60
     order by q.t, q.aud
     limit 1;
    -- 157: the class on now (running, or starting within the next 30 minutes).
    -- Only Kids classes: the kids screens; only Adults: the adult screens; All,
    -- or Kids and Adults at once: everything.
    select case when count(distinct lower(q.aud)) = 1 and min(lower(q.aud)) = 'kids'   then 'kids'
                when count(distinct lower(q.aud)) = 1 and min(lower(q.aud)) = 'adults' then 'adult' end
      into v_focus
      from jsonb_to_recordset(v_cands) as q(t time, dur integer, aud text)
     where extract(epoch from q.t) / 60 - 30 <= extract(epoch from p_now) / 60
       and extract(epoch from q.t) / 60 + q.dur > extract(epoch from p_now) / 60;
    if v_cls.t is not null then
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
         and ((v_cls.class_id is not null and a.class_id = v_cls.class_id)
              or (v_cls.class_id is null and a.class_id is null and a.unit_id = v_unit
                  and left(a.class_time::text, 5) = to_char(v_cls.t, 'HH24:MI')));
      v_next := jsonb_build_object(
        'time', to_char(v_cls.t, 'HH24:MI'), 'duration', v_cls.dur,
        'label', public._tv_class_label(v_cls.uni, v_cls.lvl, v_cls.typ),
        'uniform', coalesce(v_cls.uni, case when v_cls.typ in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'Gi'
                                            else 'No-Gi' end),
        'audience', v_cls.aud,
        'going', v_going);
    end if;
  exception when others then
    raise warning '155 tv next_class skipped: % (%)', sqlerrm, sqlstate;
    v_next := null;
    v_focus := null;
  end;

  -- Playlist: 90 seconds, by importance. The races always; then last month's
  -- winners, the chases, how to score (live only), latest points (if any in the
  -- last 7 days), the battle (both units on the board, someone trained), gi /
  -- no-gi (if any).
  -- 157: a Kids class on now shows only the kids screens (race, chase, how to
  -- score, the kids battle); an Adults class only the adult screens (race,
  -- chase, how to score, adult latest points, the adult battle, gi / no-gi). The
  -- battle only on a screen with show_battle. The seconds always sum to 90.
  v_bat_a := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'adult', '[]'::jsonb)) >= 2
             and exists (select 1 from jsonb_array_elements(v_battle -> 'adult') x where (x ->> 'active')::integer > 0);
  v_bat_k := v_show_bat and jsonb_array_length(coalesce(v_battle -> 'kids', '[]'::jsonb)) >= 2
             and exists (select 1 from jsonb_array_elements(v_battle -> 'kids') x where (x ->> 'active')::integer > 0);
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
    if v_last is not null then v_screens := v_screens || 'last_results'::text; v_weights := v_weights || 1.2; end if;
    if v_chase -> 'adult' <> 'null'::jsonb then v_screens := v_screens || 'chase_adults'::text; v_weights := v_weights || 1.0; end if;
    if v_chase -> 'kids'  <> 'null'::jsonb then v_screens := v_screens || 'chase_kids'::text;   v_weights := v_weights || 1.0; end if;
    if v_phase = 'live' and jsonb_array_length(v_rules) > 0 then v_screens := v_screens || 'rules'::text; v_weights := v_weights || 1.0; end if;
    if v_feed7 > 0 then v_screens := v_screens || 'feed'::text; v_weights := v_weights || 1.0; end if;
    if v_bat_a or v_bat_k then v_screens := v_screens || 'battle'::text; v_weights := v_weights || 1.0; end if;
    if v_gi is not null then v_screens := v_screens || 'gi_nogi'::text; v_weights := v_weights || 1.0; end if;
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
    'playlist', v_play);
end;
$$;

commit;
