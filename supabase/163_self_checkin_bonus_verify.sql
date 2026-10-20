-- 163_self_checkin_bonus_verify.sql
--
-- Run AFTER 163, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/163_self_checkin_bonus_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Three events in March 2001 (really ended, no real attendance then) on the
-- first unit by name, all with class_attended 1:
--   Zz163 Cup    + self_checkin 1, enabled; social_post 2, referral_trial 3
--   Zz163 Plain  no self_checkin rule;     social_post 2, referral_trial 3
--   Zz163 Off    self_checkin 1, disabled
-- People (first unit): Ann, Bob, Cal, Dan, Eve adults with logins (Dan's rows
-- have no creator); Kit, Kev, Kai kids with no login: Kit's guardian has an
-- active guardianship, Kev's is the legacy parent_user_id, Kai's guardianship
-- is revoked. Sid is staff. Ann also has a post (award 2), a friend's trial
-- (referral 3) and a class the coach marked as not counting (class_value 0).
-- The bonus is read back as points - class_points - award_points - referral_points,
-- and the new checkin_points column must make the parts add up to points.

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- the user the next insert is made by (stays the table owner: no RLS in the way)
create function pg_temp.by(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', case when p is null then '' else json_build_object('sub', p::text, 'role', 'authenticated')::text end, true);
end $f$;
create function pg_temp.bonus(p_comp uuid, p_student uuid) returns numeric language sql as $f$
  select coalesce((select s.points - s.class_points - s.award_points - s.referral_points
                     from public._competition_scores(p_comp, null, null) s where s.student_id = p_student), 0)
$f$;

do $$
declare
  ua uuid; comp uuid; plain uuid; off uuid;
  u_adm uuid := gen_random_uuid(); u_sid uuid := gen_random_uuid();
  u_ann uuid := gen_random_uuid(); u_bob uuid := gen_random_uuid(); u_cal uuid := gen_random_uuid();
  u_dan uuid := gen_random_uuid(); u_eve uuid := gen_random_uuid();
  u_gkit uuid := gen_random_uuid(); u_gkev uuid := gen_random_uuid(); u_gkai uuid := gen_random_uuid();
  s_ann uuid; s_bob uuid; s_cal uuid; s_dan uuid; s_eve uuid; s_kit uuid; s_kev uuid; s_kai uuid;
  a_eve uuid; a_cal2 uuid; a_null uuid; cls uuid; scr uuid; p jsonb;
  v text; w text; n numeric; m numeric;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz163 Cup', 'event', '2001-03-01', '2001-03-31', '2001-04-01', 'active',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]') returning id into comp;
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz163 Plain', 'event', '2001-03-01', '2001-03-31', '2001-04-01', 'active', '[{"place":1,"label":"1st"}]') returning id into plain;
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz163 Off', 'event', '2001-03-01', '2001-03-31', '2001-04-01', 'active', '[{"place":1,"label":"1st"}]') returning id into off;
  insert into public.competition_divisions (competition_id, unit_id, audience, label)
  select c, ua, x.aud, 'Zz163 ' || x.aud from unnest(array[comp, plain, off]) c, (values ('adult'), ('kids')) x(aud);
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'self_checkin', 1, true),
    (comp, 'social_post', 2, true), (comp, 'referral_trial', 3, true),
    (plain, 'class_attended', 1, true), (plain, 'social_post', 2, true), (plain, 'referral_trial', 3, true),
    (off, 'class_attended', 1, true), (off, 'self_checkin', 1, false);

  insert into auth.users (id, email)
  select x, 'zz163-' || x::text || '@example.invalid' from unnest(array[u_adm, u_sid, u_ann, u_bob, u_cal, u_dan, u_eve, u_gkit, u_gkev, u_gkai]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz163-' || x.id::text || '@example.invalid', x.nm, x.role, 'approved', ua
    from (values (u_adm, 'Zz Admin', 'student'), (u_sid, 'Zz Sid', 'instructor'), (u_ann, 'Zz Ann', 'student'),
                 (u_bob, 'Zz Bob', 'student'), (u_cal, 'Zz Cal', 'student'), (u_dan, 'Zz Dan', 'student'),
                 (u_eve, 'Zz Eve', 'student'), (u_gkit, 'Zz Kit parent', 'parent'), (u_gkev, 'Zz Kev parent', 'parent'),
                 (u_gkai, 'Zz Kai parent', 'parent')) x(id, nm, role)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_adm) on conflict do nothing;

  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz163 Ann A','Ann','A','adult',ua,true,'ok',u_ann) returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz163 Bob B','Bob','B','adult',ua,true,'ok',u_bob) returning id into s_bob;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz163 Cal C','Cal','C','adult',ua,true,'ok',u_cal) returning id into s_cal;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz163 Dan D','Dan','D','adult',ua,true,'ok',u_dan) returning id into s_dan;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz163 Eve E','Eve','E','adult',ua,true,'ok',u_eve) returning id into s_eve;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz163 Kit K','Kit','K','kids',ua,true,'ok') returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, parent_user_id)
    values ('Zz163 Kev K','Kev','K','kids',ua,true,'ok',u_gkev) returning id into s_kev;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz163 Kai K','Kai','K','kids',ua,true,'ok') returning id into s_kai;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kit, u_gkit, 'active', 'legacy_sync', 'manage');
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kai, u_gkai, 'revoked', 'legacy_sync', 'manage');

  -- 1. the trigger: created_by is the inserting user, whatever the client sends
  perform pg_temp.by(u_eve);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id, created_by)
    values (s_eve, null, '2001-03-02', '18:00', 'alev', 'going', 1.00, 'gi', ua, u_sid) returning id into a_eve;
  perform pg_temp.by(null);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id, created_by)
    values (s_dan, null, '2001-03-02', '18:00', 'alev', 'present', 1.00, 'gi', ua, u_dan) returning id into a_null;
  select format('eve=%s null=%s',
                (select case created_by when u_eve then 'eve' when u_sid then 'staff' else coalesce(created_by::text, 'null') end from public.attendance where id = a_eve),
                (select coalesce(created_by::text, 'null') from public.attendance where id = a_null)) into v;
  if v <> 'eve=eve null=null' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: insert sets created_by to auth.uid() and ignores the value sent (%); no auth.uid() leaves it null', v;

  -- 1.1 updates never change it: staff marks Eve present and tries to set created_by;
  --     an upsert that hits the row (the app's upsert path) does too
  perform pg_temp.by(u_sid);
  update public.attendance set status = 'present', created_by = u_sid, confirmed_at = now() where id = a_eve;
  insert into public.attendance (id, student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id, created_by)
    values (a_eve, s_eve, null, '2001-03-02', '18:00', 'alev', 'present', 1.00, 'gi', ua, u_sid)
  on conflict (id) do update set status = excluded.status, created_by = excluded.created_by;
  select case created_by when u_eve then 'eve' else coalesce(created_by::text, 'null') end into v from public.attendance where id = a_eve;
  if v <> 'eve' then raise exception 'FAIL 1.1: created_by is now %', v; end if;
  raise notice 'PASS 1.1: an update and an upsert by staff keep created_by (Eve)';

  -- fixture rows
  -- Ann (herself): present, going, absent, a private lesson
  perform pg_temp.by(u_ann);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_ann, null, '2001-03-05', '18:00', 'alev',    'present', 1.00, 'gi',   ua),
    (s_ann, null, '2001-03-06', '18:00', 'alev',    'going',   1.00, 'gi',   ua),
    (s_ann, null, '2001-03-07', '18:00', 'alev',    'absent',  1.00, 'gi',   ua),
    (s_ann, null, '2001-03-08', '07:00', 'private', 'present', 1.00, 'gi',   ua),
    (s_ann, null, '2001-03-12', '18:00', 'alev',    'present', 0.00, 'gi',   ua);   -- the coach: doesn't count
  -- class_value is NOT NULL in production; where it is nullable, a null row earns nothing either
  if not (select attnotnull from pg_attribute where attrelid = 'public.attendance'::regclass and attname = 'class_value') then
    execute format('insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
                    values (%L, null, %L, %L, %L, %L, null, %L, %L)', s_ann, '2001-03-13', '18:00', 'alev', 'present', 'gi', ua);
  end if;
  -- Cal (himself): two classes on the same day
  perform pg_temp.by(u_cal);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_cal, null, '2001-03-09', '18:00', 'alev', 'present', 1.00, 'gi',   ua);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_cal, null, '2001-03-09', '19:00', 'omat', 'present', 1.00, 'nogi', ua) returning id into a_cal2;
  -- Bob: added by staff
  perform pg_temp.by(u_sid);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_bob, null, '2001-03-05', '18:00', 'alev', 'present', 1.00, 'gi', ua);
  -- Ann: a post and a friend's trial (both events score them)
  perform pg_temp.by(null);
  insert into public.competition_awards (student_id, award_key, award_date) values (s_ann, 'social_post', '2001-03-10');
  select c.id into cls from public.classes c where c.unit_id = ua order by c.id limit 1;
  if cls is null then raise exception 'FAIL setup: no class at the first unit'; end if;
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                     attended_at, referred_by_student_id)
    values (ua, 'Re', 'Zz163', 'zz163-ref@example.invalid', '0400000163', 'booked', now(), cls, '2001-03-14', '18:00',
            timestamp '2001-03-14 19:00' at time zone 'Australia/Sydney', s_ann);
  -- the kids, each checked in by the guardian on record
  perform pg_temp.by(u_gkit);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_kit, null, '2001-03-05', '16:00', 'jun', 'present', 1.00, 'gi', ua);
  perform pg_temp.by(u_gkev);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_kev, null, '2001-03-05', '16:00', 'jun', 'present', 1.00, 'gi', ua);
  perform pg_temp.by(u_gkai);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id) values
    (s_kai, null, '2001-03-05', '16:00', 'jun', 'present', 1.00, 'gi', ua);
  perform pg_temp.by(null);

  -- 2. _attendance_is_self: own login, active guardian, legacy parent; not staff, not revoked, not null
  select format('own=%s guardian=%s legacy=%s staff=%s revoked=%s null=%s',
                public._attendance_is_self(u_ann, s_ann), public._attendance_is_self(u_gkit, s_kit),
                public._attendance_is_self(u_gkev, s_kev), public._attendance_is_self(u_sid, s_ann),
                public._attendance_is_self(u_gkai, s_kai), coalesce(public._attendance_is_self(null, s_ann)::text, 'null')) into v;
  if v <> 'own=t guardian=t legacy=t staff=f revoked=f null=false' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: _attendance_is_self %', v;

  -- 3. the bonus: Ann's own present row (going, absent and the private lesson earn nothing),
  --    Eve's own row marked present by staff, the guardian and legacy parent rows
  select format('ann=%s eve=%s kit=%s kev=%s', pg_temp.bonus(comp, s_ann), pg_temp.bonus(comp, s_eve),
                pg_temp.bonus(comp, s_kit), pg_temp.bonus(comp, s_kev)) into v;
  if v <> 'ann=1.00 eve=1.00 kit=1.00 kev=1.00' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: bonus for a self check in marked present (own login, guardian, legacy parent): %', v;

  -- 4. no bonus: staff-created (Bob), no creator (Dan), revoked guardian (Kai)
  select format('bob=%s dan=%s kai=%s', pg_temp.bonus(comp, s_bob), pg_temp.bonus(comp, s_dan), pg_temp.bonus(comp, s_kai)) into v;
  if v <> 'bob=0.00 dan=0.00 kai=0.00' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: no bonus for a staff row, a row with no creator, a revoked guardian: %', v;

  -- 4.1 going, absent and a private lesson: Ann's going / absent / private rows earn
  --     nothing (her only bonus is the 5 Mar class); the private still counts as a class
  select format('ann classes=%s bonus=%s', s.class_points, s.points - s.class_points - s.award_points - s.referral_points) into v
    from public._competition_scores(comp, null, null) s where s.student_id = s_ann;
  if v <> 'ann classes=2.00 bonus=1.00' then raise exception 'FAIL 4.1: %', v; end if;
  raise notice 'PASS 4.1: a going row, an absent row and a private lesson earn no bonus (%)', v;

  -- 4.3 a class the coach marked as not counting (class_value 0) earns no bonus
  select format('rows=%s bonus=%s',
                (select count(*) from public.attendance a where a.student_id = s_ann and a.status = 'present'
                    and coalesce(a.class_value, 0) = 0 and a.created_by = u_ann),
                pg_temp.bonus(comp, s_ann)) into v;
  if v not in ('rows=1 bonus=1.00', 'rows=2 bonus=1.00') then raise exception 'FAIL 4.3: %', v; end if;
  raise notice 'PASS 4.3: Ann''s own present row on a class that doesn''t count earns nothing (%)', v;

  -- 4.2 a competition without the rule, or with it disabled: nobody gets a bonus
  select format('plain=%s off=%s',
                (select sum(s.points - s.class_points - s.award_points - s.referral_points) from public._competition_scores(plain, null, null) s),
                (select sum(s.points - s.class_points - s.award_points - s.referral_points) from public._competition_scores(off, null, null) s)) into v;
  if v <> 'plain=0.00 off=0.00' then raise exception 'FAIL 4.2: %', v; end if;
  raise notice 'PASS 4.2: no bonus without the rule or with it disabled (%)', v;

  -- 5. two self check-ins on two classes the same day give 2
  n := pg_temp.bonus(comp, s_cal);
  if n <> 2 then raise exception 'FAIL 5: Cal bonus %', n; end if;
  raise notice 'PASS 5: two self check ins the same day: bonus %', n;

  -- 6. "Move attendees to another class" (an UPDATE of class_id / time / type /
  --    modality, index.html _moveAttRow) keeps created_by, so the bonus stays
  perform pg_temp.by(u_sid);
  update public.attendance set class_id = null, class_time = '20:00', class_type = 'alev', modality = 'gi' where id = a_cal2;
  perform pg_temp.by(null);
  select format('creator=%s bonus=%s', (select case created_by when u_cal then 'cal' else coalesce(created_by::text, 'null') end from public.attendance where id = a_cal2),
                pg_temp.bonus(comp, s_cal)) into v;
  if v <> 'creator=cal bonus=2.00' then raise exception 'FAIL 6: %', v; end if;
  raise notice 'PASS 6: a moved row keeps its creator and its bonus (%)', v;

  -- 7. only into points: class, gi, no-gi and the class count are the Plain event's
  select string_agg(format('%s %s/%s/%s/%s', s.student_id = s_cal, s.class_points, s.gi_points, s.nogi_points, s.classes_count), ',' order by s.student_id) into v
    from public._competition_scores(comp, null, null) s;
  select string_agg(format('%s %s/%s/%s/%s', s.student_id = s_cal, s.class_points, s.gi_points, s.nogi_points, s.classes_count), ',' order by s.student_id) into w
    from public._competition_scores(plain, null, null) s;
  select sum(s.points) into n from public._competition_scores(comp, null, null) s;
  select sum(s.points) into m from public._competition_scores(plain, null, null) s;
  if v is distinct from w or n - m <> 6 then raise exception 'FAIL 7: cup % / plain % / points % vs %', v, w, n, m; end if;
  raise notice 'PASS 7: class, gi, no-gi and classes columns unchanged; points differ by the 6 bonus points (Ann 1, Eve 1, Cal 2, Kit 1, Kev 1)';

  -- 8. standings, battle and review read it through _competition_scores
  perform pg_temp.v_as(u_adm);
  select format('ann=%s cal=%s', max(x.points) filter (where x.student_id = s_ann), max(x.points) filter (where x.student_id = s_cal)) into v
    from public.competition_standings(comp, null, null) x;
  execute 'reset role';
  if v <> 'ann=8.00 cal=4.00' then raise exception 'FAIL 8: standings %', v; end if;
  raise notice 'PASS 8: standings include the bonus (%)', v;

  select format('%s', b.points) into v from public._competition_battle(comp, null, null, '2001-04-30') b where b.unit_id = ua and b.audience = 'adult';
  select format('%s', b.points) into w from public._competition_battle(plain, null, null, '2001-04-30') b where b.unit_id = ua and b.audience = 'adult';
  if v::numeric - w::numeric <> 4 then raise exception 'FAIL 8.1: battle cup % plain %', v, w; end if;
  raise notice 'PASS 8.1: the battle''s points include the adults'' bonus (cup %, plain %)', v, w;

  perform pg_temp.v_as(u_adm);
  select format('cal=%s', max(x.points) filter (where x.student_id = s_cal)) into v from public.competition_review(comp) x;
  execute 'reset role';
  if v <> 'cal=4.00' then raise exception 'FAIL 8.2: review %', v; end if;
  raise notice 'PASS 8.2: review includes the bonus (%)', v;

  -- 11. the parts add up: class + award + referral + checkin = points, in every
  --     function that passes the parts through (checkin_points is their last column)
  select string_agg(x.f || '=' || x.ok, ' ' order by x.f) into v from (
    select 'scores' as f, bool_and(s.class_points + s.award_points + s.referral_points + s.checkin_points = s.points)
                          and max(s.checkin_points) filter (where s.student_id = s_ann) = 1
                          and max(s.award_points) filter (where s.student_id = s_ann) = 2
                          and max(s.referral_points) filter (where s.student_id = s_ann) = 3
                          and max(s.class_points) filter (where s.student_id = s_ann) = 2 as ok
      from public._competition_scores(comp, null, null) s
    union all
    select 'ranked', bool_and(r.class_points + r.award_points + r.referral_points + r.checkin_points = r.points)
                     and max(r.checkin_points) filter (where r.student_id = s_cal) = 2
      from public._competition_ranked(comp, null, null) r
    union all
    select 'close_rows', bool_and(c.class_points + c.award_points + c.referral_points + c.checkin_points = c.points)
                         and max(c.checkin_points) filter (where c.student_id = s_ann) = 1
      from public._competition_close_rows(comp) c) x;
  if v <> 'close_rows=true ranked=true scores=true' then raise exception 'FAIL 11: %', v; end if;
  perform pg_temp.v_as(u_adm);
  select format('ann %s+%s+%s+%s=%s', x.class_points::numeric(10,2), x.award_points::numeric(10,2), x.referral_points::numeric(10,2), x.checkin_points::numeric(10,2), x.points::numeric(10,2)) into v
    from public.competition_standings(comp, null, null) x where x.student_id = s_ann;
  execute 'reset role';
  if v <> 'ann 2.00+2.00+3.00+1.00=8.00' then raise exception 'FAIL 11: standings %', v; end if;
  if exists (select 1 from unnest(array['public._competition_scores(uuid,date,date)', 'public._competition_ranked(uuid,date,date)',
                                        'public._competition_close_rows(uuid)', 'public.competition_standings(uuid,date,date)']) f
              where pg_get_function_result(f::regprocedure) not like '%, checkin_points numeric)') then
    raise exception 'FAIL 11: checkin_points is not the last column everywhere';
  end if;
  raise notice 'PASS 11: the parts add up to points in scores, ranked, close rows and standings (%); checkin_points is the last column', v;

  -- 12. competition_finalize keeps checkin_points in its snapshot
  perform pg_temp.v_as(u_adm);
  perform public.competition_finalize(comp, null, null);
  execute 'reset role';
  select format('ann=%s cal=%s sums=%s',
                max((cr.payload ->> 'checkin_points')::numeric(10,2)) filter (where cr.student_id = s_ann),
                max((cr.payload ->> 'checkin_points')::numeric(10,2)) filter (where cr.student_id = s_cal),
                bool_and((cr.payload ->> 'class_points')::numeric + (cr.payload ->> 'award_points')::numeric
                         + (cr.payload ->> 'referral_points')::numeric + (cr.payload ->> 'checkin_points')::numeric = cr.points)) into v
    from public.competition_results cr where cr.competition_id = comp;
  if v <> 'ann=1.00 cal=2.00 sums=t' then raise exception 'FAIL 12: %', v; end if;
  raise notice 'PASS 12: the finalize snapshot stores checkin_points (%)', v;

  -- 13. the TV's Cup "bonus points" (provisional) counts check ins: everything but class points
  update public.competitions set status = 'draft' where id in (plain, off);   -- one ended event at the unit
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz163 tv', ua, encode(sha256('zz163-a'::bytea), 'hex'), true) returning id into scr;
  select sum(s.points - s.class_points) into n from public._competition_scores(comp, null, null) s where s.unit_id = ua and s.audience = 'adult';
  p := public._tv_payload(scr, '2001-04-05', '10:00');
  if p -> 'cup' ->> 'phase' is distinct from 'provisional' or (p -> 'cup' -> 'adult' -> 'numbers' ->> 'bonus')::numeric is distinct from n then
    raise exception 'FAIL 13: cup % (expected bonus %)', p -> 'cup', n;
  end if;
  raise notice 'PASS 13: TV Cup bonus (provisional) = points less class points = %', n;

  -- 14. publish: the frozen snapshot adds up and the TV reads it
  perform pg_temp.v_as(u_adm);
  perform public.competition_publish(comp, '[]'::jsonb);
  select format('ann %s+%s+%s+%s=%s', x.class_points::numeric(10,2), x.award_points::numeric(10,2), x.referral_points::numeric(10,2), x.checkin_points::numeric(10,2), x.points::numeric(10,2)) into v
    from public.competition_standings(comp, null, null) x where x.student_id = s_ann;
  execute 'reset role';
  if v <> 'ann 2.00+2.00+3.00+1.00=8.00' then raise exception 'FAIL 14: frozen standings %', v; end if;
  p := public._tv_payload(scr, '2001-04-05', '10:00');
  if p -> 'cup' ->> 'phase' is distinct from 'published' or (p -> 'cup' -> 'adult' -> 'numbers' ->> 'bonus')::numeric is distinct from n then
    raise exception 'FAIL 14: cup % (expected bonus %)', p -> 'cup', n;
  end if;
  raise notice 'PASS 14: published: frozen standings add up (%), TV Cup bonus %', v, n;

  -- 9. internal functions: no client can execute them
  if has_function_privilege('anon', 'public._attendance_is_self(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public._attendance_is_self(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public._attendance_created_by()', 'execute')
     or has_function_privilege('authenticated', 'public._attendance_created_by()', 'execute')
     or has_function_privilege('authenticated', 'public._competition_scores(uuid, date, date)', 'execute') then
    raise exception 'FAIL 9: an internal function is executable by a client role';
  end if;
  raise notice 'PASS 9: _attendance_is_self, the trigger function and _competition_scores are internal';

  -- 10. the catalog row, between class_attended and social_post
  select format('%s|%s|%s|%s|%s|%s', k.label, k.description, k.how_to_score, k.source, k.default_points, k.default_params) into v
    from public.competition_rule_catalog k where k.key = 'self_checkin';
  if v is distinct from 'Self check in|Check yourself in on the app and get a bonus point once your coach marks you present.|Check in on the app: {points} bonus per class|attendance|1|{}'
     or (select sort from public.competition_rule_catalog where key = 'self_checkin')
          not between (select sort + 1 from public.competition_rule_catalog where key = 'class_attended')
                  and (select sort - 1 from public.competition_rule_catalog where key = 'social_post') then
    raise exception 'FAIL 10: %', v;
  end if;
  raise notice 'PASS 10: catalog self_checkin: %', v;

  -- 10.1 the Christmas Cup has it (1 point, enabled); no monthly race does
  select format('cup=%s monthly=%s',
                (select r.points || '/' || r.enabled from public.competition_rules r
                  where r.competition_id = '672e130e-ef51-42d4-916d-61593f88515c' and r.rule_key = 'self_checkin'),
                (select count(*) from public.competition_rules r join public.competitions c on c.id = r.competition_id
                  where c.kind = 'monthly' and r.rule_key = 'self_checkin')) into v;
  if v <> 'cup=1/true monthly=0' then raise exception 'FAIL 10.1: %', v; end if;
  raise notice 'PASS 10.1: %', v;
end $$;

rollback;
