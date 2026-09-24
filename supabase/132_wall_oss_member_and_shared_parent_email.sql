-- ============================================================================
-- 132 — Oss anything on the Wall, and stop one child's removal cutting off
--       their sibling's parent
-- ============================================================================
--
-- Two unrelated defects in two functions, both found the same afternoon, both
-- in code that decides who may do what.
--
-- ============================================================================
-- PART ONE — the Wall had three kinds of card and only two could be reacted to
-- ============================================================================
--
-- The Wall shows a promotion, a post, and a welcome card for a new member.
-- _ossControlHtml takes a target type and defaults it to 'promotion'; the
-- welcome card called it with the STUDENT's id and no type. So tapping Oss on
-- a welcome card asked toggle_oss to find a promotion whose id is a student id,
-- which fails with 'target not visible' and a "Couldn't react" toast.
--
-- The member who joined two weeks earlier had a visible Oss button that nobody
-- could use, and nothing on screen said why.
--
-- The owner's rule, once the question was put to him: if it is on the Wall, you
-- can Oss it. No exception the member has to work out for themselves.
--
-- WHY THE POLICY AND NOT ONLY THE FUNCTION
--
-- Adding 'member' to toggle_oss was not enough, and the way it failed is worth
-- recording. The insert succeeded — toggle_oss is SECURITY DEFINER and runs
-- over RLS. The SELECT that hydrates the counts does not: it runs as the member.
--
-- wall_reactions had exactly two SELECT policies, one per type, each proving
-- visibility by joining back to promotions or to posts. Policies are permissive,
-- so a row of a third type matches neither and is simply invisible.
--
-- The symptom was worse than not working: the pill filled on tap and the count
-- was right, because toggle_oss returns its own count and the client writes it
-- straight into state. It was only on the next reload, when the hydrate came
-- back without the row, that the reaction disappeared. It looked like it worked
-- and then quietly lost the member's tap.
--
-- The new policy mirrors toggle_oss's own guard exactly: adult, active, and the
-- caller's unit unless they own units. A child's welcome card stays unreactable
-- from both directions.
--
-- ============================================================================
-- PART TWO — removing one child revoked their parent's access to the others
-- ============================================================================
--
-- whitelist.email is the primary key, so one address is exactly one row.
-- students.parent_email has no such constraint, and the app deliberately models
-- several children per parent.
--
-- deleteStudent removes the student's email AND the parent's from the whitelist.
-- With two children on one address, removing one child took the parent's access
-- to the other with it.
--
-- Not theoretical. 32 families share a parent email today, three of them with
-- three children. And 31 addresses belong to a training adult AND to a parent —
-- people who train and have a kid at the academy — so removing their student
-- record would have cut their access as a parent, and the reverse.
--
-- WHY IT HAD TO BE HERE AND NOT IN THE CLIENT
--
-- The obvious client-side guard, "skip if another student shares this email",
-- depends on the in-memory roster, which is RLS- and unit-filtered. A sibling
-- at the other unit is invisible to it, and the guard would revoke anyway.
--
-- Inside a SECURITY DEFINER function there is no RLS and no unit filter, so the
-- check sees every sibling at every unit. That is the whole reason this is a
-- migration rather than a line of JavaScript.
--
-- ORDERING NOTE
--
-- deleteStudent removes the students row BEFORE calling whitelist_remove, so by
-- the time this check runs the departing student is already gone and only the
-- survivors are counted. That is correct, but it is correct by accident of
-- ordering — do not reorder those two calls without revisiting this.
-- ============================================================================


-- ── Part one ────────────────────────────────────────────────────────────────

create or replace function public.toggle_oss(p_target_type text, p_target_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_ok boolean; v_exist uuid; v_count integer; v_react boolean;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if public.current_status() <> 'approved' then raise exception 'not approved'; end if;
  if public.current_role() not in ('student','instructor') then raise exception 'not allowed'; end if;
  if p_target_type not in ('promotion','post','member') then raise exception 'unsupported target type'; end if;

  if p_target_type = 'promotion' then
    select true into v_ok
    from public.promotions p
    join public.students s on s.id = p.student_id
    where p.id = p_target_id and s.prog = 'adult'
      and ( public.is_unit_owner_any() or s.unit_id = public.current_unit() )
    limit 1;
  elsif p_target_type = 'member' then
    -- A welcome card. Same visibility rule as a promotion: adult only, so a
    -- child is never reactable, and same unit unless the caller owns units.
    select true into v_ok
    from public.students s
    where s.id = p_target_id and s.prog = 'adult' and s.active is true
      and ( public.is_unit_owner_any() or s.unit_id = public.current_unit() )
    limit 1;
  else
    select true into v_ok
    from public.posts po
    where po.id = p_target_id and po.active is true
      and ( public.is_unit_owner_any() or po.unit_id = public.current_unit() )
    limit 1;
  end if;
  if v_ok is not true then raise exception 'target not visible'; end if;

  select id into v_exist from public.wall_reactions
  where target_type = p_target_type and target_id = p_target_id
    and reactor_user_id = v_uid and kind = 'oss';

  if v_exist is not null then
    delete from public.wall_reactions where id = v_exist;
    v_react := false;
  else
    insert into public.wall_reactions(target_type, target_id, reactor_user_id, kind)
    values (p_target_type, p_target_id, v_uid, 'oss');
    v_react := true;
  end if;

  select count(*) into v_count from public.wall_reactions
  where target_type = p_target_type and target_id = p_target_id and kind = 'oss';

  return jsonb_build_object('count', v_count, 'reacted', v_react);
end $function$;

-- Without this the tap works and the reload loses it. See the note above.
drop policy if exists wall_reactions_select_member on public.wall_reactions;
create policy wall_reactions_select_member
on public.wall_reactions
for select
using (
  target_type = 'member'
  and public.current_status() = 'approved'
  and ( public.current_role() = any (array['student','instructor']) or public.is_admin() )
  and exists (
    select 1 from public.students s
    where s.id = wall_reactions.target_id
      and s.prog = 'adult'
      and s.active is true
      and ( public.is_unit_owner_any() or s.unit_id = public.current_unit() )
  )
);


-- ── Part two ────────────────────────────────────────────────────────────────

create or replace function public.whitelist_remove(p_email text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email,'')));
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not (public.is_unit_owner_any() or public.is_staff()) then
    raise exception 'not authorised to remove';
  end if;

  if v_email = '' then
    return;   -- deleting a student with no email is normal
  end if;

  -- Somebody else may still depend on this address. Both columns are checked:
  -- it can belong to a training adult, to a parent, or to one person who is
  -- both. No RLS and no unit filter in here, so every sibling at every unit is
  -- visible — which is the entire reason this check cannot live in the client.
  if exists (
    select 1 from public.students s
    where s.active is true
      and ( lower(coalesce(s.email,'')) = v_email
         or lower(coalesce(s.parent_email,'')) = v_email )
  ) then
    return;
  end if;

  delete from public.whitelist where lower(email) = v_email;
end;
$function$;
