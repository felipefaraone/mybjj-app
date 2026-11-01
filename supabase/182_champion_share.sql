-- ============================================================================
-- 182 — champion share card
-- ============================================================================
-- An adult podium winner of a closed month (place 1-3 in an adult division)
-- can share a "champion card" image from the app. Three parts:
--
-- 1. public.my_month_title_share(p_competition uuid, p_month date): NEW, the one
--    read RPC the card needs. Returns only the CALLER's own adult podium row(s)
--    of that competition's closed month: the caller is auth.uid()'s students
--    row (students.user_id, the key; never by email). Rows come from the
--    frozen competition_results of a published close (competition_month_closes),
--    the same filters as the close's notifications (points > 0, prize_rank 1-3,
--    prize_eligible), audience 'adult' and payload minor false: a kid / minor
--    row is never returned, to anyone (a parent gets nothing). classes is the
--    frozen payload's classes_count (_competition_ranked's own count).
--    Approved users only (else empty). SECURITY DEFINER, search_path public,
--    execute for authenticated only.
--
-- 2. public.monthly_close(date): the notification copy only. A winner's own
--    notification (not a guardian's) for an ADULT, non-minor row now ends
--    "You finished 1st in October at Neutral Bay. Your champion card is ready to
--    share." instead of "You're on the October champions card on the Wall.".
--    Guardian and kids notifications, the record-first idempotency, the frozen
--    rows and everything else: unchanged. The rest of the body is the live
--    definition (pg_get_functiondef, 2 Nov 2026, body md5
--    9c30d2c53b7d09f30380225597d102f3), copied exactly. New body md5 c0bb9c3000385b6668e84eab4e6844d3.
--    Owner, grants, SECURITY DEFINER and search_path are checked unchanged below.
--
-- 3. One-time backfill for October 2026 (competition
--    3d66c81b-6f7e-456c-9077-403067db093f, published 1 Nov 2026): one
--    notification "Your October champion card is ready to share" per adult
--    podium winner's own account (6 expected: Neutral Bay Alison Lee, David
--    Wood, Adriano Martins Pinto; Camperdown Melina Bilota, Brian Luhr, George
--    Hatzi), to the winner's own account only (never a guardian). type and
--    related_entity_type 'competition_result' (the only ones notifications'
--    checks allow; the app opens the Leaderboard, the same place as the result
--    notification), related_entity_id the result row, metadata share: true.
--    The stable key is (user, result row, share): a not-exists on it (dismissed
--    rows included) guards the insert, so a second run inserts 0. Inserted
--    directly, not through create_notification, whose dedupe would match the
--    1 Nov result notification on the same row and insert nothing; its
--    preference check (user_wants_notification_type) is kept. A winner
--    without an account is skipped and counted in the NOTICE.
--
-- Rollback: 182_champion_share_rollback.sql. Checks: 182_champion_share_verify.sql.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/182_champion_share.sql
-- ============================================================================

begin;

