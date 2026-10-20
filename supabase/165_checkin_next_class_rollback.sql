-- ============================================================================
-- 165 rollback — back to 164 (the 30/15 window for check in)
-- ============================================================================
-- Restores 164's _checkin, checkin_arrive and checkin_preview exactly (texts and
-- grants). Nothing else changed in 165.
-- ============================================================================

begin;

do $$
begin
  if position('-- 165' in coalesce((select prosrc from pg_proc
                 where oid = to_regprocedure('public._checkin(uuid, uuid[], text, jsonb, timestamptz, boolean)')), '')) = 0 then
    raise exception '165 rollback: 165 is not applied; stop';
  end if;
end $$;

create function pg_temp.acl_set(p_acl aclitem[], p_owner oid) returns text language sql stable as $f$
  select coalesce(string_agg(case when a.grantee = 0 then 'PUBLIC' else r.rolname::text end || ':' || a.privilege_type, ','
                             order by 1), '')
    from aclexplode(coalesce(p_acl, acldefault('f', p_owner))) a
    left join pg_roles r on r.oid = a.grantee
   where a.grantee <> p_owner
$f$;
create function pg_temp.acl_copy(p_acl aclitem[], p_sig text) returns void language plpgsql as $f$
declare
  v_oid oid := p_sig::regprocedure;
  v_owner oid := (select p.proowner from pg_proc p where p.oid = v_oid);
  x record;
begin
  execute format('revoke all on function %s from public', p_sig);
  for x in select distinct r.rolname from pg_proc p, aclexplode(p.proacl) a join pg_roles r on r.oid = a.grantee
            where p.oid = v_oid and a.grantee <> v_owner loop
    execute format('revoke all on function %s from %I', p_sig, x.rolname);
  end loop;
  for x in select a.grantee, a.privilege_type from aclexplode(coalesce(p_acl, acldefault('f', v_owner))) a
            where a.grantee <> v_owner loop
    execute format('grant %s on function %s to %s', x.privilege_type, p_sig,
                   case when x.grantee = 0 then 'public' else quote_ident((select rolname from pg_roles where oid = x.grantee)) end);
  end loop;
  if pg_temp.acl_set((select proacl from pg_proc where oid = v_oid), v_owner) <> pg_temp.acl_set(p_acl, v_owner) then
    raise exception 'ACL copy failed for %', p_sig;
  end if;
end $f$;

create temp table acl165 on commit drop as
  select x.sig, (select proacl from pg_proc where oid = to_regprocedure(x.sig)) as acl
    from (values ('public._checkin(uuid,uuid[],text,jsonb,timestamptz,boolean)'), ('public.checkin_arrive(uuid,uuid[],text,jsonb)'), ('public.checkin_preview(uuid,uuid[],jsonb)')) x(sig);

drop function if exists public.checkin_preview(uuid, uuid[], jsonb);
drop function if exists public.checkin_arrive(uuid, uuid[], text, jsonb);
drop function if exists public._checkin(uuid, uuid[], text, jsonb, timestamptz, boolean);

-- 164's text, exactly.
create or replace function public._checkin(p_unit uuid, p_student_ids uuid[], p_via text, p_class jsonb,
                                           p_at timestamptz, p_write boolean)
returns table (
  student_id      uuid,
  result          text,
  class_id        uuid,
  class_date      date,
  class_time      text,
  class_label     text,
  class_audience  text,
  class_legacy_id text,
  attendance_id   uuid,
  status          text,
  arrived_at      timestamptz,
  opens_at        text,
  options         jsonb
)
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_uid  uuid := auth.uid();
  v_loc  timestamp := p_at at time zone 'Australia/Sydney';
  v_day  date := (p_at at time zone 'Australia/Sydney')::date;
  v_time time := (p_at at time zone 'Australia/Sydney')::time;
  v_nowm numeric := extract(epoch from (p_at at time zone 'Australia/Sydney')::time) / 60;
  v_cands jsonb;
  v_win   jsonb;
  v_fit   jsonb;
  v_pick  jsonb;
  v_aud   text;
  v_mod   text;
  v_id    uuid;
  v_cid   uuid;          -- the picked class (locals: the output names are also column names)
  v_t     text;
  v_done  boolean;
  st      record;
  a       record;
