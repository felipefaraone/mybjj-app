-- 148_competitions_schema_verify.sql
--
-- Structure checks for 148, inside BEGIN ... ROLLBACK (nothing persists).
-- The LAST statement before ROLLBACK lists every check: expected all pass = true.
-- An empty list, or any pass = false, is a FAILURE.

begin;

create temp table _v148 (n numeric, test text, pass boolean, detail text) on commit drop;

do $$
declare
  v_txt text; v_ok boolean; n int; s uuid; a1 uuid; a2 uuid; v_err text; u uuid;
  ua uuid; u_mem uuid := gen_random_uuid(); u_stf uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid();
  c_draft uuid; c_act uuid; c_arch uuid; n2 int; n3 int; n4 int;
begin
  -- tables, RLS
  select string_agg(c.relname || '=' || c.relrowsecurity, ' ' order by c.relname) into v_txt
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relname in ('competition_rule_catalog','competitions','competition_divisions',
                                                 'competition_rules','competition_awards','competition_results');
  insert into _v148 values (1, 'six tables exist, RLS on every one',
    v_txt = 'competition_awards=true competition_divisions=true competition_results=true competition_rule_catalog=true competition_rules=true competitions=true', v_txt);

  -- catalog seed
  select string_agg(k.key || ':' || k.source, ' ' order by k.sort) into v_txt from public.competition_rule_catalog k;
  insert into _v148 values (2, 'catalog: the six keys and their sources',
    v_txt = 'class_attended:attendance social_post:award class_challenge:award best_attitude:award referral_trial:referral referral_conversion:referral', v_txt);
  insert into _v148 values (2.1, 'class_attended default params {"mode":"class_value","private_cap":1}',
    (select default_params from public.competition_rule_catalog where key = 'class_attended') = '{"mode":"class_value","private_cap":1}'::jsonb,
    (select default_params::text from public.competition_rule_catalog where key = 'class_attended'));

  -- policies: no client write path on awards / results
  select string_agg(p.tablename || '.' || p.cmd, ' ' order by p.tablename, p.cmd) into v_txt
    from pg_policies p where p.schemaname = 'public' and p.tablename in ('competition_awards', 'competition_results');
  insert into _v148 values (3, 'awards and results: SELECT policy only', v_txt = 'competition_awards.SELECT competition_results.SELECT', v_txt);
  select count(*) into n from pg_policies p
   where p.schemaname = 'public' and p.tablename in ('competition_rule_catalog','competitions','competition_divisions','competition_rules');
  insert into _v148 values (3.1, 'catalog / competitions / divisions / rules: select + insert + update + delete policies (16)', n = 16, n::text);
  v_ok := not has_table_privilege('anon', 'public.competitions', 'SELECT')
      and not has_table_privilege('anon', 'public.competition_awards', 'SELECT')
      and not has_table_privilege('authenticated', 'public.competition_awards', 'INSERT')
      and not has_table_privilege('authenticated', 'public.competition_results', 'INSERT')
      and not has_table_privilege('authenticated', 'public.competitions', 'TRUNCATE')
      and has_table_privilege('authenticated', 'public.competition_awards', 'SELECT');
  insert into _v148 values (3.2, 'anon: nothing; authenticated: no direct award/result writes, no TRUNCATE', v_ok, v_ok::text);

  -- competitions period rule
  begin
    insert into public.competitions (name, kind) values ('zz148 bad event', 'event');
    v_err := 'accepted';
  exception when check_violation then v_err := 'check_violation';
  end;
  begin
    insert into public.competitions (name, kind, starts_on, ends_on) values ('zz148 bad monthly', 'monthly', '2031-01-01', '2031-01-31');
    v_err := v_err || ' / accepted';
  exception when check_violation then v_err := v_err || ' / check_violation';
  end;
  begin
    insert into public.competitions (name, kind, starts_on, ends_on) values ('zz148 reversed', 'event', '2031-02-01', '2031-01-01');
    v_err := v_err || ' / accepted';
  exception when check_violation then v_err := v_err || ' / check_violation';
  end;
  insert into _v148 values (4, 'event needs both dates in order; monthly has none',
    v_err = 'check_violation / check_violation / check_violation', v_err);

  -- awards: only award keys; unique per day / per class occurrence; voided frees
  select st.id into s from public.students st order by st.id limit 1;
  if s is null then raise exception 'V148 needs one student'; end if;
  begin
    insert into public.competition_awards (student_id, award_key, award_date) values (s, 'class_attended', '2031-07-01');
    v_err := 'accepted';
  exception when check_violation then v_err := 'check_violation';
  end;
  insert into _v148 values (5, 'an attendance / referral key cannot be an award', v_err = 'check_violation', v_err);

  insert into public.competition_awards (student_id, award_key, award_date) values (s, 'social_post', '2031-07-01') returning id into a1;
  begin
    insert into public.competition_awards (student_id, award_key, award_date) values (s, 'social_post', '2031-07-01');
    v_err := 'accepted';
  exception when unique_violation then v_err := 'unique_violation';
  end;
  update public.competition_awards set voided_at = now() where id = a1;
  insert into public.competition_awards (student_id, award_key, award_date) values (s, 'social_post', '2031-07-01') returning id into a2;
  insert into _v148 values (6, 'social_post once per student per day; voiding frees the day', v_err = 'unique_violation' and a2 is not null, v_err);

  u := gen_random_uuid();
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values (s, 'class_challenge', '2031-07-02', u, '2031-07-02');
  begin
    insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values (s, 'class_challenge', '2031-07-02', u, '2031-07-02');
    v_err := 'accepted';
  exception when unique_violation then v_err := 'unique_violation';
  end;
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values (s, 'best_attitude', '2031-07-02', u, '2031-07-02');
  insert into _v148 values (7, 'class_challenge once per student per class occurrence; best_attitude separately allowed',
    v_err = 'unique_violation', v_err);
  -- a one-off class (no class_id): once per student, key and class_date
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values (s, 'class_challenge', '2031-07-03', null, '2031-07-03');
  begin
    insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values (s, 'class_challenge', '2031-07-03', null, '2031-07-03');
    v_err := 'accepted';
  exception when unique_violation then v_err := 'unique_violation';
  end;
  insert into _v148 values (7.1, 'class award with NULL class_id: first accepted, second same day refused', v_err = 'unique_violation', v_err);

  -- audit trigger attached
  insert into _v148 values (8, 'awards audited (audit_row trigger)',
    exists (select 1 from pg_trigger t where t.tgrelid = 'public.competition_awards'::regclass and t.tgname = 'trg_audit_competition_awards'),
    'trg_audit_competition_awards');

  -- new columns, appended
  select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' || coalesce(pg_get_expr(d.adbin, d.adrelid), ''), ' ' order by a.attnum)
    into v_txt
    from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.students'::regclass and a.attname in ('leaderboard_hidden', 'prize_eligible');
  insert into _v148 values (9, 'students.leaderboard_hidden false / prize_eligible true, NOT NULL',
    v_txt = 'leaderboard_hidden:boolean:true:false prize_eligible:boolean:true:true', v_txt);
  select string_agg(a.attname, ',' order by a.attnum) into v_txt
    from (select a2.attname, a2.attnum from pg_attribute a2
           where a2.attrelid = 'public.trial_bookings'::regclass and a2.attnum > 0 and not a2.attisdropped
           order by a2.attnum desc limit 4) a;
  insert into _v148 values (10, 'trial_bookings: the four referral columns are the last four',
    v_txt = 'referrer_name,referred_by_student_id,referred_by_set_by,referred_by_set_at', v_txt);
  select string_agg(v.view_schema || '.' || v.view_name, ', ') into v_txt
    from information_schema.view_table_usage v
   where v.table_schema = 'public' and v.table_name = 'trial_bookings';
  insert into _v148 values (10.1, 'no view reads trial_bookings', v_txt is null, coalesce(v_txt, 'none'));

  -- callers: an approved member, a staff member (instructor), an admin (unit owner)
  select x.id into ua from public.units x order by x.name, x.id limit 1;
  insert into auth.users (id, email) values (u_mem, 'zz148-member@example.invalid'), (u_stf, 'zz148-staff@example.invalid'),
                                            (u_adm, 'zz148-admin@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_mem, 'zz148-member@example.invalid', 'Zz148 Member', 'student',    'approved', ua),
    (u_stf, 'zz148-staff@example.invalid',  'Zz148 Staff',  'instructor', 'approved', ua),
    (u_adm, 'zz148-admin@example.invalid',  'Zz148 Admin',  'student',    'approved', ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_adm) on conflict do nothing;

  -- competitions in each status, each with a division and a rule, and one result row
  insert into public.competitions (name, kind, starts_on, ends_on, status) values ('zz148 draft', 'event', '2031-07-01', '2031-07-31', 'draft') returning id into c_draft;
  insert into public.competitions (name, kind, starts_on, ends_on, status) values ('zz148 active', 'event', '2031-07-01', '2031-07-31', 'active') returning id into c_act;
  insert into public.competitions (name, kind, starts_on, ends_on, status) values ('zz148 archived', 'event', '2031-07-01', '2031-07-31', 'archived') returning id into c_arch;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) select c, ua, 'adult', 'zz148' from unnest(array[c_draft, c_act, c_arch]) c;
  insert into public.competition_rules (competition_id, rule_key, points) select c, 'class_attended', 1 from unnest(array[c_draft, c_act, c_arch]) c;
  insert into public.competition_results (competition_id, period_from, period_to, student_id, points) values (c_act, '2031-07-01', '2031-07-31', s, 1);

  -- results policy: staff / admin only
  select pg_get_expr(pl.polqual, pl.polrelid) into v_txt from pg_policy pl
   where pl.polrelid = 'public.competition_results'::regclass and pl.polname = 'competition_results_select';
  insert into _v148 values (11, 'competition_results SELECT policy is is_staff() OR is_admin()',
    v_txt like '%is_staff()%' and v_txt like '%is_admin()%' and v_txt not like '%current_status%', v_txt);

  perform set_config('request.jwt.claims', json_build_object('sub', u_mem::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.competition_results;
  select string_agg(c.status, ',' order by c.status) into v_txt from public.competitions c where c.name like 'zz148 %' and c.id in (c_draft, c_act, c_arch);
  select count(*) into n2 from public.competition_divisions d where d.competition_id = c_draft;
  select count(*) into n3 from public.competition_rules r where r.competition_id = c_draft;
  select count(*) into n4 from public.competition_divisions d where d.competition_id in (c_act, c_arch);
  execute 'reset role';
  insert into _v148 values (11.1, 'an approved member (not staff) reads 0 rows from competition_results', n = 0, format('rows %s', n));
  insert into _v148 values (12, 'member sees active + archived competitions, not the draft; draft divisions / rules hidden',
    v_txt = 'active,archived' and n2 = 0 and n3 = 0 and n4 = 2, format('statuses %s, draft divisions %s, draft rules %s, other divisions %s', v_txt, n2, n3, n4));

  perform set_config('request.jwt.claims', json_build_object('sub', u_stf::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.competition_results where competition_id = c_act;
  select count(*) into n2 from public.competitions c where c.id = c_draft;
  execute 'reset role';
  insert into _v148 values (11.2, 'staff reads competition_results; staff (not admin) does not see the draft', n = 1 and n2 = 0,
    format('results %s, draft visible %s', n, n2));

  perform set_config('request.jwt.claims', json_build_object('sub', u_adm::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.competition_results where competition_id = c_act;
  select string_agg(c.status, ',' order by c.status) into v_txt from public.competitions c where c.id in (c_draft, c_act, c_arch);
  select count(*) into n2 from public.competition_divisions d where d.competition_id = c_draft;
  select count(*) into n3 from public.competition_rules r where r.competition_id = c_draft;
  execute 'reset role';
  insert into _v148 values (12.1, 'admin sees every status, the draft''s divisions and rules, and the results',
    v_txt = 'active,archived,draft' and n2 = 1 and n3 = 1 and n = 1, format('statuses %s, draft divisions %s, draft rules %s, results %s', v_txt, n2, n3, n));
end $$;

select n, test, pass, detail from _v148 order by n;

rollback;
