-- 65_kids_privacy_hardening.sql

-- 1. Trigger function: silently null photo_url on kids inserts/updates
create or replace function public.block_kids_photo_url()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.prog = 'kids' then
    new.photo_url := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_block_kids_photo on public.students;
create trigger trg_block_kids_photo
  before insert or update on public.students
  for each row
  execute function public.block_kids_photo_url();

-- 2. One-shot: clear any existing photo_url for kids students
update public.students
set photo_url = null
where prog = 'kids' and photo_url is not null;
