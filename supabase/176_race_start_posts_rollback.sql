-- 176_race_start_posts_rollback.sql
--
-- Undoes 176: unschedules 'race-start-posts', restores toggle_oss exactly as it
-- was live before 176 (pg_get_functiondef, 28 Oct 2026, body md5 0b4a0f1bd53f0c75d680eb83690e1051 =
-- 172's text; CREATE OR REPLACE, owner/grants/security/search_path checked),
-- drops the 'race_start' read policy, 176's functions and its two tables (the
-- posts and the lines: nothing else references them).
-- KEPT on purpose: any Oss rows of type 'race_start' in wall_reactions
-- (unreadable without the policy). Delete by hand if wanted.
-- Run on its own (never pasted together with the migration):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/176_race_start_posts_rollback.sql

begin;

do $$
begin
  if md5(coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.toggle_oss(text, uuid)')), '')) not in ('0b4a0f1bd53f0c75d680eb83690e1051', '797d7bf7673a92239b40cfb963bbc894') then
    raise exception '176 rollback preflight: toggle_oss is neither 176''s text nor the one before it; stop and compare';
  end if;
end $$;

do $$
begin
  if to_regnamespace('cron') is not null and exists (select 1 from cron.job where jobname = 'race-start-posts') then
    perform cron.unschedule('race-start-posts');
  end if;
end $$;

create temp table acl176r on commit drop as
  select p.proowner, p.proacl::text as acl, p.prosecdef, p.provolatile, p.proconfig::text as cfg
    from pg_proc p where p.oid = to_regprocedure('public.toggle_oss(text, uuid)');

drop policy if exists wall_reactions_select_race_start on public.wall_reactions;

-- toggle_oss before 176 (172's)
CREATE OR REPLACE FUNCTION public.toggle_oss(p_target_type text, p_target_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_ok boolean; v_exist uuid; v_count integer; v_react boolean;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if public.current_status() <> 'approved' then raise exception 'not approved'; end if;
  if public.current_role() not in ('student','instructor') then raise exception 'not allowed'; end if;
  if p_target_type not in ('promotion','post','member','champions','month_champions') then raise exception 'unsupported target type'; end if;

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
  elsif p_target_type = 'champions' then
    -- 161: a Cup champions card (target = the adult division). Adults only, a
    -- published event, same unit unless the caller owns units.
    select true into v_ok
    from public.competition_divisions d
    join public.competitions c on c.id = d.competition_id
    where d.id = p_target_id and d.audience = 'adult'
      and c.kind = 'event' and c.published_at is not null
      and ( public.is_unit_owner_any() or d.unit_id = public.current_unit() )
    limit 1;
  elsif p_target_type = 'month_champions' then
    -- 172: a Monthly race champions card (target = _month_champions_target of
    -- the adult division and the month). Adults only, a published month, same
    -- unit unless the caller owns units.
    v_ok := public._month_champions_visible(p_target_id);
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

drop function if exists public.competition_start_posts_feed();
drop function if exists public._race_start_visible(uuid);
drop function if exists public._competition_start_post_day(timestamptz);
drop function if exists public._competition_start_post_due(date);
drop table if exists public.competition_start_posts;
drop table if exists public.competition_start_lines;

do $$
begin
  if md5((select prosrc from pg_proc where oid = to_regprocedure('public.toggle_oss(text, uuid)'))) <> '0b4a0f1bd53f0c75d680eb83690e1051' then
    raise exception '176 rollback: toggle_oss body is not the pre-176 text';
  end if;
  if not exists (select 1 from pg_proc p, acl176r a
                  where p.oid = to_regprocedure('public.toggle_oss(text, uuid)')
                    and p.proowner = a.proowner and p.proacl::text is not distinct from a.acl
                    and p.prosecdef = a.prosecdef and p.provolatile = a.provolatile
                    and p.proconfig::text is not distinct from a.cfg) then
    raise exception '176 rollback: owner, grants, security or search_path of toggle_oss changed';
  end if;
end $$;

commit;
