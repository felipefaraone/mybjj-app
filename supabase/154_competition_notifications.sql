-- ============================================================================
-- 154 — Competition notifications (Leaderboard phase C)
-- ============================================================================
--
-- Members hear about competition points in the bell, without opening the board.
-- Follows the existing notification pattern (42, 133, 134): rows are written
-- only by SECURITY DEFINER code through public.create_notification (which
-- dedupes on user + type + related entity and honours preferences), and a
-- notification is removed by setting dismissed_at (there is no delete).
--
-- 1. notifications CHECK constraints widened exactly as 134 did (drop and re-add,
--    same names): type + 'competition_points'; related_entity_type +
--    'competition_award' / 'trial_referral'. A preflight refuses to run if
--    production has drifted from the lists 134 left.
-- 2. When to notify: only when the points actually count. The competition that
--    applies is the one competition_for_date would pick for the student's HOME
--    unit on that date (an active challenge whose scoring dates cover it and
--    that has a division for the unit and the student's audience, else the
--    active monthly board), and the rule must be enabled there. A class award
--    also needs the present attendance 152 requires. No notification otherwise.
--      competition_awards insert  -> the student's account and every active
--                                    guardian (the set that receives other kid
--                                    notifications, as 133's feedback trigger);
--                                    guardians read the kid's first name.
--      competition_awards void    -> that award's notifications dismissed.
--      trial_bookings referrer linked / changed -> the referrer (link copy);
--                                    unlinked or changed -> the old referrer's
--                                    notifications for that booking dismissed.
--      trial_bookings converted while a referrer is linked -> the referrer.
--      Never when the referee is the referrer themself.
-- 3. Preferences: create_notification is called with p_check_prefs true; the
--    existing user_wants_notification_type has no key for 'competition_points',
--    so it is delivered by default (no existing toggle gates it, none added).
--
-- Requires 42, 133, 134, 148-153. Rollback: 154_..._rollback.sql. Checks: _verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Preflight (as 134): the two constraints must hold exactly the lists 134
--    left, or those plus 154's values (a re-run). Anything else aborts.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def  text;
  v_vals text[];
  r      record;
begin
  for r in select * from (values
    ('notifications_type_check',
     array['admin_message','feedback_received','guardian_request','photo_approved','photo_rejected','promotion'],
     array['competition_points']),
    ('notifications_related_entity_type_check',
     array['admin_message','feedback','guardianship','photo_approval','promotion'],
     array['competition_award','trial_referral'])
  ) as t(conname, expected, added) loop
    select pg_get_constraintdef(c.oid) into v_def
      from pg_constraint c
     where c.conrelid = 'public.notifications'::regclass and c.conname = r.conname;
    if v_def is null then
      raise exception '154 preflight: constraint % not found on public.notifications', r.conname;
    end if;
    select array_agg(m[1] order by m[1]) into v_vals
      from regexp_matches(v_def, '''([^'']+)''', 'g') as m;
    if not (v_vals = r.expected
            or v_vals = (select array_agg(x order by x) from unnest(r.expected || r.added) x)) then
      raise exception '154 preflight: % is % (expected %)', r.conname, v_vals, r.expected;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Notifications: 134's values + 'competition_points' / 'competition_award',
--    'trial_referral'.
-- ---------------------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'photo_approved', 'photo_rejected',
    'feedback_received', 'promotion',
    'admin_message',
    'guardian_request',                      -- 134
    'competition_points'                     -- 154
  ));

alter table public.notifications drop constraint if exists notifications_related_entity_type_check;
alter table public.notifications add constraint notifications_related_entity_type_check
  check (related_entity_type in (
    'photo_approval', 'feedback', 'promotion', 'admin_message',
    'guardianship',                          -- 134
    'competition_award', 'trial_referral'    -- 154
  ));

-- ---------------------------------------------------------------------------
-- 2. Helpers (internal)
-- ---------------------------------------------------------------------------

