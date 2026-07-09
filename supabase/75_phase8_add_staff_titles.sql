-- 75_phase8_add_staff_titles.sql
-- Staff titles for the ADD-staff flow. add_staff_member (migration 39)
-- hardcoded role_title='Professor', rejected any p_role except 'professor',
-- required a valid belt, and took no first/last name. This widens it to the
-- four supported titles (Professor / Coach / Head Professor / Admin — written
-- VERBATIM to role_title), makes the belt optional when the title is Admin
-- (non-teaching staff have no BJJ belt), and stores first_name / last_name
-- (deriving full_name from them when supplied). Matches the edit-staff title
-- set added in the frontend (commit 48b7380). role_title stays free text.
--
-- Frontend (rAddStaffModal / saveAddStaff) is updated in the same change.
-- Idempotent: drops the prior signatures, create-or-replace, DROP NOT NULL on
-- staff.belt is a no-op if the column is already nullable.

-- Admin staff can have no belt.
alter table public.staff alter column belt drop not null;

-- Retire the older signatures so the new 9-arg overload is unambiguous.
drop function if exists public.add_staff_member(text, text, text, int, text, text);
drop function if exists public.add_staff_member(text, text, text, int, text, text, text);

create or replace function public.add_staff_member(
  p_full_name      text,
  p_email          text,
  p_belt           text,
  p_degree         int,
  p_unit_legacy_id text,
  p_initials       text,
  p_role           text default 'Professor',
  p_first_name     text default null,
  p_last_name      text default null
) returns public.staff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit_id uuid;
  v_legacy  text;
  v_base    text;
  v_n       int := 1;
  v_row     public.staff;
  v_title   text := trim(coalesce(p_role, ''));
  v_belt    text := nullif(trim(lower(coalesce(p_belt, ''))), '');
  v_first   text := nullif(trim(coalesce(p_first_name, '')), '');
  v_last    text := nullif(trim(coalesce(p_last_name, '')), '');
  v_full    text := trim(coalesce(p_full_name, ''));
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_unit_owner_any() then
    raise exception 'not authorised: owner only';
  end if;

  -- Title — one of the four supported values, written verbatim to role_title.
  if v_title not in ('Professor', 'Coach', 'Head Professor', 'Admin') then
    raise exception 'invalid role: %', p_role;
  end if;

  -- Name — prefer first/last; fall back to p_full_name. full_name is always
  -- the trimmed "first last" when parts are supplied.
  if v_first is not null or v_last is not null then
    v_full := trim(concat_ws(' ', v_first, v_last));
  end if;
  if v_full = '' then
    raise exception 'full_name required';
  end if;

  if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format';
  end if;

  -- Belt — required for teaching titles; optional (may be blank) for Admin.
  if v_title = 'Admin' then
    if v_belt is not null and v_belt not in ('white','blue','purple','brown','black') then
      raise exception 'invalid belt';
    end if;
  else
    if v_belt is null or v_belt not in ('white','blue','purple','brown','black') then
      raise exception 'invalid belt';
    end if;
  end if;

  if p_degree is null or p_degree < 0 or p_degree > 6 then
    raise exception 'invalid degree';
  end if;

  select id into v_unit_id from public.units where legacy_id = p_unit_legacy_id;
  if v_unit_id is null then
    raise exception 'unit % not found', p_unit_legacy_id;
  end if;

  v_base := lower(regexp_replace(v_full, '[^a-zA-Z0-9]+', '_', 'g'));
  v_base := trim(both '_' from v_base);
  if v_base = '' then v_base := 'staff'; end if;
  v_legacy := v_base || '_s';
  while exists (select 1 from public.staff where legacy_id = v_legacy) loop
    v_n := v_n + 1;
    v_legacy := v_base || '_s' || v_n;
  end loop;

  insert into public.staff (
    legacy_id, full_name, first_name, last_name, email, belt, degree,
    role_title, initials, unit_id, total_classes, journey, feedback, active
  ) values (
    v_legacy,
    v_full,
    v_first,
    v_last,
    lower(p_email),
    v_belt,
    p_degree,
    v_title,
    coalesce(nullif(trim(p_initials), ''),
             upper(substring(regexp_replace(v_full,'[^a-zA-Z]','','g') from 1 for 2))),
    v_unit_id,
    0,
    '[]'::jsonb,
    '[]'::jsonb,
    true
  )
  returning * into v_row;

  insert into public.whitelist (email, role, unit_id, invited_by, invited_at)
  values (lower(p_email), 'instructor', v_unit_id, auth.uid(), now())
  on conflict (email) do update set
    role       = 'instructor',
    unit_id    = excluded.unit_id,
    invited_by = excluded.invited_by;

  return v_row;
end;
$$;

grant execute on function public.add_staff_member(text,text,text,int,text,text,text,text,text) to authenticated;
