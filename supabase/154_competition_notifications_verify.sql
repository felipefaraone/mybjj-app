-- 154_competition_notifications_verify.sql
--
-- Run AFTER 154, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/154_competition_notifications_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic people (adult member, kid + guardian, referrer, friend) and a
-- synthetic ACTIVE challenge in July 2031 on the first unit (by name).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; cls uuid; cls2 uuid; comp uuid;
  u_ad uuid := gen_random_uuid(); u_par uuid := gen_random_uuid(); u_ref uuid := gen_random_uuid();
  s_ad uuid; s_kid uuid; s_ref uuid; s_new uuid;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; b1 uuid; b2 uuid; b3 uuid;
  n int; v text; v2 text; v_err text;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select c.id into cls from public.classes c order by c.id limit 1;
  select c.id into cls2 from public.classes c order by c.id offset 1 limit 1;
  if ua is null or cls is null then raise exception 'FAIL setup: needs a unit and a class'; end if;

  -- 1. constraints: the new values are accepted, an unknown one is still refused
  insert into auth.users (id, email) values (u_ad,'zz154-adult@example.invalid'),(u_par,'zz154-parent@example.invalid'),(u_ref,'zz154-ref@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_ad,'zz154-adult@example.invalid','Zz154 Adult','student','approved',ua),
    (u_par,'zz154-parent@example.invalid','Zz154 Parent','parent','approved',ua),
    (u_ref,'zz154-ref@example.invalid','Zz154 Ref','student','approved',ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.notifications (user_id, type, title, related_entity_type, related_entity_id)
    values (u_ad, 'competition_points', 'zz154 probe', 'competition_award', gen_random_uuid()),
           (u_ad, 'competition_points', 'zz154 probe', 'trial_referral', gen_random_uuid());
  begin
    insert into public.notifications (user_id, type, title) values (u_ad, 'zz_unknown_type', 'x');
    v_err := 'accepted';
  exception when check_violation then v_err := 'check_violation'; end;
  begin
    insert into public.notifications (user_id, type, title, related_entity_type) values (u_ad, 'competition_points', 'x', 'zz_unknown_entity');
    v_err := v_err || '/accepted';
  exception when check_violation then v_err := v_err || '/check_violation'; end;
  if v_err <> 'check_violation/check_violation' then raise exception 'FAIL 1: %', v_err; end if;
  delete from public.notifications where title = 'zz154 probe';
  raise notice 'PASS 1: constraints accept competition_points / competition_award / trial_referral and still reject unknown values';

  -- fixtures: a July 2031 challenge (best_attitude disabled), people
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz154 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz154 adults'), (comp, ua, 'kids', 'zz154 kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp,'class_attended',1,true),(comp,'class_challenge',3,true),(comp,'best_attitude',1,false),
    (comp,'social_post',2,true),(comp,'referral_trial',3,true),(comp,'referral_conversion',5,true);
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz154 Adam Adult','Adam','Adult','adult',ua,true,'ok',u_ad) returning id into s_ad;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz154 Kit Kid','Kit','Kid','kids',ua,true,'ok') returning id into s_kid;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values (s_kid, u_par, 'active', 'legacy_sync', 'manage');
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz154 Rae Ref','Rae','Ref','adult',ua,true,'ok',u_ref) returning id into s_ref;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz154 Fred New','Fred','New','adult',ua,true,'ok') returning id into s_new;

  -- 2. social post -> the adult's account, exact copy
  insert into public.competition_awards (student_id, award_key, award_date) values (s_ad, 'social_post', '2031-07-02') returning id into a1;
  select string_agg(n.title || ' | ' || n.body, ' ; ') into v from public.notifications n
   where n.related_entity_type = 'competition_award' and n.related_entity_id = a1 and n.user_id = u_ad and n.dismissed_at is null;
  if v is distinct from 'Social post logged · +2 | Thanks for sharing myBJJ. Zz154 Cup' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: social post notifies the member: %', v;

  -- 3. kid class challenge (present) -> the guardian, kid wording
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_kid, cls, '2031-07-01', '16:00', 'kids', 'present', 1.00, ua);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (s_kid, 'class_challenge', '2031-07-01', cls, '2031-07-01') returning id into a2;
  select string_agg(n.user_id::text || ' | ' || n.title || ' | ' || n.body, ' ; ') into v from public.notifications n
   where n.related_entity_type = 'competition_award' and n.related_entity_id = a2 and n.dismissed_at is null;
  if v is distinct from u_par::text || ' | Kit won the class challenge · +3 | Zz154 Cup · Tue 1 Jul' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: kid class challenge notifies the guardian: Kit won the class challenge · +3 | Zz154 Cup · Tue 1 Jul';

  -- 4. unread count matches, then a void removes it
  perform pg_temp.v_as(u_par);
  n := public.unread_notification_count();
  select count(*) into v_err from public.list_my_notifications(50, false) x where x.related_entity_id = a2;
  execute 'reset role';
  if n <> 1 or v_err <> '1' then raise exception 'FAIL 4: unread % listed %', n, v_err; end if;
  update public.competition_awards set voided_at = now() where id = a2;
  perform pg_temp.v_as(u_par);
  n := public.unread_notification_count();
  select count(*) into v_err from public.list_my_notifications(50, false) x where x.related_entity_id = a2;
  execute 'reset role';
  if n <> 0 or v_err <> '0' then raise exception 'FAIL 4: after void unread % listed %', n, v_err; end if;
  raise notice 'PASS 4: unread count 1 (bell list 1); after the void 0 and gone from the bell';

  -- 5. the rule is disabled (best_attitude) -> nothing; a class award without a present attendance -> nothing
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_ad, cls, '2031-07-03', '18:00', 'beg', 'present', 1.00, ua);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (s_ad, 'best_attitude', '2031-07-03', cls, '2031-07-03') returning id into a3;
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (s_ad, 'class_challenge', '2031-07-04', cls, '2031-07-04') returning id into a4;
  select count(*) into n from public.notifications where related_entity_id in (a3, a4);
  if n <> 0 then raise exception 'FAIL 5: % notifications for a disabled rule / no attendance', n; end if;
  raise notice 'PASS 5: disabled rule and a class award without a present attendance notify nobody';

  -- 6. referral linked, friend not trained yet -> "Thanks for the referral"
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time)
    values (ua, 'Fred', 'New', 'zz154-fred@example.invalid', '0400000154', 'booked', now(), cls, '2031-07-20', '18:00') returning id into b1;
  update public.trial_bookings set referred_by_student_id = s_ref where id = b1;
  select string_agg(n.title || ' | ' || n.body, ' ; ') into v from public.notifications n
   where n.user_id = u_ref and n.metadata->>'booking_id' = b1::text and n.dismissed_at is null;
  if v not like 'Thanks for the referral | When Fred trains with us you get +3. If they sign up, +5 more.' then raise exception 'FAIL 6: %', v; end if;
  raise notice 'PASS 6: link -> %', v;

  -- 7. converted while the referrer is linked -> "Fred signed up · +5"
  update public.trial_bookings set converted_student_id = s_new, converted_at = (timestamp '2031-07-10 10:00' at time zone 'Australia/Sydney') where id = b1;
  select string_agg(n.title, ' ; ' order by n.created_at) into v from public.notifications n
   where n.user_id = u_ref and n.metadata->>'booking_id' = b1::text and n.metadata->>'kind' = 'conversion' and n.dismissed_at is null;
  if v is distinct from 'Fred signed up · +5' then raise exception 'FAIL 7: %', v; end if;
  raise notice 'PASS 7: conversion -> %', v;

  -- 8. unlink -> the referrer's notifications for that booking are removed
  update public.trial_bookings set referred_by_student_id = null where id = b1;
  select count(*) into n from public.notifications where user_id = u_ref and metadata->>'booking_id' = b1::text and dismissed_at is null;
  if n <> 0 then raise exception 'FAIL 8: % still showing after unlink', n; end if;
  raise notice 'PASS 8: unlink removes the referral notifications';

  -- 9. self-referral (the referee is the referrer) -> nothing
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                     converted_student_id, converted_at)
    values (ua, 'Rae', 'Ref', 'zz154-rae@example.invalid', '0400000155', 'booked', now(), cls, '2031-07-05', '18:00',
            s_ref, timestamp '2031-07-06 10:00' at time zone 'Australia/Sydney') returning id into b2;
  update public.trial_bookings set referred_by_student_id = s_ref where id = b2;
  select count(*) into n from public.notifications where metadata->>'booking_id' = b2::text;
  if n <> 0 then raise exception 'FAIL 9: % notifications for a self-referral', n; end if;
  raise notice 'PASS 9: self-referral notifies nobody';

  -- 10. linked after the friend already trained -> "<Friend> trained with us · +3"
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time)
    values (ua, 'Gia', 'Friend', 'zz154-gia@example.invalid', '0400000156', 'booked', now(), cls, '2031-07-08', '18:00') returning id into b3;
  insert into public.trial_sessions (trial_booking_id, class_id, class_date, class_time, attended) values (b3, cls, '2031-07-08', '18:00', true);
  update public.trial_bookings set referred_by_student_id = s_ref where id = b3;
  select string_agg(n.title || ' | ' || n.body, ' ; ') into v from public.notifications n
   where n.user_id = u_ref and n.metadata->>'booking_id' = b3::text and n.dismissed_at is null;
  if v is distinct from 'Gia trained with us · +3 | Zz154 Cup' then raise exception 'FAIL 10: %', v; end if;
  raise notice 'PASS 10: link after training -> %', v;

  -- 11. unread count for the referrer matches the bell (2 dismissed, 1 live)
  perform pg_temp.v_as(u_ref);
  n := public.unread_notification_count();
  select count(*) into v2 from public.list_my_notifications(50, false) x where x.type = 'competition_points';
  execute 'reset role';
  if n <> 1 or v2 <> '1' then raise exception 'FAIL 11: unread % listed %', n, v2; end if;
  raise notice 'PASS 11: referrer unread count 1 = bell list 1';

  -- 12. nothing here is callable by clients
  if has_function_privilege('authenticated', 'public._competition_notify_rule(uuid, date, text)', 'execute')
     or has_function_privilege('authenticated', 'public.competition_awards_notify()', 'execute')
     or has_function_privilege('authenticated', 'public.trial_referral_notify()', 'execute') then
    raise exception 'FAIL 12: an internal function is executable by authenticated';
  end if;
  raise notice 'PASS 12: 154 functions closed to clients';
end $$;

rollback;
