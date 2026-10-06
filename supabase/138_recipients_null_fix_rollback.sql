-- 138_recipients_null_fix_rollback.sql
--
-- Restores email_recipients_for_student exactly as 137 created it.
-- WARNING: this brings the bug back — every guardian of a kid with no email of
-- their own is dropped again (and a student with a NULL prog whose address is
-- their own email). Run only if 138 itself has to come out.

begin;

create or replace function public.email_recipients_for_student(p_student uuid, p_kind text)
returns table (email text, display_name text, is_guardian boolean)
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select st.id, st.prog::text as prog, st.user_id,
           nullif(lower(btrim(st.email::text)), '') as own_email,
           coalesce(nullif(btrim(st.first_name::text), ''), split_part(btrim(coalesce(st.full_name::text, '')), ' ', 1)) as first_name
      from public.students st
     where st.id = p_student
  ),
  cand as (
    -- Adult: their own address, else the linked account's.
    select nullif(lower(btrim(coalesce(s.own_email, pu.email::text, au.email::text))), '') as email,
           nullif(s.first_name, '') as display_name,
           false as is_guardian
      from s
      left join public.users pu on pu.id = s.user_id
      left join auth.users au   on au.id = s.user_id
     where coalesce(s.prog, 'adult') <> 'kids'
    union all
    -- Kid: guardians only. Active -> the account's address; pending -> the invite.
    select nullif(lower(btrim(case when g.status = 'active'
                                   then coalesce(au.email::text, pu.email::text)
                                   else g.invite_email::text end)), '') as email,
           coalesce(nullif(btrim(pu.full_name::text), ''),
                    nullif(btrim(gs.full_name::text), ''),
                    nullif(btrim(g.guardian_name::text), '')) as display_name,
           true as is_guardian
      from s
      join public.guardianships g   on g.student_id = s.id and g.status in ('active','pending')
      left join auth.users au       on au.id = g.guardian_user_id
      left join public.users pu     on pu.id = g.guardian_user_id
      left join public.students gs  on gs.id = g.guardian_student_id
     where s.prog = 'kids'
  )
  select distinct on (c.email)
         c.email::text, c.display_name::text, c.is_guardian
    from cand c, s
   where c.email is not null
     -- never the kid's own address for a kid
     and not (s.prog = 'kids' and c.email = s.own_email)
     and not exists (select 1 from public.email_optouts o
                      where lower(o.email::text) = c.email
                        and o.kind in ('all', p_kind))
   order by c.email, (c.display_name is null), c.display_name
$$;

revoke all on function public.email_recipients_for_student(uuid, text) from public, anon, authenticated;
grant execute on function public.email_recipients_for_student(uuid, text) to service_role;

commit;
