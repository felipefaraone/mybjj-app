-- 139_trial_emails_verify.sql
--
-- Checks for 139_trial_emails.sql. V1-V2 are read-only. V3 writes throwaway rows
-- inside a block it rolls back before showing results: NOTHING PERSISTS. Run
-- V3's statements together (two temp helpers, the block, the final select).

-- ---------------------------------------------------------------------------
-- V1. Schema. Expected: one row, every column t.
-- ---------------------------------------------------------------------------
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'trial_bookings'
           and column_name = 'no_show_by' and data_type = 'uuid')                                   as no_show_by_uuid,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'trial_bookings'
           and column_name = 'no_show_marked_at' and data_type = 'timestamp with time zone')       as no_show_marked_at_tstz,
  coalesce((select pg_get_constraintdef(oid) like '%''trial''%' from pg_constraint
             where conrelid = 'public.email_sends'::regclass and conname = 'email_sends_kind_check'), false)     as sends_kind_trial,
  coalesce((select pg_get_constraintdef(oid) like '%''trial''%' from pg_constraint
             where conrelid = 'public.email_optouts'::regclass and conname = 'email_optouts_kind_check'), false) as optouts_kind_trial,
  coalesce((select i.indisunique and pg_get_indexdef(i.indexrelid) like '%(period_key, recipient_email)%'
                   and pg_get_expr(i.indpred, i.indrelid) like '%''trial''%'
              from pg_index i where i.indexrelid = 'public.email_sends_trial_once'::regclass), false)         as trial_once_index;

-- ---------------------------------------------------------------------------
-- V2. The function: SECURITY DEFINER, closed to clients, open to service_role.
--     Expected: 1 row, definer t, anon f, authenticated f, service_role t.
-- ---------------------------------------------------------------------------
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute') as service_role
  from pg_proc p
 where p.oid = 'public.trial_email_candidates(timestamptz)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V3. Scenario proof (rolled back), July 2031 (Sydney = UTC+10). Needs one
--     public.users row (the staff who marks no-shows) and one class. Expected:
--     every pass = true.
--   Class: Thursday 10 Jul 2031 18:00 Sydney.
--   1-8  adult, attended path: 2 on Wed 9 Jul 18:00; 3A Fri 11 09:00; 4A Sat 12;
--        5A Tue 15; 6A Sat 19; one minute early = nothing; conversion stops it
--   9-11 kid, staff-marked no-show: 3B day +1, 4B +3, 5B +7, kids stream,
--        child = first word of kid_name
--   12   automatic no-show (no no_show_by): nothing on any B day
--   13   undo no-show (back to booked, marks cleared): nothing
--   14-16 rebooking: the old session's stream stops; the new session streams
--        under its own period key
--   17   booked less than 24h before the class: no email 2
--   18   late run: an email more than 2 days past due is skipped
--   19   opt-out: kind 'trial' and 'all' stop it; 'monthly_recap' does not
--   20   idempotency: sent / skipped never again; failed comes back as 'failed'
--   21   a second 'trial' row for the same period key + address is refused
--   22   a booking with no class: nothing, ever
--   23   output shape: period key, lowercased address, HH:MM, lowercased unit id
-- ---------------------------------------------------------------------------
create or replace function pg_temp.syd(t text) returns timestamptz
  language sql immutable as $$ select (t::timestamp at time zone 'Australia/Sydney') $$;
create or replace function pg_temp.codes(b uuid, t text) returns text
  language sql as $$
    select coalesce(string_agg(c.code, ',' order by c.code), '') from public.trial_email_candidates(pg_temp.syd(t)) c where c.booking_id = b
  $$;

create temp table if not exists _v139_results (n int, check_name text, pass boolean, detail text);
truncate _v139_results;
do $$
declare
  staff uuid; cls uuid; unit uuid;
  a uuid; k uuid; an uuid; un uuid; rb uuid; s_old uuid; s_new uuid; sh uuid; lt uuid; oo uuid; idm uuid; nc uuid;
  has_created boolean; v text; c int; r record; res jsonb := '[]'::jsonb;
