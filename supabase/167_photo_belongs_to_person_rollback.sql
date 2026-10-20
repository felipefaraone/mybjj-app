-- ============================================================================
-- 167 rollback — back to 41's approval sync (subject row + users only)
-- ============================================================================
-- Restores sync_photo_url_on_approval exactly as 41 wrote it and drops
-- _publish_person_photo. The photo paths already written (including the one
-- time fill of empty adult students rows) are left as they are: they are
-- each person's approved photo, and clearing them would lose data.
-- ============================================================================

begin;

do $$
begin
  if position('-- 167' in coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.sync_photo_url_on_approval()')), '')) = 0 then
    raise exception '167 rollback: 167 is not applied; stop';
  end if;
end $$;

-- 41's text, exactly.
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

  if v_user_id is not null then
    update public.users set photo_url = NEW.photo_url where id = v_user_id;
  end if;

  return NEW;
end;
$$;

drop function if exists public._publish_person_photo(uuid, text);

commit;
