-- 167_photo_belongs_to_person_verify.sql
--
-- Run AFTER 167, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/167_photo_belongs_to_person_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- People (first unit by name): Bri is staff and has two adult students rows
-- (one per unit); Sam is a student only; Tom is staff only; Kit is a kid with
-- no login whose guardian Gil (an adult member) uploads a photo for him.
-- A photo is published the way the app does it: a photo_approvals row moves
-- from pending to approved (staff auto-approval is the same update).

begin;

create function pg_temp.publish(p_user uuid, p_student uuid, p_staff uuid, p_path text) returns void language plpgsql as $f$
declare v uuid;
begin
  insert into public.photo_approvals (user_id, student_id, staff_id, photo_url, status)
    values (p_user, p_student, p_staff, p_path, 'pending') returning id into v;
  update public.photo_approvals set status = 'approved', approved_by_id = p_user, approved_at = now() where id = v;
end $f$;
create function pg_temp.photos(p_user uuid) returns text language sql as $f$
  select format('users=%s staff=%s students=%s',
    coalesce((select photo_url from public.users where id = p_user), '-'),
    coalesce((select string_agg(coalesce(photo_url, '-'), ',' order by id) from public.staff where user_id = p_user), '-'),
    coalesce((select string_agg(coalesce(photo_url, '-'), ',' order by id) from public.students where user_id = p_user), '-'))
$f$;

