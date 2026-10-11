-- 143_mia_settle_and_gate_verify.sql
--
-- Checks for 143_mia_settle_and_gate.sql. V1 and V2 are read-only. V3 is one DO
-- block that ENDS WITH RAISE EXCEPTION carrying every result: the
-- "ERROR:  V143 ..." message IS the report, and it guarantees nothing persists.

-- ---------------------------------------------------------------------------
-- V1. Read-only: the function reads the tables, the VALUES list is gone, the
--     settings row and the five codes exist.
--     Expected: one row, every boolean t.
-- ---------------------------------------------------------------------------
select
  position('public.mia_codes'    in p.prosrc) > 0                      as reads_mia_codes,
  position('public.mia_settings' in p.prosrc) > 0                      as reads_mia_settings,
  position('public.mia_unit_holds' in p.prosrc) > 0                    as uses_gate_helper,
  position('values (''M1''' in p.prosrc) = 0                           as values_list_gone,
  (select count(*) from public.mia_settings where id) = 1              as one_settings_row,
  (select string_agg(code || '=' || days || '/' || seq, ' ' order by seq, code) from public.mia_codes) as codes,
  (select row(settle_days, gate_lookback_days, gate_min_ratio, gate_baseline_weeks, max_late_days)::text
     from public.mia_settings where id)                                as settings
  from pg_proc p
 where p.oid = 'public.mia_email_candidates(timestamptz)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V2. Read-only DRY RUN.
--   a. what is due right now, by code (zero rows is a valid answer);
--   b. per unit, held right now and why: each lookback day, its present rows,
--      the weekday median over the baseline weeks, whether that day holds.
--      This is the SAME function the candidates use (mia_unit_holds).
-- ---------------------------------------------------------------------------
select c.code, count(*) as due_now
  from public.mia_email_candidates(now()) c
 group by c.code
 order by c.code;

select h.unit_name, h.unit_held, h.day, h.present_rows, h.baseline, h.day_holds
  from public.mia_unit_holds(now()) h
 order by h.unit_name, h.day desc;

-- ---------------------------------------------------------------------------
-- V3. Synthetic scenarios (rolled back). Settings and codes are set to the 143
--     defaults inside the block, so the expectations hold whatever was tuned.
--     D = 1 Jul 2031 (Sydney = UTC+10). Times are 15:30 Sydney.
--   S1  last class D: no M1 at D+10, D+11; M1 at D+12.
--   S2  late card: a present row for D+9 entered at D+11: no M1 at D+12.
--   S3  hold then release: unit held on D+12 -> no M1; cards catch up, released
--       on D+14 (M2 not due until D+16) -> M1 returned at D+14.
--   S4  superseded: M1 never sent, at D+16 (M2 due) -> M2 only, not M1.
--   S5  R: return class D+20 entered at D+23 -> no R at D+21; R at D+23.
--   S6  gate: a unit whose yesterday count is under half its weekday median is
--       held; a weekday whose median is 0 does not hold.
--   Expected in the final ERROR line: every case "pass", no "FAIL".
-- ---------------------------------------------------------------------------
do $$
declare
  dd date := date '2031-07-01';
  u_free uuid; u_gate uuid; g2 uuid; g3 uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid;
  fill uuid[] := '{}'; f uuid; i int; k int; x date;
  out text := ''; v text;
  y date := date '2031-08-19';                  -- S6 "yesterday"
  t6 timestamptz := (date '2031-08-20' + time '15:30') at time zone 'Australia/Sydney';
