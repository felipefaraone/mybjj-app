-- 56_phase8_staff_notes.sql
-- Privacy: move Head Instructor Notes out of staff.feedback (leaked via staff_select=true)
-- into a dedicated owner-only table.

create table if not exists public.staff_notes (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  author_id uuid references public.users(id),
  author_name text,
  text text not null,
  created_at timestamptz not null default now()
);
alter table public.staff_notes enable row level security;

-- owner-only read (matches owner-only write). Flip to "is_admin() or is_staff()" to let instructors read.
drop policy if exists staff_notes_select on public.staff_notes;
create policy staff_notes_select on public.staff_notes
for select to authenticated using (is_admin());

insert into public.staff_notes (staff_id, author_name, text, created_at)
select s.id, 'Prof. Mario',
       'Felipe is showing strong leadership in kids classes. Technically ready — working on the mat presence and teaching consistency before black belt.',
       '2026-02-01T00:00:00Z'::timestamptz
from public.staff s
where s.legacy_id = 'felipe_s'
  and not exists (select 1 from public.staff_notes n where n.staff_id = s.id);

update public.staff set feedback = '[]'::jsonb
where feedback is not null and feedback::text <> '[]';

drop function if exists public.add_staff_note(uuid, text);
drop function if exists public.delete_staff_note(uuid, text);

create function public.add_staff_note(p_staff_id uuid, p_text text)
returns setof public.staff_notes
language plpgsql security definer set search_path to 'public'
as $function$
declare v_author text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_admin() then raise exception 'not authorised: admin only'; end if;
  if p_text is null or btrim(p_text) = '' then raise exception 'empty note'; end if;
  if not exists (select 1 from public.staff where id = p_staff_id) then
    raise exception 'staff % not found', p_staff_id; end if;
  select u.full_name into v_author from public.users u where u.id = auth.uid();
  insert into public.staff_notes (staff_id, author_id, author_name, text)
  values (p_staff_id, auth.uid(), coalesce(nullif(btrim(v_author),''),'Unknown'), p_text);
  return query select * from public.staff_notes where staff_id = p_staff_id order by created_at desc;
end;
$function$;

create function public.delete_staff_note(p_staff_id uuid, p_note_id uuid)
returns setof public.staff_notes
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_admin() then raise exception 'not authorised: admin only'; end if;
  delete from public.staff_notes where id = p_note_id and staff_id = p_staff_id;
  return query select * from public.staff_notes where staff_id = p_staff_id order by created_at desc;
end;
$function$;

grant execute on function public.add_staff_note(uuid, text) to authenticated;
grant execute on function public.delete_staff_note(uuid, uuid) to authenticated;