-- The competition whose points this student earns with rule p_key on p_date,
-- and the rule's points. Empty when the points would not count.
create or replace function public._competition_notify_rule(p_student uuid, p_date date, p_key text)
returns table (competition_id uuid, competition_name text, points numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.students;
  v_aud text;
  v_comp uuid;
begin
  if p_student is null or p_date is null then return; end if;
  select * into s from public.students where id = p_student;
  if not found or s.unit_id is null
     or not public._competition_eligible(s.active, s.standing::text, s.membership_level::text) then
    return;
  end if;
  v_aud := public._competition_audience(s.prog::text);
  -- an active challenge scoring on that date, with this student's division
  select c.id into v_comp
    from public.competitions c
   where c.status = 'active' and c.kind = 'event'
     and p_date between c.starts_on and c.ends_on
     and exists (select 1 from public.competition_divisions d
                  where d.competition_id = c.id and d.unit_id = s.unit_id and d.audience = v_aud)
   order by c.starts_on desc, c.created_at desc
   limit 1;
  if v_comp is null then
    -- else the active monthly board (the one competition_for_date shows)
    select c.id into v_comp
      from public.competitions c
     where c.status = 'active' and c.kind = 'monthly'
       and exists (select 1 from public.competition_divisions d
                    where d.competition_id = c.id and d.unit_id = s.unit_id and d.audience = v_aud)
     order by c.created_at desc
     limit 1;
  end if;
  if v_comp is null then return; end if;
  return query
    select c.id, c.name::text, r.points
      from public.competitions c
      join public.competition_rules r on r.competition_id = c.id
     where c.id = v_comp and r.rule_key = p_key and r.enabled is true and r.points > 0;
end;
$$;

-- Who hears about a student: their own account, and every active guardian
-- (133's set for kid notifications). is_guardian marks the third-person copy.
create or replace function public._competition_notify_recipients(p_student uuid)
returns table (user_id uuid, is_guardian boolean)
language sql
stable
security definer
set search_path = public
as $$
  select distinct on (x.user_id) x.user_id, x.is_guardian
    from (
      select s.user_id, false as is_guardian
        from public.students s where s.id = p_student and s.user_id is not null
      union all
      select g.guardian_user_id, true
        from public.guardianships g
       where g.student_id = p_student and g.status = 'active' and g.guardian_user_id is not null
    ) x
    join public.users u on u.id = x.user_id
   order by x.user_id, x.is_guardian;   -- the student's own account wins over a guardian row
$$;

create or replace function public._competition_first_name(p_student uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(btrim(s.first_name::text), ''), nullif(split_part(btrim(coalesce(s.full_name::text, '')), ' ', 1), ''), 'Your child')
    from public.students s where s.id = p_student
$$;

create or replace function public._competition_pts(p numeric)
returns text
language sql
immutable
as $$ select trim_scale(p)::text $$;

-- ---------------------------------------------------------------------------
-- 3. competition_awards -> notifications
-- ---------------------------------------------------------------------------
create or replace function public.competition_awards_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule record;
  v_first text;
  v_pts text;
  v_day text;
  v_title text;
  v_body text;
  r record;
begin
  -- All notification work (create and dismiss) sits in this block: a failure
  -- here is a WARNING and rolls back only the notification work, never the
  -- staff write that fired the trigger. Every path returns NEW.
  begin
    -- void: remove this award's notifications (existing removal pattern)
    if TG_OP = 'UPDATE' then
      if OLD.voided_at is null and NEW.voided_at is not null then
        update public.notifications n
           set dismissed_at = coalesce(n.dismissed_at, now())
         where n.related_entity_type = 'competition_award'
           and n.related_entity_id = NEW.id
           and n.dismissed_at is null;
      end if;
      return NEW;
    end if;

    if NEW.voided_at is not null
       or NEW.award_key not in ('class_challenge', 'best_attitude', 'social_post') then
      return NEW;
    end if;
    -- a class award counts only with a present attendance (152)
    if NEW.class_date is not null and not exists (
         select 1 from public.attendance a
          where a.student_id = NEW.student_id and a.status = 'present' and a.class_date = NEW.class_date
            and ((NEW.class_id is not null and a.class_id = NEW.class_id)
                 or (NEW.class_id is null and a.class_id is null))) then
      return NEW;
    end if;
    select * into v_rule from public._competition_notify_rule(NEW.student_id, NEW.award_date, NEW.award_key) limit 1;
    if v_rule.competition_id is null then
      return NEW;
    end if;

    v_first := public._competition_first_name(NEW.student_id);
    v_pts   := public._competition_pts(v_rule.points);
    v_day   := to_char(NEW.award_date, 'Dy FMDD Mon');

    for r in select * from public._competition_notify_recipients(NEW.student_id) loop
      if NEW.award_key = 'class_challenge' then
        v_title := case when r.is_guardian then v_first || ' won the class challenge · +' || v_pts
                        else 'Challenge win · +' || v_pts end;
        v_body  := v_rule.competition_name || ' · ' || v_day;
      elsif NEW.award_key = 'best_attitude' then
        v_title := case when r.is_guardian then v_first || ' got best attitude · +' || v_pts
                        else 'Best attitude · +' || v_pts end;
        v_body  := v_rule.competition_name || ' · ' || v_day;
      else
        v_title := case when r.is_guardian then v_first || '''s social post logged · +' || v_pts
                        else 'Social post logged · +' || v_pts end;
        v_body  := 'Thanks for sharing myBJJ. ' || v_rule.competition_name;
      end if;
      perform public.create_notification(
        p_user_id             := r.user_id,
        p_type                := 'competition_points',
        p_title               := v_title,
        p_body                := v_body,
        p_related_entity_type := 'competition_award',
        p_related_entity_id   := NEW.id,
        p_metadata            := jsonb_build_object('student_id', NEW.student_id, 'award_key', NEW.award_key,
                                                    'competition_id', v_rule.competition_id),
        p_check_prefs         := true
      );
    end loop;
  exception when others then
    raise warning '154 notify skipped: % (%)', sqlerrm, sqlstate;
  end;
  return NEW;
end;
$$;

drop trigger if exists trg_competition_awards_notify on public.competition_awards;
create trigger trg_competition_awards_notify
  after insert or update of voided_at on public.competition_awards
  for each row execute function public.competition_awards_notify();

-- ---------------------------------------------------------------------------
-- 4. trial_bookings -> notifications (referrals)
-- ---------------------------------------------------------------------------
create or replace function public.trial_referral_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref uuid;
  v_today date;
  v_friend text;
  v_trained date;
  v_trial record;
  v_conv record;
  v_title text;
  v_body text;
  v_send_link boolean := false;
  v_send_conv boolean := false;
  r record;
begin
  -- All notification work (create and dismiss) sits in this block: a failure
  -- here is a WARNING and rolls back only the notification work, never the
  -- staff write that fired the trigger. Every path returns NEW.
  begin
    v_ref   := NEW.referred_by_student_id;
    v_today := (now() at time zone 'Australia/Sydney')::date;

    -- referrer removed or changed: the old referrer's notifications for this
    -- booking go (existing removal pattern)
    if TG_OP = 'UPDATE' and OLD.referred_by_student_id is not null
       and OLD.referred_by_student_id is distinct from NEW.referred_by_student_id then
      update public.notifications n
         set dismissed_at = coalesce(n.dismissed_at, now())
       where n.related_entity_type = 'trial_referral'
         and n.metadata->>'booking_id' = NEW.id::text
         and n.dismissed_at is null;
    end if;

    if v_ref is null then return NEW; end if;
    -- never when the referee is the referrer themself
    if NEW.converted_student_id is not null and NEW.converted_student_id = v_ref then return NEW; end if;

    v_send_link := TG_OP = 'INSERT' or OLD.referred_by_student_id is distinct from v_ref;
    v_send_conv := NEW.converted_student_id is not null
                   and (v_send_link or TG_OP = 'INSERT' or OLD.converted_student_id is null);
    if not v_send_link and not v_send_conv then return NEW; end if;

    v_friend := coalesce(
      nullif(split_part(btrim(case when NEW.is_kid then coalesce(NEW.kid_name, '') else '' end), ' ', 1), ''),
      nullif(btrim(coalesce(NEW.first_name, '')), ''),
      'Your friend');
    v_trained := public.trial_first_attended_on(NEW.id);

    if v_send_link then
      if v_trained is not null then
        -- already trained: the trial points, if they count on that day
        select * into v_trial from public._competition_notify_rule(v_ref, v_trained, 'referral_trial') limit 1;
        if v_trial.competition_id is not null then
          v_title := v_friend || ' trained with us · +' || public._competition_pts(v_trial.points);
          v_body  := v_trial.competition_name;
        end if;
      else
        -- not trained yet: what counts today
        select * into v_trial from public._competition_notify_rule(v_ref, v_today, 'referral_trial') limit 1;
        select * into v_conv  from public._competition_notify_rule(v_ref, v_today, 'referral_conversion') limit 1;
        if v_trial.competition_id is not null or v_conv.competition_id is not null then
          v_title := 'Thanks for the referral';
          v_body  := concat_ws(' ',
            case when v_trial.competition_id is not null then 'When ' || v_friend || ' trains with us you get +' || public._competition_pts(v_trial.points) || '.' end,
            case when v_conv.competition_id is not null then
              case when v_trial.competition_id is not null then 'If they sign up, +' || public._competition_pts(v_conv.points) || ' more.'
                   else 'If ' || v_friend || ' signs up, you get +' || public._competition_pts(v_conv.points) || '.' end end);
        end if;
      end if;
      if v_title is not null then
        for r in select * from public._competition_notify_recipients(v_ref) loop
          perform public.create_notification(
            p_user_id             := r.user_id,
            p_type                := 'competition_points',
            p_title               := v_title,
            p_body                := v_body,
            p_related_entity_type := 'trial_referral',
            p_related_entity_id   := NEW.id,
            p_metadata            := jsonb_build_object('booking_id', NEW.id, 'kind', 'link', 'student_id', v_ref),
            p_check_prefs         := true
          );
        end loop;
      end if;
    end if;

    if v_send_conv then
      select * into v_conv from public._competition_notify_rule(
        v_ref, coalesce((NEW.converted_at at time zone 'Australia/Sydney')::date, v_today), 'referral_conversion') limit 1;
      if v_conv.competition_id is not null then
        for r in select * from public._competition_notify_recipients(v_ref) loop
          perform public.create_notification(
            p_user_id             := r.user_id,
            p_type                := 'competition_points',
            p_title               := v_friend || ' signed up · +' || public._competition_pts(v_conv.points),
            p_body                := v_conv.competition_name,
            p_related_entity_type := 'trial_referral',
            -- its own entity id (the new member), so create_notification's dedupe
            -- never folds it into the link notification for the same booking
            p_related_entity_id   := NEW.converted_student_id,
            p_metadata            := jsonb_build_object('booking_id', NEW.id, 'kind', 'conversion', 'student_id', v_ref),
            p_check_prefs         := true
          );
        end loop;
      end if;
    end if;
  exception when others then
    raise warning '154 notify skipped: % (%)', sqlerrm, sqlstate;
  end;
  return NEW;
end;
$$;

drop trigger if exists trg_trial_referral_notify on public.trial_bookings;
create trigger trg_trial_referral_notify
  after insert or update of referred_by_student_id, converted_student_id on public.trial_bookings
  for each row execute function public.trial_referral_notify();

-- ---------------------------------------------------------------------------
-- Privileges: every function here is internal
-- ---------------------------------------------------------------------------
revoke all on function public._competition_notify_rule(uuid, date, text)   from public, anon, authenticated;
revoke all on function public._competition_notify_recipients(uuid)          from public, anon, authenticated;
revoke all on function public._competition_first_name(uuid)                 from public, anon, authenticated;
revoke all on function public._competition_pts(numeric)                     from public, anon, authenticated;
revoke all on function public.competition_awards_notify()                   from public, anon, authenticated;
revoke all on function public.trial_referral_notify()                       from public, anon, authenticated;

commit;