begin
  -- the 143 defaults, whatever is live
  update public.mia_settings set settle_days = 2, gate_lookback_days = 3, gate_min_ratio = 0.5,
                                 gate_baseline_weeks = 6, max_late_days = 7 where id;
  update public.mia_codes set days = case code when 'M1' then 10 when 'M2' then 14 when 'M3' then 21 else 30 end,
                              seq  = case code when 'M1' then 1 when 'M2' then 2 when 'M3' then 3 else 4 end;

  insert into public.units (name, legacy_id) values ('zz v143 Free', 'zzv143free') returning id into u_free;
  insert into public.units (name, legacy_id) values ('zz v143 Gate', 'zzv143gate') returning id into u_gate;
  insert into public.units (name, legacy_id) values ('zz v143 G2', 'zzv143g2') returning id into g2;
  insert into public.units (name, legacy_id) values ('zz v143 G3', 'zzv143g3') returning id into g3;

  -- inactive filler students carry the baseline attendance (never emailed)
  for i in 1..10 loop
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v143 Filler ' || i, 'adult', null, false, 'ok') returning id into f;
    fill := fill || f;
  end loop;

  -- the members under test (adults with an address, so M rows have a recipient)
  insert into public.students (full_name, first_name, prog, email, active, standing, unit_id)
    values ('zz v143 S1', 'S1', 'adult', 'zz-v143-s1@example.invalid', true, 'ok', u_free) returning id into s1;
  insert into public.students (full_name, first_name, prog, email, active, standing, unit_id)
    values ('zz v143 S2', 'S2', 'adult', 'zz-v143-s2@example.invalid', true, 'ok', u_free) returning id into s2;
  insert into public.students (full_name, first_name, prog, email, active, standing, unit_id)
    values ('zz v143 S3', 'S3', 'adult', 'zz-v143-s3@example.invalid', true, 'ok', u_gate) returning id into s3;
  insert into public.students (full_name, first_name, prog, email, active, standing, unit_id)
    values ('zz v143 S4', 'S4', 'adult', 'zz-v143-s4@example.invalid', true, 'ok', u_free) returning id into s4;
  insert into public.students (full_name, first_name, prog, email, active, standing, unit_id)
    values ('zz v143 S5', 'S5', 'adult', 'zz-v143-s5@example.invalid', true, 'ok', u_free) returning id into s5;
  insert into public.attendance (student_id, status, class_date, class_type, unit_id, confirmed_at)
  select s, 'present', dd, 'beg', u, (dd + time '19:00') at time zone 'Australia/Sydney'
    from (values (s1, u_free), (s2, u_free), (s3, u_gate), (s4, u_free), (s5, u_free)) t(s, u);

  -- S1
  v := concat_ws(' | ',
    (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 10) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s1),
    (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 11) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s1),
    (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 12) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s1));
  out := out || format(E'\n  S1 settle: D+10 | D+11 | D+12 = %s -> %s', v, case when v = '- | - | M1' then 'pass' else 'FAIL (expected - | - | M1)' end);

  -- S2: the card for D+9 lands at D+11, inside the settle window
  insert into public.attendance (student_id, status, class_date, class_type, unit_id, confirmed_at)
    values (s2, 'present', dd + 9, 'beg', u_free, ((dd + 11) + time '10:00') at time zone 'Australia/Sydney');
  v := (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 12) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s2);
  out := out || format(E'\n  S2 late card: D+12 = %s -> %s', v, case when v = '-' then 'pass' else 'FAIL (expected -: the episode moved to D+9)' end);

  -- S3: u_gate has 10 present rows a day from D-45 to D+8, none from D+9
  for x in select generate_series(dd - 45, dd + 8, interval '1 day')::date loop
    insert into public.attendance (student_id, status, class_date, class_type, unit_id)
      select unnest(fill), 'present', x, 'beg', u_gate;
  end loop;
  v := (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 12) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s3)
       || ' (gate ' || coalesce((select string_agg(h.day || ' ' || h.present_rows || '/' || h.baseline, ', ' order by h.day desc)
                                   from public.mia_unit_holds(((dd + 12) + time '15:30') at time zone 'Australia/Sydney') h where h.unit_id = u_gate), '?') || ')';
  out := out || format(E'\n  S3 held at D+12: %s -> %s', v, case when v like '- (gate%' then 'pass' else 'FAIL (expected no M1 while held)' end);
  for x in select generate_series(dd + 9, dd + 13, interval '1 day')::date loop
    insert into public.attendance (student_id, status, class_date, class_type, unit_id)
      select unnest(fill), 'present', x, 'beg', u_gate;
  end loop;
  v := (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 14) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s3)
       || ' (held ' || (select bool_or(h.unit_held)::text from public.mia_unit_holds(((dd + 14) + time '15:30') at time zone 'Australia/Sydney') h where h.unit_id = u_gate) || ')';
  out := out || format(E'\n  S3 released at D+14: %s -> %s', v, case when v = 'M1 (held false)' then 'pass' else 'FAIL (expected M1, gate released)' end);

  -- S4: nothing sent; at D+16 M2 is due, so M1 is superseded
  v := (select coalesce(string_agg(c.code, ',' order by c.code), '-') from public.mia_email_candidates(((dd + 16) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s4);
  out := out || format(E'\n  S4 superseded: D+16 = %s -> %s', v, case when v = 'M2' then 'pass' else 'FAIL (expected M2 only)' end);

  -- S5: M1 was sent for D; return class D+20 entered at D+23
  insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
    values ('mia', s5::text || ':' || dd::text || ':M1', s5, 'zz-v143-s5@example.invalid', 'sent', now());
  insert into public.attendance (student_id, status, class_date, class_type, unit_id, confirmed_at)
    values (s5, 'present', dd + 20, 'beg', u_free, ((dd + 23) + time '09:30') at time zone 'Australia/Sydney');
  v := concat_ws(' | ',
    (select coalesce(string_agg(c.code, ','), '-') from public.mia_email_candidates(((dd + 21) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s5),
    (select coalesce(string_agg(c.code || ' due ' || to_char(c.due_at at time zone 'Australia/Sydney', 'MM-DD HH24:MI'), ','), '-')
       from public.mia_email_candidates(((dd + 23) + time '15:30') at time zone 'Australia/Sydney') c where c.student_id = s5));
  out := out || format(E'\n  S5 R: D+21 | D+23 = %s -> %s', v,
    case when v = '- | R due ' || to_char(dd + 23, 'MM-DD') || ' 15:00' then 'pass' else 'FAIL (expected - | R due D+23 15:00)' end);

  -- S6: g2 has 10 rows on yesterday's weekday for 6 weeks and 3 yesterday;
  --     g3 has rows only on a weekday outside the lookback, none on yesterday's.
  for k in 1..6 loop
    insert into public.attendance (student_id, status, class_date, class_type, unit_id)
      select unnest(fill), 'present', y - 7 * k, 'beg', g2;
    insert into public.attendance (student_id, status, class_date, class_type, unit_id)
      select unnest(fill), 'present', y - 3 - 7 * k, 'beg', g3;
  end loop;
  insert into public.attendance (student_id, status, class_date, class_type, unit_id)
    select unnest(fill[1:3]), 'present', y, 'beg', g2;
  v := (select h.present_rows || '/' || h.baseline || ' day_holds=' || h.day_holds || ' unit_held=' || h.unit_held
          from public.mia_unit_holds(t6) h where h.unit_id = g2 and h.day = y);
  out := out || format(E'\n  S6 under half the median: G2 %s %s -> %s', y, v,
    case when v = '3/10 day_holds=true unit_held=true' then 'pass' else 'FAIL (expected 3/10, held)' end);
  v := (select h.present_rows || '/' || h.baseline || ' day_holds=' || h.day_holds || ' unit_held=' || h.unit_held
          from public.mia_unit_holds(t6) h where h.unit_id = g3 and h.day = y);
  out := out || format(E'\n  S6 weekday median 0: G3 %s %s -> %s', y, v,
    case when v = '0/0 day_holds=false unit_held=false' then 'pass' else 'FAIL (expected 0/0, not held)' end);

  raise exception 'V143 results (rolled back):%', out;
end $$;
