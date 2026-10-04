-- 135_kid_guardians_types_rollback.sql
--
-- Restores kid_guardians exactly as 134 applied it.
-- WARNING: this brings the bug back. With auth.users.email being varchar(255)
-- in Supabase, every STAFF call fails with
--   42804 structure of query does not match function result type
--   (character varying vs text, column 6).
-- Only run it if 135 itself has to come out.

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
         coalesce(nullif(btrim(pu.full_name), ''),
                  nullif(btrim(gs.full_name), ''),
                  nullif(btrim(g.guardian_name), ''),
                  case when v_staff then g.invite_email::text end),
         g.status,
         g.is_primary,
         g.relationship,
         case when v_staff then coalesce(au.email, pu.email, gs.email, g.invite_email::text) end,
         case when v_staff then g.origin end,
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