begin
  if p_via is null or p_via not in ('qr', 'app') then
    raise exception 'p_via must be qr or app' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.units u where u.id = p_unit and u.active is not false) then
    raise exception 'unknown unit' using errcode = 'invalid_parameter_value';
  end if;
  v_cands := public._classes_on_day(p_unit, v_day);
  v_win := public._classes_in_window(p_unit, v_day, v_time);

  for st in
    select x.sid, x.o, s.id as id, s.user_id, s.parent_user_id, s.standing::text as standing, s.prog::text as prog
      from unnest(coalesce(p_student_ids, array[]::uuid[])) with ordinality x(sid, o)
      left join public.students s on s.id = x.sid
     order by x.o
  loop
    student_id := st.sid; result := null; class_id := null; class_date := null; class_time := null;
    class_label := null; class_audience := null; class_legacy_id := null; attendance_id := null;
    status := null; arrived_at := null; opens_at := null; options := '[]'::jsonb;

    if st.id is null or v_uid is null
       or not coalesce(st.user_id = v_uid or st.parent_user_id = v_uid or public.is_guardian_of(st.id, 'manage'), false) then   -- null is never a yes
      result := 'not_allowed'; return next; continue;
    end if;
    if st.standing = 'on_hold' then
      result := 'on_hold'; return next; continue;
    end if;

    v_aud := case when st.prog = 'kids' then 'kids' else 'adults' end;
    select coalesce(jsonb_agg(w || jsonb_build_object('label', public._tv_class_label(w ->> 'uni', w ->> 'lvl', w ->> 'typ'),
                                                      'time', to_char((w ->> 't')::time, 'HH24:MI'))
                              order by abs(extract(epoch from (w ->> 't')::time) / 60 - v_nowm), (w ->> 't')::time,
                                       w ->> 'aud', w ->> 'class_id'), '[]'::jsonb)
      into v_fit
      from jsonb_array_elements(v_win) w
     where lower(w ->> 'aud') in ('all', v_aud);
    options := v_fit;

    if jsonb_array_length(v_fit) = 0 then
      select to_char((x ->> 't')::time, 'HH24:MI'), to_char((x ->> 't')::time - interval '30 minutes', 'HH24:MI')
        into class_time, opens_at
        from jsonb_array_elements(v_cands) x
       where lower(x ->> 'aud') in ('all', v_aud)
         and extract(epoch from (x ->> 't')::time) / 60 - 30 > v_nowm
       order by (x ->> 't')::time
       limit 1;
      result := 'no_class'; return next; continue;
    end if;

    v_pick := null;
    if p_class is not null then
      select f into v_pick from jsonb_array_elements(v_fit) f
       where (nullif(p_class ->> 'class_id', '') is not null and f ->> 'class_id' = p_class ->> 'class_id')
          or (nullif(p_class ->> 'class_id', '') is null and f ->> 'class_id' is null
              and f ->> 'time' = left(coalesce(p_class ->> 'time', ''), 5))
       limit 1;
      if v_pick is null then
        result := 'invalid_class'; return next; continue;
      end if;
    else
      select f into v_pick
        from jsonb_array_elements(v_fit) with ordinality f(f, n)
       where exists (select 1 from public.attendance x
                      where x.student_id = st.id and x.class_date = v_day
                        and ((f ->> 'class_id' is not null and x.class_id = (f ->> 'class_id')::uuid)
                             or (f ->> 'class_id' is null and x.class_id is null and x.unit_id = p_unit
                                 and left(x.class_time::text, 5) = f ->> 'time')))
       order by n
       limit 1;
      if v_pick is null then v_pick := v_fit -> 0; end if;
    end if;

    v_cid := (v_pick ->> 'class_id')::uuid;
    v_t := v_pick ->> 'time';
    class_id := v_cid;
    class_date := v_day;
    class_time := v_t;
    class_label := v_pick ->> 'label';
    class_audience := v_pick ->> 'aud';
    class_legacy_id := v_pick ->> 'legacy';

    select x.id, x.status::text as status, x.arrived_at into a
      from public.attendance x
     where x.student_id = st.id and x.class_date = v_day
       and ((v_cid is not null and x.class_id = v_cid)
            or (v_cid is null and x.class_id is null and x.unit_id = p_unit
                and left(x.class_time::text, 5) = v_t))
     order by (x.status = 'present') desc, x.id
     limit 1;
    v_id := a.id;

    if not p_write then
      attendance_id := v_id; status := a.status; arrived_at := a.arrived_at;
      result := case when a.arrived_at is not null then 'already' else 'ready' end;
      return next; continue;
    end if;

    if v_id is null then
      -- doCI's row: modality from the uniform (Gi / No-Gi; Mixed none), else from the type
      v_mod := case when nullif(v_pick ->> 'uni', '') is not null
                    then case v_pick ->> 'uni' when 'Gi' then 'gi' when 'No-Gi' then 'nogi' end
                    when v_pick ->> 'typ' in ('gi', 'alev', 'beg', 'adv', 'jun', 'mini') then 'gi'
                    when v_pick ->> 'typ' in ('nogi', 'jnogi', 'mma', 'jmma') then 'nogi' end;
      insert into public.attendance (student_id, unit_id, class_id, class_legacy_id, class_date, class_time,
                                     class_type, modality, gi, status)
      values (st.id, p_unit, v_cid, v_pick ->> 'legacy', v_day, v_t,
              v_pick ->> 'typ', v_mod, v_mod is not distinct from 'gi', 'going')
      on conflict do nothing
      returning id into v_id;
      if v_id is null then
        select x.id into v_id from public.attendance x
         where x.student_id = st.id and x.class_date = v_day
           and ((v_cid is not null and x.class_id = v_cid)
                or (v_cid is null and x.class_id is null and x.unit_id = p_unit
                    and left(x.class_time::text, 5) = v_t))
         order by x.id limit 1;
      end if;
    end if;

    update public.attendance x set arrived_at = p_at, arrived_via = p_via
     where x.id = v_id and x.arrived_at is null;
    v_done := found;
    select x.status::text, x.arrived_at into status, arrived_at from public.attendance x where x.id = v_id;
    attendance_id := v_id;
    result := case when v_done then 'arrived' else 'already' end;
    return next;
  end loop;