do $$
declare
  ua uuid; ub uuid;
  u_bri uuid := gen_random_uuid(); u_sam uuid := gen_random_uuid(); u_tom uuid := gen_random_uuid(); u_gil uuid := gen_random_uuid();
  st_bri uuid; st_tom uuid; s_bri uuid; s_bri2 uuid; s_sam uuid; s_gil uuid; s_kit uuid;
  v text; v_rm regprocedure;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;

  insert into auth.users (id, email)
  select x, 'zz167-' || x::text || '@example.invalid' from unnest(array[u_bri, u_sam, u_tom, u_gil]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz167-' || x.id::text || '@example.invalid', 'Zz167', x.role, 'approved', ua
    from (values (u_bri, 'instructor'), (u_sam, 'student'), (u_tom, 'instructor'), (u_gil, 'parent')) x(id, role)
  on conflict (id) do update set role = excluded.role, status = excluded.status, photo_url = null;
  insert into public.staff (user_id, full_name, belt, unit_id) values (u_bri, 'Zz167 Bri Staff', 'black', ua) returning id into st_bri;
  insert into public.staff (user_id, full_name, belt, unit_id) values (u_tom, 'Zz167 Tom Staff', 'brown', ua) returning id into st_tom;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz167 Bri Student','Bri','S','adult',ua,true,'ok',u_bri) returning id into s_bri;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz167 Bri Two','Bri','T','adult',ub,true,'ok',u_bri) returning id into s_bri2;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz167 Sam Student','Sam','S','adult',ua,true,'ok',u_sam) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz167 Gil Guardian','Gil','G','adult',ua,true,'ok',u_gil) returning id into s_gil;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, parent_user_id)
    values ('Zz167 Kit Kid','Kit','K','kids',ua,true,'ok',u_gil) returning id into s_kit;

  -- 1. staff + student, from the staff profile: the users row, the staff row and both adult students rows
  perform pg_temp.publish(u_bri, null, st_bri, 'staff/a.jpg');
  v := pg_temp.photos(u_bri);
  if v <> 'users=staff/a.jpg staff=staff/a.jpg students=staff/a.jpg,staff/a.jpg' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: staff + student, from the staff profile: %', v;

  -- 2. then from the student profile: every row again (the staff row too)
  perform pg_temp.publish(u_bri, s_bri, null, 'student/b.jpg');
  v := pg_temp.photos(u_bri);
  if v <> 'users=student/b.jpg staff=student/b.jpg students=student/b.jpg,student/b.jpg' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: then from the student profile: %', v;

  -- 3. a student only
  perform pg_temp.publish(u_sam, s_sam, null, 'student/c.jpg');
  v := pg_temp.photos(u_sam);
  if v <> 'users=student/c.jpg staff=- students=student/c.jpg' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: a student only: %', v;

  -- 4. staff only
  perform pg_temp.publish(u_tom, null, st_tom, 'staff/d.jpg');
  v := pg_temp.photos(u_tom);
  if v <> 'users=staff/d.jpg staff=staff/d.jpg students=-' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: staff only: %', v;

  -- 5. a guardian uploading for a kid: the kid row as before (the kids trigger keeps
  --    it empty); the guardian's own rows untouched
  perform pg_temp.publish(u_gil, s_kit, null, 'student/kid.jpg');
  v := coalesce((select photo_url from public.students where id = s_kit), '-') || ' | ' || pg_temp.photos(u_gil);
  if v <> '- | users=- staff=- students=-' then raise exception 'FAIL 5: %', v; end if;
  raise notice 'PASS 5: a guardian''s upload for a kid: kid %', v;

  -- 6. a rejection never touches the published photo
  insert into public.photo_approvals (user_id, staff_id, photo_url, status) values (u_bri, st_bri, 'staff/e.jpg', 'pending');
  update public.photo_approvals set status = 'rejected' where photo_url = 'staff/e.jpg';
  v := pg_temp.photos(u_bri);
  if v <> 'users=student/b.jpg staff=student/b.jpg students=student/b.jpg,student/b.jpg' then raise exception 'FAIL 6: %', v; end if;
  raise notice 'PASS 6: a rejected photo changes nothing: %', v;

  -- 7. a re-update of an approved row does not republish (41's edge rule kept)
  update public.staff set photo_url = 'staff/manual.jpg' where id = st_bri;
  update public.photo_approvals set approved_at = now() where photo_url = 'student/b.jpg';
  if (select photo_url from public.staff where id = st_bri) <> 'staff/manual.jpg' then raise exception 'FAIL 7'; end if;
  update public.staff set photo_url = 'student/b.jpg' where id = st_bri;
  raise notice 'PASS 7: only the pending to approved edge publishes';

  -- 8. remove clears every row of the person (remove_photo lives outside the repo's
  --    migrations: checked where it exists, i.e. production)
  v_rm := to_regprocedure('public.remove_photo()');
  if v_rm is null then
    select p.oid::regprocedure into v_rm from pg_proc p where p.proname = 'remove_photo' and p.pronamespace = 'public'::regnamespace limit 1;
  end if;
  if v_rm is null then
    raise notice 'PASS 8: skipped here: public.remove_photo is not in this database (it is in production; this test runs there)';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', u_bri::text, 'role', 'authenticated')::text, true);
    execute 'select public.remove_photo()';
    perform set_config('request.jwt.claims', '', true);
    v := pg_temp.photos(u_bri);
    if v <> 'users=- staff=- students=-,-' then
      raise exception 'FAIL 8: remove_photo left a row with the photo: % (it must clear the users row, every staff row and every adult students row of the person)', v;
    end if;
    raise notice 'PASS 8: remove_photo clears every row: %', v;
  end if;

  -- 9. the helper is internal
  if has_function_privilege('authenticated', 'public._publish_person_photo(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public._publish_person_photo(uuid, text)', 'execute') then
    raise exception 'FAIL 9: _publish_person_photo is callable by a client';
  end if;
  raise notice 'PASS 9: _publish_person_photo is internal';

  -- 10. no adult students row is left without the approved photo its user has (the fill)
  if exists (select 1 from public.students s join public.users u on u.id = s.user_id
              where s.prog is distinct from 'kids' and coalesce(s.photo_url, '') = '' and coalesce(u.photo_url, '') <> ''
                and exists (select 1 from public.photo_approvals a where a.photo_url = u.photo_url and a.status = 'approved')) then
    raise exception 'FAIL 10: an adult students row is missing its person''s approved photo';
  end if;
  raise notice 'PASS 10: every adult students row has its person''s approved photo';
end $$;

rollback;
