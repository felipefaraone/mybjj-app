-- 140_mia_emails_verify.sql
--
-- Checks for 140_mia_emails.sql. V1-V2 are read-only. V3 writes throwaway rows
-- inside a block it rolls back before showing results: NOTHING PERSISTS. Run
-- V3's statements together (three temp helpers, the block, the final select).

-- ---------------------------------------------------------------------------
-- V1. The function: SECURITY DEFINER, closed to clients, open to service_role.
--     Expected: 1 row, definer t, anon f, authenticated f, service_role t.
-- ---------------------------------------------------------------------------
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute') as service_role
  from pg_proc p
 where p.oid = 'public.mia_email_candidates(timestamptz)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V2. What 140 relies on from 137: 'mia' allowed in both kind checks, and the
--     unique key that makes each MIA email once per key + address.
--     Expected: one row, every column t.
-- ---------------------------------------------------------------------------
select
  coalesce((select pg_get_constraintdef(oid) like '%''mia''%' from pg_constraint
             where conrelid = 'public.email_sends'::regclass and conname = 'email_sends_kind_check'), false)   as sends_kind_mia,
  coalesce((select pg_get_constraintdef(oid) like '%''mia''%' from pg_constraint
             where conrelid = 'public.email_optouts'::regclass and conname = 'email_optouts_kind_check'), false) as optouts_kind_mia,
  coalesce((select pg_get_constraintdef(oid) = 'UNIQUE (kind, period_key, student_id, recipient_email)' from pg_constraint
             where conrelid = 'public.email_sends'::regclass and conname = 'email_sends_once'), false)          as unique_key;

-- ---------------------------------------------------------------------------
-- V3. Scenario proof (rolled back), July 2031 (Sydney = UTC+10). Needs two
--     accounts in auth.users joined to public.users. Expected: every pass = t.
--   1-5   adult: M1 at 15:00 on day 7 (not 14:59), M2 day 14, M3 day 21,
--         M4 + T4 day 30; T4 to info@, real membership, days absent, last class
--   6-9   attends after M2: M3 stopped, R at 15:00 the next day, R once,
--         the new absence starts fresh keys
--   10    no R when the absence's M1 was never sent
--   11-12 kid: both guardians (active + pending), never the kid; T4 lists them
--   13-14 staff excluded (account; adult email); a kid carrying a staff email
--         is not
--   15-17 on hold, inactive, never trained: nothing
--   18    launch: 45 days absent -> nothing in any hour of the day
--   19    late: due until exactly 2 days late, then skipped
--   20    future-dated attendance ignored
--   21    opt-outs: monthly_recap keeps; mia stops M1 (T4 still goes); all stops
--   22    idempotency: failed -> retried; sent / skipped -> never again;
--         a second row for the same key + address is refused
--   23    T4 says what the member actually got: sent_codes, reachable
--   24    T4 for a member who opted out: no codes, 'opted_out'
--   25    T4 for a member with no address at all: 'no_address'
--   26    visitors and casual tiers (visitor_* / casual_*) excluded, even from T4;
--         a real plan is not
-- ---------------------------------------------------------------------------
create or replace function pg_temp.syd(t text) returns timestamptz
  language sql immutable as $$ select (t::timestamp at time zone 'Australia/Sydney') $$;
create or replace function pg_temp.codes(sid uuid, t text) returns text
  language sql as $$
    select coalesce(string_agg(distinct c.code, ','), '') from public.mia_email_candidates(pg_temp.syd(t)) c where c.student_id = sid
  $$;
create or replace function pg_temp.rcpt(sid uuid, t text, cd text) returns text
  language sql as $$
    select coalesce(string_agg(c.recipient, ',' order by c.recipient), '') from public.mia_email_candidates(pg_temp.syd(t)) c
     where c.student_id = sid and c.code = cd
  $$;

create temp table if not exists _v140_results (n int, check_name text, pass boolean, detail text);
truncate _v140_results;
do $$
declare
  u1 uuid; u2 uuid; u2mail text;
  na uuid; vis uuid[] := '{}'; pl uuid; lvl text;
  a uuid; b uuid; c uuid; k uuid; sf uuid; se uuid; sk uuid; oh uuid; ina uuid; nt uuid; lg uuid; lt uuid; fu uuid; o uuid; idm uuid;
  v text; n int; r record; res jsonb := '[]'::jsonb;
