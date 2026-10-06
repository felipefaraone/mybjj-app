-- ============================================================================
-- 138 — email_recipients_for_student: NULL-safe "never the kid's own email"
-- ============================================================================
--
-- WHY
-- 137's final filter was
--     and not (s.prog = 'kids' and c.email = s.own_email)
-- For a kid with NO email of their own, c.email = NULL is NULL, so the AND is
-- NULL, NOT NULL is NULL, and the WHERE drops the row: every guardian of every
-- kid without an own email was filtered out. Production dry run (2026-09):
-- 229 of 404 eligible students without a recipient = 6 adults with no email +
-- 221 kids with no own email (ALL their guardians lost) + 2 kids with no live
-- guardian. 137's V4 case 4 and the harness only used a kid WITH an own email.
--
-- WHAT CHANGES (that predicate only)
--     and not (coalesce(s.prog, 'adult') = 'kids' and c.email is not distinct from s.own_email)
--  - IS NOT DISTINCT FROM: an own email of NULL never matches a guardian's address.
--  - coalesce(s.prog, 'adult'): students.prog is nullable (08 set a default, never
--    NOT NULL). The adult branch above already treats a NULL prog as adult; the
--    bare `s.prog = 'kids'` made the filter NULL for such a student whenever their
--    address equalled own_email — the normal adult case — and dropped them too.
--    Same rule as the adult branch, so the two can't disagree.
-- Signature, return table, SECURITY DEFINER, STABLE, search_path and every other
-- line are 137's. Grants re-asserted as 137 set them.
--
-- Rollback: 138_recipients_null_fix_rollback.sql (restores 137's body, and the bug).
-- Checks: 138_recipients_null_fix_verify.sql.
-- ============================================================================

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
     and not (coalesce(s.prog, 'adult') = 'kids' and c.email is not distinct from s.own_email)
     and not exists (select 1 from public.email_optouts o
                      where lower(o.email::text) = c.email
                        and o.kind in ('all', p_kind))
   order by c.email, (c.display_name is null), c.display_name
$$;

revoke all on function public.email_recipients_for_student(uuid, text) from public, anon, authenticated;
grant execute on function public.email_recipients_for_student(uuid, text) to service_role;

commit;
