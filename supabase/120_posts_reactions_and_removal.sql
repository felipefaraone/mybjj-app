-- 120_posts_reactions_and_removal.sql
-- 5 September 2026
--
-- PURPOSE
-- The two server-side pieces public.posts needs to work, applied directly in the
-- SQL Editor:
--   - RPC    public.toggle_oss              <-- extended to accept 'post'
--   - policy public.wall_reactions_select_post
--   - RPC    public.set_post_active         <-- new
--
-- Captured EXACTLY as they run in production (see the note in migration 109).
-- Depends on migration 119 (public.posts).
--
-- toggle_oss: WHY IT WAS ALREADY ALMOST RIGHT
-- wall_reactions was built polymorphic from the start — target_type + target_id,
-- no foreign key — so reactions on posts needed no schema change at all. The RPC
-- had a hard guard `if p_target_type <> 'promotion' then raise`; that guard now
-- admits 'post' and each branch checks visibility against its own table. The
-- promotion branch is byte-identical to what migration 109 captured.
--
-- wall_reactions_select_post: A SECOND POLICY, NOT AN EDIT
-- The existing wall_reactions_select is scoped to target_type='promotion'. Rather
-- than widen it, this adds a sibling for posts. Multiple permissive policies are
-- OR-ed by Postgres, so the promotion path is untouched and stays reviewable on
-- its own.
--
-- set_post_active: WHY REMOVAL CANNOT BE A PLAIN UPDATE
-- posts_select requires active IS TRUE, and Postgres applies a SELECT policy as
-- an implicit WITH CHECK on the row an UPDATE produces. Setting active=false is
-- therefore the one update that can never satisfy the policy: a direct PATCH
-- returns 42501 "new row violates row-level security policy" even for the post's
-- own author. Reproduced in production by an owner removing his own post.
--
-- SECURITY DEFINER is not a loosening here — the function re-checks everything
-- the policy would have: authenticated, approved, staff, and author-or-owner.
-- It bypasses the visibility rule only because the visibility rule is what makes
-- the operation impossible.

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
  if p_target_type not in ('promotion','post') then raise exception 'unsupported target type'; end if;

  if p_target_type = 'promotion' then
    select true into v_ok
    from public.promotions p
    join public.students s on s.id = p.student_id
    where p.id = p_target_id and s.prog = 'adult'
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

drop policy if exists wall_reactions_select_post on public.wall_reactions;
create policy wall_reactions_select_post on public.wall_reactions
for select using (
  (target_type = 'post')
  and (public.current_status() = 'approved')
  and ((public."current_role"() = any (array['student','instructor'])) or public.is_admin())
  and (exists (
    select 1 from public.posts po
    where po.id = wall_reactions.target_id
      and po.active is true
      and (public.is_unit_owner_any() or (po.unit_id = public.current_unit()))
  ))
);

create or replace function public.set_post_active(p_id uuid, p_active boolean)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_po public.posts;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if public.current_status() <> 'approved' then raise exception 'not approved'; end if;
  if not public.is_staff() then raise exception 'not allowed'; end if;

  select * into v_po from public.posts where id = p_id;
  if v_po.id is null then raise exception 'post not found'; end if;

  if not ( v_po.author_user_id = v_uid or public.is_unit_owner_any() ) then
    raise exception 'not allowed';
  end if;

  update public.posts set active = p_active where id = p_id;
  return true;
end $function$;
