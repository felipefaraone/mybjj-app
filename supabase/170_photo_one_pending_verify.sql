-- 170_photo_one_pending_verify.sql
--
-- Run AFTER 170, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/170_photo_one_pending_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- People (first unit by name): Sam is a student with a login, Tom is staff
-- (also uploads for Sam), Una is a login with no staff or students row, Kim and
-- Lou are students used for the cleanup.

begin;

create function pg_temp.st(p uuid) returns text language sql as $f$
  select status from public.photo_approvals where id = p
$f$;
create function pg_temp.add(p_user uuid, p_student uuid, p_staff uuid, p_path text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.photo_approvals (user_id, student_id, staff_id, photo_url, status)
    values (p_user, p_student, p_staff, p_path, 'pending') returning id into v;
  return v;
end $f$;

do $$
declare
  ua uuid;
  u_sam uuid := gen_random_uuid(); u_tom uuid := gen_random_uuid(); u_una uuid := gen_random_uuid();
  st_tom uuid; s_sam uuid; s_kim uuid; s_lou uuid;
  a1 uuid; a2 uuid; b1 uuid; b2 uuid; c1 uuid; c2 uuid; k1 uuid; k2 uuid; k3 uuid; l1 uuid; l2 uuid;
  v text; n int;
begin
  -- 0. structure
  if not exists (select 1 from pg_constraint where conrelid = 'public.photo_approvals'::regclass and conname = 'photo_approvals_status_check'
                  and pg_get_constraintdef(oid) like '%superseded%') then
    raise exception 'FAIL 0: status check does not allow superseded';
  end if;
  select count(*) into n from pg_trigger where tgrelid = 'public.photo_approvals'::regclass
     and tgname in ('trg_photo_one_pending', 'trg_photo_superseded_final', 'trg_photo_approval_sync');
  if n <> 3 then raise exception 'FAIL 0: expected 3 triggers, found %', n; end if;
  if has_function_privilege('authenticated', 'public._photo_supersede_duplicates()', 'execute')
     or has_function_privilege('authenticated', 'public._photo_subject_key(uuid, uuid, uuid)', 'execute') then
    raise exception 'FAIL 0: a 170 helper is callable by a client';
  end if;
  if not exists (select 1 from pg_class where oid = 'public._bak_photo_approvals_pending_20261025'::regclass and relrowsecurity) then
    raise exception 'FAIL 0: backup table missing or without RLS';
  end if;
  raise notice 'PASS 0: check allows superseded; triggers present; helpers internal; backup has RLS';

  -- the cleanup already ran: no person has two pending photos
  select count(*) into n from (
    select public._photo_subject_key(staff_id, student_id, user_id) from public.photo_approvals
     where status = 'pending' group by 1 having count(*) > 1) x;
  if n <> 0 then raise exception 'FAIL 0.1: % subject(s) still have more than one pending photo', n; end if;
  raise notice 'PASS 0.1: every subject has at most one pending photo';

  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;
  insert into auth.users (id, email)
  select x, 'zz170-' || x::text || '@example.invalid' from unnest(array[u_sam, u_tom, u_una]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz170-' || x.id::text || '@example.invalid', 'Zz170', x.role, 'approved', ua
    from (values (u_sam, 'student'), (u_tom, 'instructor'), (u_una, 'student')) x(id, role)
  on conflict (id) do update set role = excluded.role, status = excluded.status, photo_url = null;
  insert into public.staff (user_id, full_name, belt, unit_id) values (u_tom, 'Zz170 Tom Staff', 'black', ua) returning id into st_tom;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz170 Sam Student', 'Sam', 'S', 'adult', ua, true, 'ok', u_sam) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz170 Kim Student', 'Kim', 'K', 'adult', ua, true, 'ok') returning id into s_kim;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz170 Lou Student', 'Lou', 'L', 'adult', ua, true, 'ok') returning id into s_lou;

  -- 1. student: Sam sends one, then the coach sends another for Sam (a row Sam
  --    could never see or delete): the first is superseded
  a1 := pg_temp.add(u_sam, s_sam, null, 'student/zz170-a1.jpg');
  a2 := pg_temp.add(u_tom, s_sam, null, 'student/zz170-a2.jpg');
  v := pg_temp.st(a1) || '/' || pg_temp.st(a2);
  if v <> 'superseded/pending' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: student: second pending supersedes the first (%)', v;

  -- 2. staff
  b1 := pg_temp.add(u_tom, null, st_tom, 'staff/zz170-b1.jpg');
  b2 := pg_temp.add(u_tom, null, st_tom, 'staff/zz170-b2.jpg');
  v := pg_temp.st(b1) || '/' || pg_temp.st(b2);
  if v <> 'superseded/pending' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: staff: second pending supersedes the first (%)', v;

  -- 3. self (a login with neither staff nor student)
  c1 := pg_temp.add(u_una, null, null, 'self/zz170-c1.jpg');
  c2 := pg_temp.add(u_una, null, null, 'self/zz170-c2.jpg');
  v := pg_temp.st(c1) || '/' || pg_temp.st(c2);
  if v <> 'superseded/pending' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: self: second pending supersedes the first (%)', v;

  -- 4. different subjects coexist (Sam's, Tom's staff photo, Una's), and Tom's own
  --    upload for Sam did not touch Tom's staff subject
  select count(*) into n from public.photo_approvals where id in (a2, b2, c2) and status = 'pending';
  if n <> 3 then raise exception 'FAIL 4: % of 3 subjects still pending', n; end if;
  raise notice 'PASS 4: pending photos of three different subjects coexist';

  -- 5. a superseded row published nothing and sent nothing (so far nothing is published)
  if coalesce((select photo_url from public.students where id = s_sam), '') <> ''
     or coalesce((select photo_url from public.users where id = u_sam), '') <> '' then
    raise exception 'FAIL 5: a photo was published by superseding';
  end if;
  if to_regclass('public.notifications') is not null then
    select count(*) into n from public.notifications where related_entity_id in (a1, b1, c1);
    if n <> 0 then raise exception 'FAIL 5: % notification(s) for superseded rows', n; end if;
  end if;
  raise notice 'PASS 5: superseding publishes nothing and notifies nobody';

  -- 6. approving the newest still publishes through 41/167
  update public.photo_approvals set status = 'approved', approved_by_id = u_tom, approved_at = now() where id = a2;
  v := coalesce((select photo_url from public.students where id = s_sam), '-') || ' ' || coalesce((select photo_url from public.users where id = u_sam), '-');
  if v <> 'student/zz170-a2.jpg student/zz170-a2.jpg' then raise exception 'FAIL 6: %', v; end if;
  raise notice 'PASS 6: approving the newest publishes it (%)', v;

  -- 7. a superseded row can never be approved (so it never publishes)
  begin
    update public.photo_approvals set status = 'approved', approved_by_id = u_tom, approved_at = now() where id = a1;
    raise exception 'FAIL 7: a superseded row was approved';
  exception when check_violation then null;
  end;
  if pg_temp.st(a1) <> 'superseded' or (select photo_url from public.students where id = s_sam) <> 'student/zz170-a2.jpg' then
    raise exception 'FAIL 7: superseded row changed or published';
  end if;
  raise notice 'PASS 7: approving a superseded row is refused; the published photo is unchanged';

  -- 8. the queue's read (status = 'pending') never returns a superseded row
  select count(*) into n from public.photo_approvals where status = 'pending' and id in (a1, b1, c1);
  if n <> 0 then raise exception 'FAIL 8: superseded rows in the pending read'; end if;
  raise notice 'PASS 8: the photo queue''s pending read excludes superseded rows';

  -- 9. the cleanup keeps the newest pending per subject. Duplicates are made
  --    the way old data got them, without the insert trigger: inserted as
  --    rejected, then set back to pending (an update, not an insert)
  insert into public.photo_approvals (user_id, student_id, photo_url, status, submitted_at) values
    (u_tom, s_kim, 'student/zz170-k1.jpg', 'rejected', now() - interval '3 hours'),
    (u_tom, s_kim, 'student/zz170-k2.jpg', 'rejected', now() - interval '2 hours'),
    (u_tom, s_kim, 'student/zz170-k3.jpg', 'rejected', now() - interval '1 hour'),
    (u_tom, s_lou, 'student/zz170-l1.jpg', 'rejected', now() - interval '2 hours'),
    (u_tom, s_lou, 'student/zz170-l2.jpg', 'rejected', now() - interval '1 hour');
  update public.photo_approvals set status = 'pending' where photo_url like 'student/zz170-k_.jpg' or photo_url like 'student/zz170-l_.jpg';
  select id into k1 from public.photo_approvals where photo_url = 'student/zz170-k1.jpg';
  select id into k2 from public.photo_approvals where photo_url = 'student/zz170-k2.jpg';
  select id into k3 from public.photo_approvals where photo_url = 'student/zz170-k3.jpg';
  select id into l1 from public.photo_approvals where photo_url = 'student/zz170-l1.jpg';
  select id into l2 from public.photo_approvals where photo_url = 'student/zz170-l2.jpg';
  n := public._photo_supersede_duplicates();
  v := n || ' ' || pg_temp.st(k1) || '/' || pg_temp.st(k2) || '/' || pg_temp.st(k3) || ' ' || pg_temp.st(l1) || '/' || pg_temp.st(l2);
  if v <> '3 superseded/superseded/pending superseded/pending' then raise exception 'FAIL 9: %', v; end if;
  raise notice 'PASS 9: cleanup keeps the newest pending per subject (%)', v;
end $$;

rollback;
