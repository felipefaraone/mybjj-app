-- 182_champion_share_rollback.sql
--
-- Undoes 182: drops public.my_month_title_share, restores public.monthly_close
-- to the live text 182 was built from (body md5 9c30d2c53b7d09f30380225597d102f3;
-- owner, grants, security and search_path are untouched by CREATE OR REPLACE)
-- and deletes the backfilled share notifications (metadata share: true, which
-- only 182's backfill writes). Run on its own:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/182_champion_share_rollback.sql

begin;

do $$
begin
  if md5(coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.monthly_close(date)')), ''))
     not in ('9c30d2c53b7d09f30380225597d102f3', 'c0bb9c3000385b6668e84eab4e6844d3') then
    raise exception '182 rollback preflight: monthly_close is neither 182''s text nor the one before it; stop and compare';
  end if;
end $$;

drop function if exists public.my_month_title_share(uuid, date);

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
               cr.payload ->> 'audience' as audience
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
                       || case when r.audience = 'adult' then ' You''re on the ' || v_mon || ' champions card on the Wall.' else '' end
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

delete from public.notifications
 where type = 'competition_result' and related_entity_type = 'competition_result'
   and coalesce((metadata ->> 'share')::boolean, false);

do $$
begin
  if md5((select prosrc from pg_proc where oid = to_regprocedure('public.monthly_close(date)'))) <> '9c30d2c53b7d09f30380225597d102f3' then
    raise exception '182 rollback: monthly_close is not the restored text';
  end if;
end $$;

commit;
