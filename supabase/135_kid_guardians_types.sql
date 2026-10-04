-- ============================================================================
-- 135 — kid_guardians: explicit text casts on every returned text column
-- ============================================================================
--
-- WHY
-- 134 is applied in production. Its verify V4 failed at case 8 with
--   ERROR 42804: structure of query does not match function result type
--   DETAIL: Returned type character varying does not match expected type text
--           in column 6.
-- In Supabase auth.users.email is varchar(255). Column 6 (email) was
-- coalesce(au.email, pu.email, gs.email, g.invite_email::text): COALESCE takes
-- the type of its first argument when the others convert to it, so the column
-- came out varchar while RETURNS TABLE declares text. RETURN QUERY checks the
-- column TYPES, not the values, so every call failed — staff and guardian
-- alike, even though a guardian only ever gets NULL in that column. The local
-- harness modelled auth.users.email as text, which is why it never showed.
--
-- WHAT CHANGES
-- Only the casts. Every expression returned in a text column is cast ::text at
-- its SOURCE column, so no column's type depends on argument order or on what
-- Supabase declares in a schema this repo doesn't own:
--   display_name  pu.full_name, gs.full_name, g.guardian_name, g.invite_email
--   status        g.status
--   relationship  g.relationship
--   email         au.email, pu.email, gs.email, g.invite_email
--   origin        g.origin
-- Signature, return table, language, STABLE, SECURITY DEFINER, search_path,
-- authorisation and row logic are 134's, character for character otherwise.
--
-- AUDIT of every other function from 133 and 134 that returns a table or a
-- composite fed from auth.users / public.users / public.students: none
-- mismatched (see the report that came with this file).
--
-- Rollback: 135_kid_guardians_types_rollback.sql (restores 134's body, and
-- with it the bug).
-- ============================================================================

begin;

create or replace function public.kid_guardians(p_student uuid, p_include_closed boolean default false)
returns table (
  id           uuid,
  display_name text,
  status       text,
  is_primary   boolean,
  relationship text,
  email        text,
  origin       text,
  created_at   timestamptz,
  approved_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_staff boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  v_staff := public._guardian_can_manage(p_student);
  if not v_staff and not public.is_guardian_of(p_student, 'view') then
    raise exception 'Only staff or a guardian of this child can see its guardians.';
  end if;

  return query
  select g.id,
         coalesce(nullif(btrim(pu.full_name::text), ''),
                  nullif(btrim(gs.full_name::text), ''),
                  nullif(btrim(g.guardian_name::text), ''),
                  case when v_staff then g.invite_email::text end),
         g.status::text,
         g.is_primary,
         g.relationship::text,
         case when v_staff then coalesce(au.email::text, pu.email::text, gs.email::text, g.invite_email::text) end,
         case when v_staff then g.origin::text end,
         case when v_staff then g.created_at end,
         case when v_staff then g.approved_at end
    from public.guardianships g
    left join public.users pu    on pu.id = g.guardian_user_id
    left join auth.users au      on au.id = g.guardian_user_id
    left join public.students gs on gs.id = g.guardian_student_id
   where g.student_id = p_student
     and (g.status in ('requested','pending','active')
          or (v_staff and coalesce(p_include_closed, false)))
   order by g.is_primary desc,
            case g.status when 'active' then 0 when 'pending' then 1 when 'requested' then 2 else 3 end,
            g.created_at;
end;
$$;

revoke all on function public.kid_guardians(uuid, boolean) from public, anon;
grant execute on function public.kid_guardians(uuid, boolean) to authenticated;

commit;