end;
$$;

-- 164's text, exactly.
create or replace function public.checkin_arrive(p_unit uuid, p_student_ids uuid[], p_via text, p_class jsonb default null)
returns table (student_id uuid, result text, class_id uuid, class_date date, class_time text, class_label text,
               class_audience text, class_legacy_id text, attendance_id uuid, status text, arrived_at timestamptz,
               opens_at text, options jsonb)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from public._checkin(p_unit, p_student_ids, p_via, p_class, now(), true);
end;
$$;

-- 164's text, exactly.
create or replace function public.checkin_preview(p_unit uuid, p_student_ids uuid[], p_class jsonb default null)
returns table (student_id uuid, result text, class_id uuid, class_date date, class_time text, class_label text,
               class_audience text, class_legacy_id text, attendance_id uuid, status text, arrived_at timestamptz,
               opens_at text, options jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from public._checkin(p_unit, p_student_ids, 'app', p_class, now(), false);
end;
$$;

select pg_temp.acl_copy((select acl from acl165 where sig = 'public._checkin(uuid,uuid[],text,jsonb,timestamptz,boolean)'), 'public._checkin(uuid,uuid[],text,jsonb,timestamptz,boolean)');
select pg_temp.acl_copy((select acl from acl165 where sig = 'public.checkin_arrive(uuid,uuid[],text,jsonb)'), 'public.checkin_arrive(uuid,uuid[],text,jsonb)');
select pg_temp.acl_copy((select acl from acl165 where sig = 'public.checkin_preview(uuid,uuid[],jsonb)'), 'public.checkin_preview(uuid,uuid[],jsonb)');

commit;