begin
  select id into staff from public.users order by id limit 1;
  select id, unit_id into cls, unit from public.classes where unit_id is not null order by id limit 1;
  if staff is null or cls is null then raise exception 'V3 needs one public.users row and one class'; end if;
  has_created := exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'trial_sessions' and column_name = 'created_at');

  begin
    -- 1-8 adult, attended ----------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time)
      values (unit, 'Ada', 'Zz139', '  ZZ-139-Ada@Example.INVALID ', '0400000000', 'booked', pg_temp.syd('2031-07-01 10:00'),
              cls, '2031-07-10', '18:00') returning id into a;
    v := pg_temp.codes(a, '2031-07-09 17:59') || '|' || pg_temp.codes(a, '2031-07-09 18:00');
    res := res || jsonb_build_object('n',1,'c','email 2 at the class time minus one day, not a minute earlier','p', v = '|2', 'd', v);
    v := pg_temp.codes(a, '2031-07-10 18:00');
    res := res || jsonb_build_object('n',2,'c','email 2 gone once the class has started','p', v = '', 'd', v);

    update public.trial_bookings set trial_status = 'attended', attended_at = pg_temp.syd('2031-07-10 19:30') where id = a;
    v := pg_temp.codes(a, '2031-07-11 08:59') || '|' || pg_temp.codes(a, '2031-07-11 09:00');
    res := res || jsonb_build_object('n',3,'c','3A at 09:00 on day +1','p', v = '|3A', 'd', v);
    insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values ('trial', a::text || ':3A', 'zz-139-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-12 08:59') || '|' || pg_temp.codes(a, '2031-07-12 09:00');
    res := res || jsonb_build_object('n',4,'c','4A at 09:00 on day +2 (3A sent)','p', v = '|4A', 'd', v);
    insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values ('trial', a::text || ':4A', 'zz-139-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-15 08:59') || '|' || pg_temp.codes(a, '2031-07-15 09:00');
    res := res || jsonb_build_object('n',5,'c','5A at 09:00 on day +5','p', v = '|5A', 'd', v);
    insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values ('trial', a::text || ':5A', 'zz-139-ada@example.invalid', 'sent', now());
    v := pg_temp.codes(a, '2031-07-19 08:59') || '|' || pg_temp.codes(a, '2031-07-19 09:00');
    res := res || jsonb_build_object('n',6,'c','6A at 09:00 on day +9','p', v = '|6A', 'd', v);
    select string_agg(x.code, ',' order by x.code) into v
      from public.trial_email_candidates(pg_temp.syd('2031-07-19 09:00')) x where x.booking_id = a and x.stream = 'adult';
    res := res || jsonb_build_object('n',7,'c','adult stream','p', v = '6A', 'd', v);
    update public.trial_bookings set trial_status = 'converted', converted_at = pg_temp.syd('2031-07-18 12:00') where id = a;
    v := pg_temp.codes(a, '2031-07-19 09:00');
    update public.trial_bookings set trial_status = 'attended' where id = a;            -- converted_at alone also stops it
    v := v || '|' || pg_temp.codes(a, '2031-07-19 09:00');
    res := res || jsonb_build_object('n',8,'c','converted (status or converted_at): nothing','p', v = '|', 'd', v);

    -- 9-11 kid, staff-marked no-show -------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                       is_kid, kid_name, lapsed_at, no_show_by, no_show_marked_at)
      values (unit, 'Jo', 'Zz139', 'zz-139-jo@example.invalid', '0400000001', 'no_show', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              true, '  Mia Rose Zz139', pg_temp.syd('2031-07-10 20:00'), staff, pg_temp.syd('2031-07-10 20:00')) returning id into k;
    v := pg_temp.codes(k, '2031-07-11 09:00');
    insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values ('trial', k::text || ':3B', 'zz-139-jo@example.invalid', 'sent', now());
    v := v || '|' || pg_temp.codes(k, '2031-07-12 09:00') || '|' || pg_temp.codes(k, '2031-07-13 08:59') || '|' || pg_temp.codes(k, '2031-07-13 09:00');
    insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values ('trial', k::text || ':4B', 'zz-139-jo@example.invalid', 'sent', now());
    v := v || '|' || pg_temp.codes(k, '2031-07-17 08:59') || '|' || pg_temp.codes(k, '2031-07-17 09:00');
    res := res || jsonb_build_object('n',9,'c','kid no-show: 3B day +1, 4B day +3, 5B day +7','p', v = '3B|||4B||5B', 'd', v);
    select x.stream || '/' || x.first_name || '/' || coalesce(x.child_first_name, '(null)') into v
      from public.trial_email_candidates(pg_temp.syd('2031-07-17 09:00')) x where x.booking_id = k;
    res := res || jsonb_build_object('n',10,'c','kids stream, parent + child first names','p', v = 'kids/Jo/Mia', 'd', v);
    v := pg_temp.codes(k, '2031-07-11 09:00');
    res := res || jsonb_build_object('n',11,'c','no-show, day +1 after 3B was sent: nothing else (no A-branch email, no email 2)','p', v = '', 'd', v);

    -- 12 automatic no-show ----------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time, lapsed_at)
      values (unit, 'Al', 'Zz139', 'zz-139-auto@example.invalid', '0400000002', 'no_show', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-11 02:00')) returning id into an;
    v := pg_temp.codes(an, '2031-07-11 09:00') || '|' || pg_temp.codes(an, '2031-07-13 09:00') || '|' || pg_temp.codes(an, '2031-07-17 09:00');
    res := res || jsonb_build_object('n',12,'c','automatic no-show (no no_show_by): nothing','p', v = '||', 'd', v);

    -- 13 undo no-show -----------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                       lapsed_at, no_show_by, no_show_marked_at)
      values (unit, 'Un', 'Zz139', 'zz-139-undo@example.invalid', '0400000003', 'no_show', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-10 20:00'), staff, pg_temp.syd('2031-07-10 20:00')) returning id into un;
    v := pg_temp.codes(un, '2031-07-11 09:00');
    update public.trial_bookings set trial_status = 'booked', lapsed_at = null, no_show_by = null, no_show_marked_at = null where id = un;
    v := v || '|' || pg_temp.codes(un, '2031-07-11 09:00') || '|' || pg_temp.codes(un, '2031-07-13 09:00');
    update public.trial_bookings set trial_status = 'no_show' where id = un;              -- status back, marks still cleared
    v := v || '|' || pg_temp.codes(un, '2031-07-13 09:00');
    res := res || jsonb_build_object('n',13,'c','undo no-show stops the stream (3B before, nothing after)','p', v = '3B|||', 'd', v);

    -- 14-16 rebooking -------------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                       lapsed_at, no_show_by, no_show_marked_at)
      values (unit, 'Re', 'Zz139', 'zz-139-re@example.invalid', '0400000004', 'no_show', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-10 20:00'), staff, pg_temp.syd('2031-07-10 20:00')) returning id into rb;
    v := pg_temp.codes(rb, '2031-07-11 09:00');
    -- What trial-booking does on a rebook: back-fill the original as a session,
    -- add the new one, status back to booked (no_show_by left as it was).
    insert into public.trial_sessions (trial_booking_id, class_id, class_date, class_time, attended)
      values (rb, cls, '2031-07-10', '18:00', false) returning id into s_old;
    insert into public.trial_sessions (trial_booking_id, class_id, class_date, class_time, attended)
      values (rb, cls, '2031-07-20', '18:00', false) returning id into s_new;
    if has_created then
      execute 'update public.trial_sessions set created_at = $1 where id = $2' using pg_temp.syd('2031-07-12 10:00'), s_new;
      execute 'update public.trial_sessions set created_at = $1 where id = $2' using pg_temp.syd('2031-07-12 10:00'), s_old;
    end if;
    update public.trial_bookings set trial_status = 'booked', lapsed_at = null where id = rb;
    v := v || '|' || pg_temp.codes(rb, '2031-07-13 09:00') || '|' || pg_temp.codes(rb, '2031-07-17 09:00');
    res := res || jsonb_build_object('n',14,'c','rebooked: the old no-show stream stops (no 4B, no 5B)','p', v = '3B||', 'd', v);
    v := pg_temp.codes(rb, '2031-07-19 18:00');
    res := res || jsonb_build_object('n',15,'c','rebooked: email 2 for the new session iff trial_sessions.created_at exists ('
             || case when has_created then 'it does' else 'it does not' end || ')','p', v = case when has_created then '2' else '' end, 'd', v);
    update public.trial_bookings set trial_status = 'attended', attended_at = pg_temp.syd('2031-07-20 19:30') where id = rb;
    select string_agg(x.period_key, ',') into v from public.trial_email_candidates(pg_temp.syd('2031-07-21 09:00')) x where x.booking_id = rb;
    res := res || jsonb_build_object('n',16,'c','rebooked: the new session streams under its own key','p', v = s_new::text || ':3A', 'd', v);

    -- 17 booked less than 24h ahead ----------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time)
      values (unit, 'Sh', 'Zz139', 'zz-139-short@example.invalid', '0400000005', 'booked', pg_temp.syd('2031-07-09 20:00'), cls, '2031-07-10', '18:00')
      returning id into sh;
    v := pg_temp.codes(sh, '2031-07-09 20:01') || '|' || pg_temp.codes(sh, '2031-07-10 12:00');
    update public.trial_bookings set booked_at = pg_temp.syd('2031-07-09 17:59') where id = sh;   -- 24h01m ahead: gets it
    v := v || '|' || pg_temp.codes(sh, '2031-07-09 20:01');
    res := res || jsonb_build_object('n',17,'c','booked under 24h ahead: no email 2 (24h01m: yes)','p', v = '||2', 'd', v);

    -- 18 late run ------------------------------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time, attended_at)
      values (unit, 'La', 'Zz139', 'zz-139-late@example.invalid', '0400000006', 'attended', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-10 19:30')) returning id into lt;
    v := pg_temp.codes(lt, '2031-07-13 09:00') || '|' || pg_temp.codes(lt, '2031-07-13 09:01');
    res := res || jsonb_build_object('n',18,'c','late run: 3A until exactly 2 days late, then skipped (4A still due)','p', v = '3A,4A|4A', 'd', v);

    -- 19 opt-out ------------------------------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time, attended_at)
      values (unit, 'Oo', 'Zz139', 'zz-139-opt@example.invalid', '0400000007', 'attended', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-10 19:30')) returning id into oo;
    insert into public.email_optouts (email, kind) values ('ZZ-139-OPT@example.invalid', 'monthly_recap');
    v := pg_temp.codes(oo, '2031-07-11 09:00');
    insert into public.email_optouts (email, kind) values ('zz-139-opt@example.invalid', 'trial');
    v := v || '|' || pg_temp.codes(oo, '2031-07-11 09:00');
    delete from public.email_optouts where email = 'zz-139-opt@example.invalid' and kind = 'trial';
    insert into public.email_optouts (email, kind) values ('zz-139-opt@example.invalid', 'all');
    v := v || '|' || pg_temp.codes(oo, '2031-07-11 09:00');
    res := res || jsonb_build_object('n',19,'c','opt-out: monthly_recap keeps; trial and all stop','p', v = '3A||', 'd', v);

    -- 20-21 idempotency ------------------------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time, attended_at)
      values (unit, 'Id', 'Zz139', 'zz-139-idem@example.invalid', '0400000008', 'attended', pg_temp.syd('2031-07-01 10:00'), cls, '2031-07-10', '18:00',
              pg_temp.syd('2031-07-10 19:30')) returning id into idm;
    insert into public.email_sends (kind, period_key, recipient_email, status, error) values ('trial', idm::text || ':3A', 'zz-139-idem@example.invalid', 'failed', 'x');
    select coalesce(string_agg(x.code || '/' || coalesce(x.attempt_status, '-'), ','), '') into v
      from public.trial_email_candidates(pg_temp.syd('2031-07-11 09:00')) x where x.booking_id = idm;
    update public.email_sends set status = 'sent', sent_at = now() where kind = 'trial' and period_key = idm::text || ':3A';
    v := v || '|' || pg_temp.codes(idm, '2031-07-11 09:00');
    update public.email_sends set status = 'skipped' where kind = 'trial' and period_key = idm::text || ':3A';
    v := v || '|' || pg_temp.codes(idm, '2031-07-11 09:00');
    res := res || jsonb_build_object('n',20,'c','failed -> retried (marked failed); sent / skipped -> never again','p', v = '3A/failed||', 'd', v);
    begin
      insert into public.email_sends (kind, period_key, recipient_email, status) values ('trial', idm::text || ':3A', 'ZZ-139-IDEM@example.invalid', 'sent');
      v := 'second row accepted';
    exception when unique_violation then v := 'refused';
    end;
    res := res || jsonb_build_object('n',21,'c','a second trial row for the same key + address is refused','p', v = 'refused', 'd', v);

    -- 22 no class -------------------------------------------------------------------------------------
    insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, preferred_day)
      values (unit, 'Nc', 'Zz139', 'zz-139-noclass@example.invalid', '0400000009', 'booked', pg_temp.syd('2031-07-01 10:00'), 'Any weekday')
      returning id into nc;
    select count(*) into c from generate_series(pg_temp.syd('2031-07-01 00:00'), pg_temp.syd('2031-07-31 00:00'), interval '1 hour') g(t),
           lateral public.trial_email_candidates(g.t) x where x.booking_id = nc;
    res := res || jsonb_build_object('n',22,'c','booking with no class: nothing in any hour of July','p', c = 0, 'd', c);

    -- 23 output shape ---------------------------------------------------------------------------------
    select x.* into r from public.trial_email_candidates(pg_temp.syd('2031-07-11 09:00')) x where x.booking_id = lt;
    v := concat_ws(' ', r.period_key = lt::text || ':3A', r.session_key = lt::text, r.session_id is null, r.recipient = 'zz-139-late@example.invalid',
                   r.class_time = '18:00', r.unit_legacy_id is not distinct from lower(r.unit_legacy_id), r.due_at = pg_temp.syd('2031-07-11 09:00'),
                   r.unit_name is not null);
    res := res || jsonb_build_object('n',23,'c','output: period key, address, HH:MM, unit id, due time','p', v = 't t t t t t t t' or v = 'true true true true true true true true', 'd', v);

    raise exception 'v139-rollback';
  exception when others then
    if sqlerrm <> 'v139-rollback' then raise; end if;
  end;
  insert into _v139_results
  -- an empty result compares as NULL: count it as a failure, never a blank
  select (j->>'n')::int, j->>'c', coalesce((j->>'p')::boolean, false), coalesce(j->>'d', '(none)') from jsonb_array_elements(res) j;
end $$;
select * from _v139_results order by n;
