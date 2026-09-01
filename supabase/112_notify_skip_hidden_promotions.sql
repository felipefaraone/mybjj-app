-- 112 — Promotion notifications must ignore hidden (historical) entries.
-- The Promote -> "not current belt" flow writes hidden=true rows to build a
-- student's ladder; the notify trigger fired on those too, sending "New belt!"
-- for gradings that happened years ago. Guard added; body otherwise identical
-- to the live function captured in 111.

CREATE OR REPLACE FUNCTION public.trg_notify_promotion_fn()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_user_id       uuid;
  v_student_name  text;
  v_student_prog  text;
  v_promoter_name text;
  v_title         text;
  v_body          text;
begin
  -- 112: historical/backfill entries (hidden=true) are records, not events -- never notify.
  if NEW.hidden is true then return NEW; end if;
  select coalesce(s.user_id, s.parent_user_id), s.full_name, s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s where s.id = NEW.student_id;
  if v_user_id is null then return NEW; end if;
  v_promoter_name := coalesce(NEW.promoted_by_name, 'Your instructor');
  if NEW.is_new_belt is true then
    v_title := 'New belt!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    else
      v_body := 'You were promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    end if;
  else
    v_title := 'New stripe!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' earned a new stripe from ' || v_promoter_name || '.';
    else
      v_body := 'You earned a new stripe from ' || v_promoter_name || '.';
    end if;
  end if;
  perform public.create_notification(
    p_user_id := v_user_id, p_type := 'promotion', p_title := v_title, p_body := v_body,
    p_related_entity_type := 'promotion', p_related_entity_id := NEW.id,
    p_metadata := jsonb_build_object('student_id', NEW.student_id, 'from_belt', NEW.from_belt,
      'to_belt', NEW.to_belt, 'from_deg', NEW.from_deg, 'to_deg', NEW.to_deg, 'is_new_belt', NEW.is_new_belt),
    p_check_prefs := true);
  return NEW;
end;
$function$;
