-- 60_phase8_relink_trigger.sql
-- Belt-and-suspenders re-link: fire on every public.users INSERT so an
-- orphan kid (parent_email pointing at an email that didn't have a
-- public.users row yet) gets parent_user_id stitched the moment its
-- parent's row is born, regardless of which path created the row
-- (claim_profile branches, an admin-managed insert, a future
-- handle_new_user trigger, anything).
--
-- claim_profile's existing branch-level re-links (migration 28 + the
-- else-branch addition in migration 59) remain — harmless, idempotent.
-- This trigger is the guarantee.
--
-- FK note: students.parent_user_id REFERENCES public.users(id). The
-- AFTER INSERT trigger fires once NEW.id is committed to public.users,
-- so the UPDATE here can't FK-violate.

create or replace function public.relink_orphan_kids_on_user_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and (lower(parent_email)  = lower(new.email)
          or lower(parent2_email) = lower(new.email));
  return new;
end;
$$;

drop trigger if exists trg_relink_orphan_kids on public.users;

create trigger trg_relink_orphan_kids
  after insert on public.users
  for each row
  execute function public.relink_orphan_kids_on_user_insert();