begin
  select u.id into u1 from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null order by u.id limit 1;
  select u.id, lower(btrim(au.email::text)) into u2, u2mail from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null and u.id <> u1 order by u.id limit 1;
  if u2 is null then raise exception 'V3 needs two accounts'; end if;

  begin
    -- 1-5 adult ----------------------------------------------------------------
    insert into public.students (full_name, first_name, last_name, prog, email, active, standing, membership_level)
      values ('zz v140 Ada Adult', 'Ada', 'Adult', 'adult', ' ZZ-140-Ada@Example.INVALID ', true, 'ok', 'plan_unlimited') returning id into a;
    insert into public.attendance (student_id, status, class_date, class_type) values
      (a, 'present', '2031-06-20', 'beg'), (a, 'present', '2031-07-01', 'beg'), (a, 'going', '2031-07-05', 'beg');
    v := pg_temp.codes(a, '2031-07-08 14:59') || '|' || pg_temp.codes(a, '2031-07-08 15:00') || '|' || pg_temp.rcpt(a, '2031-07-08 15:00', 'M1');
    res := res || jsonb_build_object('n',1,'c','M1 at 15:00 Sydney on day 7, not at 14:59; to the member''s address','p', v = '|M1|zz-140-ada@example.invalid', 'd', v);
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
      values ('mia', a::text || ':2031-07-01:M1', a, 'zz-140-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-15 14:59') || '|' || pg_temp.codes(a, '2031-07-15 15:00');
    res := res || jsonb_build_object('n',2,'c','M2 on day 14','p', v = '|M2', 'd', v);
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
      values ('mia', a::text || ':2031-07-01:M2', a, 'zz-140-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-22 15:00');
    res := res || jsonb_build_object('n',3,'c','M3 on day 21','p', v = 'M3', 'd', v);
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
      values ('mia', a::text || ':2031-07-01:M3', a, 'zz-140-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-31 14:59') || '|' || pg_temp.codes(a, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',4,'c','M4 and T4 together on day 30','p', v = '|M4,T4', 'd', v);
    select concat_ws(' ', x.recipient, x.membership_level, x.days_absent, x.last_class_date, x.first_name, x.last_name, x.period_key = a::text || ':2031-07-01:T4', x.parents is null)
      into v from public.mia_email_candidates(pg_temp.syd('2031-07-31 15:00')) x where x.student_id = a and x.code = 'T4';
    res := res || jsonb_build_object('n',5,'c','T4: info@, real membership, 30 days, last class, names, key','p',
             v = 'info@mybjj.com.au plan_unlimited 30 2031-07-01 Ada Adult t t', 'd', v);

    -- 6-9 return ----------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v140 Bo Back', 'adult', 'zz-140-bo@example.invalid', true, 'ok') returning id into b;
    insert into public.attendance (student_id, status, class_date, class_type) values (b, 'present', '2031-07-01', 'beg');
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at) values
      ('mia', b::text || ':2031-07-01:M1', b, 'zz-140-bo@example.invalid', 'sent', now()),
      ('mia', b::text || ':2031-07-01:M2', b, 'zz-140-bo@example.invalid', 'sent', now());
    insert into public.attendance (student_id, status, class_date, class_type) values (b, 'present', '2031-07-17', 'beg');
    v := pg_temp.codes(b, '2031-07-22 15:00');
    res := res || jsonb_build_object('n',6,'c','attended after M2: M3 never comes','p', v = '', 'd', v);
    v := pg_temp.codes(b, '2031-07-18 14:59') || '|' || pg_temp.codes(b, '2031-07-18 15:00');
    select v || '|' || coalesce(string_agg(x.period_key, ','), '') into v
      from public.mia_email_candidates(pg_temp.syd('2031-07-18 15:00')) x where x.student_id = b;
    res := res || jsonb_build_object('n',7,'c','R at 15:00 the day after returning, keyed by the absence','p',
             v = '|R|' || b::text || ':2031-07-01:R', 'd', v);
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
      values ('mia', b::text || ':2031-07-01:R', b, 'zz-140-bo@example.invalid', 'sent', now());
    v := pg_temp.codes(b, '2031-07-18 16:00') || '|' || pg_temp.codes(b, '2031-07-19 15:00');
    res := res || jsonb_build_object('n',8,'c','R once','p', v = '|', 'd', v);
    select coalesce(string_agg(x.period_key, ','), '') into v
      from public.mia_email_candidates(pg_temp.syd('2031-07-24 15:00')) x where x.student_id = b;
    res := res || jsonb_build_object('n',9,'c','second absence: fresh keys from the new last class','p', v = b::text || ':2031-07-17:M1', 'd', v);

    -- 10 no R without M1 ------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v140 Cy Quick', 'adult', 'zz-140-cy@example.invalid', true, 'ok') returning id into c;
    insert into public.attendance (student_id, status, class_date, class_type) values (c, 'present', '2031-07-01', 'beg'), (c, 'present', '2031-07-10', 'beg');
    v := pg_temp.codes(c, '2031-07-11 15:00');
    res := res || jsonb_build_object('n',10,'c','returned but M1 was never sent: no R','p', v = '', 'd', v);

    -- 11-12 kid ----------------------------------------------------------------------
    -- The legacy parent columns are how most kids carry a parent today; 133's
    -- sync turns parent_email into a PENDING guardianship by itself.
    insert into public.students (full_name, first_name, prog, email, active, standing, parent_name, parent_email, parent_phone)
      values ('zz v140 Kit Kid', 'Kit', 'kids', 'zz-140-kit@example.invalid', true, 'ok',
              'Pat Pending', 'ZZ-140-Pending@Example.invalid', '0400 140 140') returning id into k;
    insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, approved_at)
      values (k, u2, 'active', 'staff', u2, now());
    if not exists (select 1 from public.guardianships g where g.student_id = k and g.status = 'pending'
                    and lower(g.invite_email::text) = 'zz-140-pending@example.invalid') then
      insert into public.guardianships (student_id, invite_email, guardian_name, status, origin, created_by)
        values (k, 'zz-140-pending@example.invalid', 'Pat Pending', 'pending', 'staff', u2);
    end if;
    insert into public.attendance (student_id, status, class_date, class_type) values (k, 'present', '2031-07-01', 'jun');
    v := pg_temp.rcpt(k, '2031-07-08 15:00', 'M1');
    res := res || jsonb_build_object('n',11,'c','kid: both guardians (active + pending), never the kid','p',
             v = (select string_agg(e, ',' order by e) from unnest(array[u2mail, 'zz-140-pending@example.invalid']) e), 'd', v);
    select x.recipient || ' ' || (select string_agg(coalesce(p->>'email','-') || '/' || coalesce(p->>'phone','-'), ',' order by p->>'email')
                                    from jsonb_array_elements(x.parents) p) || ' ' || x.is_kid
      into v from public.mia_email_candidates(pg_temp.syd('2031-07-31 15:00')) x where x.student_id = k and x.code = 'T4';
    res := res || jsonb_build_object('n',12,'c','kid T4 to info@ lists the guardians, legacy phone matched by email','p',
             v = 'info@mybjj.com.au ' || (select string_agg(e, ',' order by e) from unnest(array[u2mail || '/-', 'zz-140-pending@example.invalid/0400 140 140']) e) || ' true', 'd', v);

    -- 13-14 staff -----------------------------------------------------------------------
    insert into public.staff (user_id, full_name, active) values (u1, 'zz v140 Coach One', true);
    insert into public.students (full_name, prog, user_id, active, standing) values ('zz v140 Staff Account', 'adult', u1, true, 'ok') returning id into sf;
    insert into public.staff (full_name, email, active) values ('zz v140 Coach Two', 'zz-140-coach@example.invalid', true);
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Staff Email', 'adult', 'ZZ-140-Coach@example.invalid', true, 'ok') returning id into se;
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Coach Kid', 'kids', 'zz-140-coach@example.invalid', true, 'ok') returning id into sk;
    insert into public.attendance (student_id, status, class_date, class_type) values (sf, 'present', '2031-07-01', 'beg'), (se, 'present', '2031-07-01', 'beg'), (sk, 'present', '2031-07-01', 'jun');
    v := pg_temp.codes(sf, '2031-07-08 15:00') || '|' || pg_temp.codes(sf, '2031-07-31 15:00') || '|' || pg_temp.codes(se, '2031-07-08 15:00') || '|' || pg_temp.codes(se, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',13,'c','staff excluded: staff account, and adult with a staff email','p', v = '|||', 'd', v);
    v := pg_temp.codes(sk, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',14,'c','a kid whose record carries a staff email is still a member (T4 due)','p', v = 'T4', 'd', v);

    -- 15-17 on hold, inactive, never trained ------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 On Hold', 'adult', 'zz-140-hold@example.invalid', true, 'on_hold') returning id into oh;
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Inactive', 'adult', 'zz-140-gone@example.invalid', false, 'ok') returning id into ina;
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Never', 'adult', 'zz-140-never@example.invalid', true, 'ok') returning id into nt;
    insert into public.attendance (student_id, status, class_date, class_type) values
      (oh, 'present', '2031-07-01', 'beg'), (ina, 'present', '2031-07-01', 'beg'), (nt, 'going', '2031-07-01', 'beg'), (nt, 'absent', '2031-07-01', 'beg');
    v := pg_temp.codes(oh, '2031-07-08 15:00') || '|' || pg_temp.codes(oh, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',15,'c','on hold: nothing (not even T4)','p', v = '|', 'd', v);
    v := pg_temp.codes(ina, '2031-07-08 15:00') || '|' || pg_temp.codes(ina, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',16,'c','inactive: nothing','p', v = '|', 'd', v);
    v := pg_temp.codes(nt, '2031-07-08 15:00') || '|' || pg_temp.codes(nt, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',17,'c','never trained (going / absent only): nothing','p', v = '|', 'd', v);

    -- 18 launch -------------------------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Long Gone', 'adult', 'zz-140-long@example.invalid', true, 'ok') returning id into lg;
    insert into public.attendance (student_id, status, class_date, class_type) values (lg, 'present', '2031-06-01', 'beg');
    select count(*) into n from generate_series(pg_temp.syd('2031-07-16 00:00'), pg_temp.syd('2031-07-16 23:00'), interval '1 hour') g(t),
           lateral public.mia_email_candidates(g.t) x where x.student_id = lg;
    res := res || jsonb_build_object('n',18,'c','launch with someone 45 days absent: nothing in any hour of the day','p', n = 0, 'd', n);

    -- 19 late -------------------------------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Late', 'adult', 'zz-140-late@example.invalid', true, 'ok') returning id into lt;
    insert into public.attendance (student_id, status, class_date, class_type) values (lt, 'present', '2031-07-01', 'beg');
    v := pg_temp.codes(lt, '2031-07-10 15:00') || '|' || pg_temp.codes(lt, '2031-07-10 15:01');
    res := res || jsonb_build_object('n',19,'c','late: due until exactly 2 days late, then skipped','p', v = 'M1|', 'd', v);

    -- 20 future attendance -----------------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Future', 'adult', 'zz-140-fut@example.invalid', true, 'ok') returning id into fu;
    insert into public.attendance (student_id, status, class_date, class_type) values (fu, 'present', '2031-07-01', 'beg'), (fu, 'present', '2031-08-30', 'beg');
    v := pg_temp.codes(fu, '2031-07-08 15:00');
    res := res || jsonb_build_object('n',20,'c','a present row dated in the future is ignored','p', v = 'M1', 'd', v);

    -- 21 opt-outs ---------------------------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Opt', 'adult', 'zz-140-opt@example.invalid', true, 'ok') returning id into o;
    insert into public.attendance (student_id, status, class_date, class_type) values (o, 'present', '2031-07-01', 'beg');
    insert into public.email_optouts (email, kind) values ('ZZ-140-OPT@example.invalid', 'monthly_recap');
    v := pg_temp.codes(o, '2031-07-08 15:00');
    insert into public.email_optouts (email, kind) values ('zz-140-opt@example.invalid', 'mia');
    v := v || '|' || pg_temp.codes(o, '2031-07-08 15:00') || '|' || pg_temp.codes(o, '2031-07-31 15:00');
    -- 24 (while the 'mia' opt-out is in place)
    declare w text; begin
      select coalesce(array_to_string(x.sent_codes, ','), '(null)') || '/' || coalesce(x.member_reach, '(null)') into w
        from public.mia_email_candidates(pg_temp.syd('2031-07-31 15:00')) x where x.student_id = o and x.code = 'T4';
      res := res || jsonb_build_object('n',24,'c','T4 for a member who opted out: nothing sent, opted_out','p', w = '/opted_out', 'd', w);
    end;
    delete from public.email_optouts where email = 'zz-140-opt@example.invalid' and kind = 'mia';
    insert into public.email_optouts (email, kind) values ('zz-140-opt@example.invalid', 'all');
    v := v || '|' || pg_temp.codes(o, '2031-07-08 15:00');
    res := res || jsonb_build_object('n',21,'c','opt-outs: monthly_recap keeps; mia stops M1 but T4 still goes; all stops','p', v = 'M1||T4|', 'd', v);

    -- 22 idempotency --------------------------------------------------------------------------------
    insert into public.students (full_name, prog, email, active, standing) values ('zz v140 Idem', 'adult', 'zz-140-idem@example.invalid', true, 'ok') returning id into idm;
    insert into public.attendance (student_id, status, class_date, class_type) values (idm, 'present', '2031-07-01', 'beg');
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, error)
      values ('mia', idm::text || ':2031-07-01:M1', idm, 'zz-140-idem@example.invalid', 'failed', 'x');
    select coalesce(string_agg(x.code || '/' || coalesce(x.attempt_status, '-'), ','), '') into v
      from public.mia_email_candidates(pg_temp.syd('2031-07-08 15:00')) x where x.student_id = idm;
    update public.email_sends set status = 'sent', sent_at = now() where kind = 'mia' and period_key = idm::text || ':2031-07-01:M1';
    v := v || '|' || pg_temp.codes(idm, '2031-07-08 15:00');
    update public.email_sends set status = 'skipped' where kind = 'mia' and period_key = idm::text || ':2031-07-01:M1';
    v := v || '|' || pg_temp.codes(idm, '2031-07-08 15:00');
    begin
      insert into public.email_sends (kind, period_key, student_id, recipient_email, status)
        values ('mia', idm::text || ':2031-07-01:M1', idm, 'ZZ-140-IDEM@example.invalid', 'sent');
      v := v || '|second row accepted';
    exception when unique_violation then v := v || '|refused';
    end;
    res := res || jsonb_build_object('n',22,'c','failed -> retried; sent / skipped -> never; duplicate refused','p', v = 'M1/failed|||refused', 'd', v);

    -- 23 T4 for the adult above (M1-M3 logged sent)
    select coalesce(array_to_string(x.sent_codes, ','), '(null)') || '/' || coalesce(x.member_reach, '(null)') into v
      from public.mia_email_candidates(pg_temp.syd('2031-07-31 15:00')) x where x.student_id = a and x.code = 'T4';
    res := res || jsonb_build_object('n',23,'c','T4 carries the member emails actually sent and reachable','p', v = 'M1,M2,M3/reachable', 'd', v);

    -- 25 no address at all
    insert into public.students (full_name, prog, email, user_id, active, standing) values ('zz v140 No Address', 'adult', null, null, true, 'ok') returning id into na;
    insert into public.attendance (student_id, status, class_date, class_type) values (na, 'present', '2031-07-01', 'beg');
    select coalesce(array_to_string(x.sent_codes, ','), '(null)') || '/' || coalesce(x.member_reach, '(null)') || '/' || pg_temp.codes(na, '2031-07-08 15:00')
      into v from public.mia_email_candidates(pg_temp.syd('2031-07-31 15:00')) x where x.student_id = na and x.code = 'T4';
    res := res || jsonb_build_object('n',25,'c','no address: no member email, T4 says no_address','p', v = '/no_address/', 'd', v);

    -- 26 visitors and casual tiers
    foreach lvl in array array['visitor_other_gym', 'visitor_unaffiliated', 'casual_dropin', 'casual_member'] loop
      insert into public.students (full_name, prog, email, active, standing, membership_level)
        values ('zz v140 ' || lvl, 'adult', 'zz-140-' || replace(lvl, '_', '-') || '@example.invalid', true, 'ok', lvl) returning id into pl;
      insert into public.attendance (student_id, status, class_date, class_type) values (pl, 'present', '2031-07-01', 'beg');
      vis := vis || pl;
    end loop;
    insert into public.students (full_name, prog, email, active, standing, membership_level)
      values ('zz v140 Plan One', 'adult', 'zz-140-plan@example.invalid', true, 'ok', 'plan_1_lesson') returning id into pl;
    insert into public.attendance (student_id, status, class_date, class_type) values (pl, 'present', '2031-07-01', 'beg');
    select count(*) into n from generate_series(pg_temp.syd('2031-07-08 15:00'), pg_temp.syd('2031-07-31 15:00'), interval '1 day') g(t),
           lateral public.mia_email_candidates(g.t) x where x.student_id = any(vis);
    v := n || '|' || pg_temp.codes(pl, '2031-07-08 15:00') || '|' || pg_temp.codes(pl, '2031-07-31 15:00');
    res := res || jsonb_build_object('n',26,'c','visitor_* / casual_* excluded on every due day (T4 too); plan_1_lesson still emailed','p', v = '0|M1|M4,T4', 'd', v);

    raise exception 'v140-rollback';
  exception when others then
    if sqlerrm <> 'v140-rollback' then raise; end if;
  end;
  insert into _v140_results
  -- an empty result compares as NULL: count it as a failure, never a blank
  select (j->>'n')::int, j->>'c', coalesce((j->>'p')::boolean, false), coalesce(j->>'d', '(none)') from jsonb_array_elements(res) j;
end $$;
select * from _v140_results order by n;