do $$
begin
  if md5(coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.monthly_close(date)')), ''))
     not in ('9c30d2c53b7d09f30380225597d102f3', 'c0bb9c3000385b6668e84eab4e6844d3') then
    raise exception '182 preflight: monthly_close is not the text this migration was built from; stop and compare';
  end if;
end $$;

create temp table acl182 on commit drop as
  select p.proowner, p.proacl::text as acl, p.prosecdef, p.provolatile, p.proconfig::text as cfg
    from pg_proc p where p.oid = to_regprocedure('public.monthly_close(date)');

-- 1. the card's read RPC -----------------------------------------------------
create or replace function public.my_month_title_share(p_competition uuid, p_month date)
returns table (
  competition_id uuid, period_from date, title_month text, place integer, display_name text,
  belt text, degree integer, photo_url text, unit_id uuid, unit_name text, classes integer,
  division_label text
)
language sql
stable
security definer
set search_path = public
as $$
  select m.competition_id, m.period_from, to_char(m.period_from, 'FMMonth')::text,
         cr.prize_rank,
         (cr.payload ->> 'display_name')::text,
         (cr.payload ->> 'belt')::text,
         (cr.payload ->> 'degree')::integer,
         (cr.payload ->> 'photo_url')::text,
         (cr.payload ->> 'unit_id')::uuid,
         u.name::text,
         (cr.payload ->> 'classes_count')::integer,
         (cr.payload ->> 'division_label')::text
    from public.competition_month_closes m
    join public.competitions x on x.id = m.competition_id and x.kind = 'monthly' and x.status <> 'draft'
    join public.competition_results cr
      on cr.competition_id = m.competition_id and cr.period_from = m.period_from and cr.period_to = m.period_to
    join public.students s on s.id = cr.student_id and s.user_id = auth.uid()       -- the caller's own row only
    left join public.units u on u.id = (cr.payload ->> 'unit_id')::uuid
   where m.competition_id = p_competition
     and m.period_from = date_trunc('month', p_month)::date
     and coalesce(public.current_status(), '') = 'approved'
     and cr.points > 0
     and cr.prize_rank between 1 and 3
     and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
     and cr.payload ->> 'audience' = 'adult'
     and not coalesce((cr.payload ->> 'minor')::boolean, false)                     -- never a kid / minor
   order by cr.prize_rank, u.name;
$$;

revoke all on function public.my_month_title_share(uuid, date) from public, anon;
grant execute on function public.my_month_title_share(uuid, date) to authenticated;

-- 2. monthly_close: the adult podium copy ------------------------------------
CREATE OR REPLACE FUNCTION public.monthly_close(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from  date;
  v_to    date;
  v_mon   text;
  v_out   jsonb := '[]'::jsonb;
  v_rows  integer;
  v_sent  integer;
  c       record;
  r       record;
  rc      record;
  v_first text;
  v_pts   text;
  v_title text;
  v_body  text;
begin
  if p_month is null then
    raise exception 'p_month is required' using errcode = 'invalid_parameter_value';
  end if;
  v_from := date_trunc('month', p_month)::date;
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;
  if v_to >= (now() at time zone 'Australia/Sydney')::date then
    raise exception 'the month % has not ended yet', to_char(v_from, 'YYYY-MM') using errcode = 'invalid_parameter_value';
  end if;
  v_mon := to_char(v_from, 'FMMonth');

  for c in select x.id, x.name::text as name from public.competitions x
            where x.kind = 'monthly' and x.status = 'active' order by x.created_at, x.id loop
    -- the record first: a second call (or a concurrent one, which waits on the
    -- key) inserts nothing and stops here
    insert into public.competition_month_closes (competition_id, period_from, period_to)
      values (c.id, v_from, v_to)
      on conflict (competition_id, period_from) do nothing;
    if not found then
      raise notice 'monthly_close: % % is already published, nothing done', c.name, to_char(v_from, 'YYYY-MM');
      v_out := v_out || jsonb_build_object('competition_id', c.id, 'month', v_from, 'already_published', true);
      continue;
    end if;

    -- the frozen month: the board's ranking (163's _competition_ranked), 161's payload
    delete from public.competition_results
     where competition_id = c.id and period_from = v_from and period_to = v_to;
    insert into public.competition_results
      (competition_id, period_from, period_to, division_id, student_id, points, rank, prize_rank, payload, finalized_at, finalized_by)
    select c.id, v_from, v_to, x.division_id, x.student_id, x.points, x.rank, x.prize_rank,
           jsonb_build_object(
             'display_name', x.display_name, 'audience', x.audience, 'unit_id', x.unit_id,
             'division_label', d.label, 'places', 3, 'kind', 'monthly',
             'photo_url', x.photo_url, 'belt', x.belt, 'degree', x.degree, 'minor', x.minor,
             'class_points', x.class_points, 'gi_points', x.gi_points, 'nogi_points', x.nogi_points,
             'award_points', x.award_points, 'referral_points', x.referral_points,
             'checkin_points', x.checkin_points,
             'classes_count', x.classes_count, 'last_scored_on', x.last_scored_on,
             'prize_eligible', x.prize_eligible, 'leaderboard_hidden', x.leaderboard_hidden),
           now(), auth.uid()
      from public._competition_ranked(c.id, v_from, v_to) x
      join public.competition_divisions d on d.id = x.division_id;
    get diagnostics v_rows = row_count;

    -- the top 3 of every division (adults and kids; a kid's to the guardians,
    -- 154's routing). Staff have no prize_rank. Never blocks the close (154 /
    -- 161's guard).
    v_sent := 0;
    begin
      for r in
        select cr.id, cr.student_id, cr.points, cr.prize_rank,
               cr.payload ->> 'division_label' as label,
               coalesce((cr.payload ->> 'leaderboard_hidden')::boolean, false) as hidden,
               cr.payload ->> 'audience' as audience,
               coalesce((cr.payload ->> 'minor')::boolean, false) as minor,                   -- 182
               (select u.name::text from public.units u where u.id = (cr.payload ->> 'unit_id')::uuid) as unit_name
          from public.competition_results cr
         where cr.competition_id = c.id and cr.period_from = v_from and cr.period_to = v_to
           and cr.points > 0 and cr.prize_rank is not null and cr.prize_rank <= 3
           and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
         order by cr.prize_rank, cr.student_id
      loop
        v_pts   := public._competition_pts(r.points) || case when r.points = 1 then ' point' else ' points' end;
        v_first := public._competition_first_name(r.student_id);
        for rc in select * from public._competition_notify_recipients(r.student_id) loop
          if rc.is_guardian then
            v_title := v_first || ' finished ' || public._competition_ord(r.prize_rank) || ' in the ' || v_mon || ' race';
            v_body  := r.label || ', ' || v_pts || '. Well done ' || v_first || '!'
                       || case when r.hidden then ' ' || v_first || ' is hidden on the board, so they show as Anonymous.' else '' end;
          else
            v_title := 'You finished ' || public._competition_ord(r.prize_rank) || ' in the ' || v_mon || ' race';
            v_body  := r.label || ', ' || v_pts || '. Congratulations!'
                       || case when r.audience = 'adult' and not r.minor and r.unit_name is not null   -- 182: the share card
                               then ' You finished ' || public._competition_ord(r.prize_rank) || ' in ' || v_mon || ' at '
                                    || r.unit_name || '. Your champion card is ready to share.'
                               when r.audience = 'adult' then ' You''re on the ' || v_mon || ' champions card on the Wall.' else '' end
                       || case when r.hidden then ' You''re hidden on the board, so you show as Anonymous.' else '' end;
          end if;
          perform public.create_notification(
            p_user_id             := rc.user_id,
            p_type                := 'competition_result',
            p_title               := v_title,
            p_body                := v_body,
            p_related_entity_type := 'competition_result',
            p_related_entity_id   := r.id,
            p_metadata            := jsonb_build_object('competition_id', c.id, 'student_id', r.student_id, 'kind', 'monthly',
                                                        'month', v_from, 'prize_rank', r.prize_rank),
            p_check_prefs         := true
          );
          v_sent := v_sent + 1;
        end loop;
      end loop;
    exception when others then
      raise warning '172 monthly_close notify skipped: % (%)', sqlerrm, sqlstate;
    end;

    update public.competition_month_closes set result_rows = v_rows, notifications = v_sent
     where competition_id = c.id and period_from = v_from;
    raise notice 'monthly_close: % % published, % row(s), % notification(s)', c.name, to_char(v_from, 'YYYY-MM'), v_rows, v_sent;
    v_out := v_out || jsonb_build_object('competition_id', c.id, 'month', v_from, 'already_published', false,
                                         'rows', v_rows, 'notifications', v_sent);
  end loop;
  return v_out;
end;
$function$

;

do $$
begin
  if md5((select prosrc from pg_proc where oid = to_regprocedure('public.monthly_close(date)'))) <> 'c0bb9c3000385b6668e84eab4e6844d3' then
    raise exception '182: monthly_close body is not the expected text';
  end if;
  if not exists (select 1 from pg_proc p, acl182 a
                  where p.oid = to_regprocedure('public.monthly_close(date)')
                    and p.proowner = a.proowner and p.proacl::text is not distinct from a.acl
                    and p.prosecdef = a.prosecdef and p.provolatile = a.provolatile
                    and p.proconfig::text is not distinct from a.cfg) then
    raise exception '182: owner, grants, security or search_path of monthly_close changed';
  end if;
end $$;

-- 3. the October 2026 backfill -----------------------------------------------
do $$
declare
  v_comp   constant uuid := '3d66c81b-6f7e-456c-9077-403067db093f';
  v_from   constant date := '2026-10-01';
  v_mon    text := to_char(v_from, 'FMMonth');
  r        record;
  rc       record;
  v_new    integer := 0;
  v_had    integer := 0;
  v_noacct integer := 0;
  v_prefs  integer := 0;
begin
  for r in
    select cr.id, cr.student_id, cr.prize_rank, u.name::text as unit_name
      from public.competition_month_closes m
      join public.competition_results cr
        on cr.competition_id = m.competition_id and cr.period_from = m.period_from and cr.period_to = m.period_to
      left join public.units u on u.id = (cr.payload ->> 'unit_id')::uuid
     where m.competition_id = v_comp and m.period_from = v_from
       and cr.points > 0 and cr.prize_rank between 1 and 3
       and coalesce((cr.payload ->> 'prize_eligible')::boolean, true)
       and cr.payload ->> 'audience' = 'adult'
       and not coalesce((cr.payload ->> 'minor')::boolean, false)
     order by u.name, cr.prize_rank, cr.student_id
  loop
    if not exists (select 1 from public._competition_notify_recipients(r.student_id) x where not x.is_guardian) then
      v_noacct := v_noacct + 1;
      continue;
    end if;
    for rc in select x.user_id from public._competition_notify_recipients(r.student_id) x where not x.is_guardian loop
      if exists (select 1 from public.notifications n
                  where n.user_id = rc.user_id and n.type = 'competition_result'
                    and n.related_entity_type = 'competition_result' and n.related_entity_id = r.id
                    and coalesce((n.metadata ->> 'share')::boolean, false)) then
        v_had := v_had + 1;
        continue;
      end if;
      if not public.user_wants_notification_type(rc.user_id, 'competition_result') then
        v_prefs := v_prefs + 1;
        continue;
      end if;
      insert into public.notifications (user_id, type, title, body, related_entity_type, related_entity_id, metadata)
      values (rc.user_id, 'competition_result',
              'Your ' || v_mon || ' champion card is ready to share',
              'You finished ' || public._competition_ord(r.prize_rank) || ' in ' || v_mon || coalesce(' at ' || r.unit_name, '') || '.',
              'competition_result', r.id,
              jsonb_build_object('competition_id', v_comp, 'student_id', r.student_id, 'kind', 'monthly',
                                 'month', v_from, 'prize_rank', r.prize_rank, 'share', true));
      v_new := v_new + 1;
    end loop;
  end loop;
  raise notice '182 backfill: % inserted, % already there, % skipped (no account), % skipped (notifications off)',
    v_new, v_had, v_noacct, v_prefs;
end $$;

commit;
