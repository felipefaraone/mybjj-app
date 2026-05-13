-- =============================================================================
-- myBJJ V1 — Phase 7.5 nickname self-edit
-- Run AFTER 16_phase7_5_cleanup.sql. Safe to re-run.
--
-- Adds nickname columns to staff and users (students already has one), a
-- 40-char length check on all three, and a SECURITY DEFINER RPC that lets
-- any authenticated user set their own nickname (or, for parents, their
-- child's nickname) without widening the table's write RLS.
--
-- Why RPC and not "self-update on staff/users with column restriction":
--   A self-update RLS policy on public.staff (USING user_id = auth.uid())
--   would let a coach issue UPDATE staff SET belt='black' WHERE user_id=...
--   via the PostgREST API. RLS can't restrict by column; a trigger could,
--   but would also break the existing edit_staff_self RPC unless it sets
--   a bypass flag. An RPC scoped to the single nickname column is simpler
--   and matches the precedent set by edit_staff_self / edit_staff_admin.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.staff add column if not exists nickname text;
alter table public.users add column if not exists nickname text;
-- students.nickname already exists (seeded earlier in Phase 7).

-- ---------------------------------------------------------------------------
-- 2. Length constraints (max 40 chars; null/empty allowed)
-- ---------------------------------------------------------------------------
alter table public.staff    drop constraint if exists staff_nickname_len;
alter table public.staff    add  constraint staff_nickname_len
  check (nickname is null or char_length(nickname) <= 40);

alter table public.users    drop constraint if exists users_nickname_len;
alter table public.users    add  constraint users_nickname_len
  check (nickname is null or char_length(nickname) <= 40);

alter table public.students drop constraint if exists students_nickname_len;
alter table public.students add  constraint students_nickname_len
  check (nickname is null or char_length(nickname) <= 40);

-- ---------------------------------------------------------------------------
-- 3. RPC: set_my_nickname
--    - p_nickname is trimmed; empty string -> NULL (clears the field).
--    - p_child_legacy_id is optional. When set, the function updates that
--      student row only if its parent_user_id matches the caller. This is
--      how the Side Panel "Edit profile" wires up the parent role.
--    - When p_child_legacy_id is NULL, the function locates the caller's
--      own row by trying students.user_id -> staff.user_id -> users.id
--      in that order. The first match wins.
-- ---------------------------------------------------------------------------
create or replace function public.set_my_nickname(
  p_nickname        text,
  p_child_legacy_id text default null
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_nick text;
  v_n    int;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_nick := nullif(btrim(coalesce(p_nickname, '')), '');
  if v_nick is not null and char_length(v_nick) > 40 then
    raise exception 'nickname too long (max 40 characters)';
  end if;

  -- Parent editing child's nickname
  if p_child_legacy_id is not null then
    update public.students
       set nickname = v_nick
     where legacy_id = p_child_legacy_id
       and parent_user_id = v_uid;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'not authorised: % is not your child', p_child_legacy_id;
    end if;
    return coalesce(v_nick, '');
  end if;

  -- Self update: try each linked-row table in turn
  update public.students set nickname = v_nick where user_id = v_uid;
  get diagnostics v_n = row_count;
  if v_n > 0 then return coalesce(v_nick, ''); end if;

  update public.staff    set nickname = v_nick where user_id = v_uid;
  get diagnostics v_n = row_count;
  if v_n > 0 then return coalesce(v_nick, ''); end if;

  update public.users    set nickname = v_nick where id      = v_uid;
  get diagnostics v_n = row_count;
  if v_n > 0 then return coalesce(v_nick, ''); end if;

  raise exception 'no profile row found for current user';
end;
$$;

grant execute on function public.set_my_nickname(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Verification (uncomment in SQL Editor to inspect)
-- ---------------------------------------------------------------------------
-- select column_name from information_schema.columns
--  where table_schema='public' and table_name in ('staff','users','students')
--    and column_name='nickname';
-- select proname, prosrc is not null as has_body
--   from pg_proc where proname='set_my_nickname';
