-- ============================================================================
-- 167 — A photo belongs to the person
-- ============================================================================
--
-- Brian is staff and also has a students row (same user_id). He uploaded his
-- photo from his staff profile: the approval wrote staff.photo_url and
-- users.photo_url, students.photo_url stayed null, and every student surface
-- (class list, Add student, Leaderboard, People, TV) reads students.photo_url,
-- so others saw his initials.
--
-- The publish already runs in one place, the trigger trg_photo_approval_sync
-- (41: on photo_approvals' pending -> approved edge, staff auto-approval
-- included). 167 keeps its subject routing exactly and replaces its last step
-- (users only) with _publish_person_photo(user, path): the users row, every
-- staff row and every adult students row (prog not kids) of that login. Kids
-- rows are never written (the kids photo trigger nulls them anyway); a
-- guardian's upload for a kid stays as it was (the kid has no login).
--
-- Rejection (reject_photo) never touches a published photo_url: unchanged.
-- remove_photo lives outside the repo's migrations; 167 does not change it.
--
-- A one time fill: an adult students row whose own photo is empty takes the
-- photo its user already has published (users.photo_url, an approved photo).
-- Only empty rows are filled; nothing is overwritten.
--
-- Rollback: 167_photo_belongs_to_person_rollback.sql (41's trigger function
-- exactly). Checks: 167_photo_belongs_to_person_verify.sql.
-- ============================================================================

begin;

do $$
declare
  v_bad text;
begin
  if to_regprocedure('public.sync_photo_url_on_approval()') is null then
    raise exception '167 preflight: sync_photo_url_on_approval (41) not found';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.sync_photo_url_on_approval()'::regprocedure)) <> 'bcd3e44ac7d947c1587f721c46da9fff'
     and position('-- 167' in (select prosrc from pg_proc where oid = 'public.sync_photo_url_on_approval()'::regprocedure)) = 0 then
    raise exception '167 preflight: sync_photo_url_on_approval is not 41''s text; stop and compare';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_photo_approval_sync' and tgrelid = 'public.photo_approvals'::regclass) then
    raise exception '167 preflight: trigger trg_photo_approval_sync is missing';
  end if;
  select string_agg(x.t || '.' || x.c, ', ') into v_bad
    from (values ('users', 'photo_url'), ('staff', 'user_id'), ('staff', 'photo_url'),
                 ('students', 'user_id'), ('students', 'photo_url'), ('students', 'prog'),
                 ('photo_approvals', 'user_id'), ('photo_approvals', 'student_id'), ('photo_approvals', 'staff_id'),
                 ('photo_approvals', 'photo_url'), ('photo_approvals', 'status')) x(t, c)
   where not exists (select 1 from information_schema.columns i
                      where i.table_schema = 'public' and i.table_name = x.t and i.column_name = x.c);
  if v_bad is not null then
    raise exception '167 preflight: missing columns: %', v_bad;
  end if;
end $$;

create or replace function public._publish_person_photo(p_user uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 167: one place for "this person's photo is now p_path"
  if p_user is null or p_path is null or p_path = '' then
    return;
  end if;
  update public.users    set photo_url = p_path where id = p_user and photo_url is distinct from p_path;
  update public.staff    set photo_url = p_path where user_id = p_user and photo_url is distinct from p_path;
  update public.students set photo_url = p_path
   where user_id = p_user and prog is distinct from 'kids' and photo_url is distinct from p_path;
end;
$$;

revoke all on function public._publish_person_photo(uuid, text) from public, anon, authenticated;

-- 41's text; 167 changes marked.
create or replace function public.sync_photo_url_on_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  -- Fire only on the pending → approved edge. A re-update that leaves
  -- status='approved' (e.g. someone touching approved_at) must not
  -- re-trigger the cascade, otherwise an admin "undo" path that later
  -- nulls a photo_url could re-overwrite the source-of-truth tables.
  if NEW.status <> 'approved' then return NEW; end if;
  if OLD.status = 'approved' then return NEW; end if;
  if NEW.photo_url is null or NEW.photo_url = '' then return NEW; end if;

  -- Subject routing. photo_approvals rows have exactly one subject:
  -- student_id, staff_id, or neither (user-self upload — dev admin or
  -- any auth user without a staff/student linkage). The trigger mirrors
  -- onto the subject table AND resolves the linked auth user to mirror
  -- onto public.users.
  if NEW.student_id is not null then
    update public.students set photo_url = NEW.photo_url where id = NEW.student_id;
    select user_id into v_user_id from public.students where id = NEW.student_id;
  elsif NEW.staff_id is not null then
    update public.staff set photo_url = NEW.photo_url where id = NEW.staff_id;
    select user_id into v_user_id from public.staff where id = NEW.staff_id;
  else
    v_user_id := NEW.user_id;
  end if;

  -- 167: the photo is the person's: the users row, every staff row and every
  -- adult students row of that login (kids rows never; their trigger nulls them)
  if v_user_id is not null then
    perform public._publish_person_photo(v_user_id, NEW.photo_url);
  end if;

  return NEW;
end;
$$;

-- The one time fill (only empty adult students rows; an approved photo only)
do $$
declare n int;
begin
  update public.students s
     set photo_url = u.photo_url
    from public.users u
   where s.user_id = u.id
     and s.prog is distinct from 'kids'
     and coalesce(s.photo_url, '') = ''
     and coalesce(u.photo_url, '') <> ''
     and exists (select 1 from public.photo_approvals a where a.photo_url = u.photo_url and a.status = 'approved');
  get diagnostics n = row_count;
  raise notice '167: % adult students row(s) took their person''s published photo', n;
end $$;

commit;
