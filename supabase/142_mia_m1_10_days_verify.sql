-- 142_mia_m1_10_days_verify.sql
--
-- Checks for 142_mia_m1_10_days.sql. V1 and V2 are read-only. V3 is one DO block
-- that ENDS WITH RAISE EXCEPTION carrying its results: the "ERROR:  V142 ..."
-- message IS the report, and it guarantees nothing in the block persists.

-- ---------------------------------------------------------------------------
-- V1. The live function has M1 at 10 and no longer at 7.
--     Expected: one row, has_m1_10 t, has_m1_7 f.
-- ---------------------------------------------------------------------------
select p.proname,
       position('(''M1'', 10)' in p.prosrc) > 0 as has_m1_10,
       position('(''M1'', 7)'  in p.prosrc) > 0 as has_m1_7
  from pg_proc p
 where p.oid = 'public.mia_email_candidates(timestamptz)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V2. It runs: what is due right now, by code (zero rows is a valid answer).
-- ---------------------------------------------------------------------------
select c.code, count(*) as due_now
  from public.mia_email_candidates(now()) c
 group by c.code
 order by c.code;

-- ---------------------------------------------------------------------------
-- V3. M1 at day 10, not day 8 (rolled back).
--   A. Real data: members whose last 'present' class was exactly 8 days ago
--      (Sydney) and who have no M1 sent for that class. For up to 5 of them:
--      at 15:30 Sydney TODAY (day 8) there must be NO M1 row, and at 15:30 on
--      day 10 there must be one. A member with no M1 at day 10 either is not
--      eligible (staff, on hold, visitor / casual, inactive) or has no address
--      to email: reported as INCONCLUSIVE, not as a pass. If there is no such
--      member at all, the result says so explicitly.
--   B. Synthetic (always runs): a throwaway adult whose last class is
--      1 Jul 2031 — no M1 on day 7 or day 8 at 15:30, M1 on day 10 at 15:30,
--      M2 still on day 14.
--   Expected in the final ERROR line: no "FAIL"; B all "pass".
-- ---------------------------------------------------------------------------
do $$
declare
  today date := (now() at time zone 'Australia/Sydney')::date;
  r record; n int := 0; found_any boolean := false;
  d8 boolean; d10 boolean; out text := ''; st uuid; v text;
  syd8 timestamptz; syd10 timestamptz;
begin
  -- A. real members, last class exactly 8 days ago, no M1 sent for it
  for r in
    select a.student_id, max(a.class_date) as last_date
      from public.attendance a
     where a.status = 'present' and a.class_date is not null and a.class_date <= today
     group by a.student_id
    having max(a.class_date) = today - 8
       and not exists (select 1 from public.email_sends es
                        where es.kind = 'mia' and es.status = 'sent'
                          and es.period_key = a.student_id::text || ':' || max(a.class_date)::text || ':M1')
     order by a.student_id
     limit 5
  loop
    found_any := true;
    syd8  := ((r.last_date + 8)  + time '15:30') at time zone 'Australia/Sydney';
    syd10 := ((r.last_date + 10) + time '15:30') at time zone 'Australia/Sydney';
    d8  := exists (select 1 from public.mia_email_candidates(syd8)  c where c.student_id = r.student_id and c.code = 'M1');
    d10 := exists (select 1 from public.mia_email_candidates(syd10) c where c.student_id = r.student_id and c.code = 'M1');
    n := n + 1;
    out := out || format(E'\n  A%s student %s (last class %s): day 8 M1=%s, day 10 M1=%s -> %s',
      n, r.student_id, r.last_date, d8, d10,
      case when d8 then 'FAIL (M1 offered on day 8)'
           when d10 then 'pass'
           else 'INCONCLUSIVE (not offered on day 10: not eligible or no address)' end);
  end loop;
  if not found_any then
    out := out || format(E'\n  A: NO member whose last present class was exactly 8 days ago (%s) without an M1 sent — the real-data check could not run today; see B.', today - 8);
  end if;

  -- B. synthetic member (rolled back with everything else)
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v142 Synthetic', 'Zz', 'Synthetic', 'adult', 'zz-v142@example.invalid', true, 'ok')
    returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  select string_agg(coalesce((select string_agg(c.code, ',' order by c.code)
                                from public.mia_email_candidates((x.d::timestamp + time '15:30') at time zone 'Australia/Sydney') c
                               where c.student_id = st), '-'), ' | ' order by x.d)
    into v
    from (values (date '2031-07-08'), (date '2031-07-09'), (date '2031-07-11'), (date '2031-07-15')) x(d);
  out := out || format(E'\n  B synthetic (last class 2031-07-01) day 7 | day 8 | day 10 | day 14 = %s -> %s',
    v, case when v = '- | - | M1 | M2' then 'pass' else 'FAIL (expected - | - | M1 | M2)' end);

  raise exception 'V142 results (rolled back):%', out;
end $$;
