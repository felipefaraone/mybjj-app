-- ============================================================================
-- 150 — Competitions, PHASE A3: seed (Christmas Cup 2026 + the monthly race)
-- ============================================================================
--
-- Requires 148 and 149. Run 150_competitions_seed_verify.sql's PRE-CHECK (V0)
-- first: it shows the two units this seed will use.
--
--   Christmas Cup 2026  event, 2026-11-02 .. 2026-12-18 (inclusive), finale
--                       2026-12-19, active, prizes 1st / 2nd / 3rd
--   Monthly race        monthly (period supplied at query time), active
--   Both: 4 divisions — Camperdown kids / adults, Neutral Bay kids / adults.
--   Cup rules:     class_attended 1 {"mode":"class_value","private_cap":1},
--                  social_post 2, class_challenge 3, referral_trial 3,
--                  referral_conversion 5, best_attitude 0 DISABLED (pending
--                  the owner's decision).
--   Monthly rules: class_attended 1 (same params), referral_trial 3,
--                  referral_conversion 5.
--
-- Units are resolved BY NAME (case and spaces ignored), never by hardcoded id.
-- The seed stops with an exception, writing nothing, if a name does not match
-- exactly one unit, or if a competition with either name already exists.
--
-- Rollback: 150_competitions_seed_rollback.sql.
-- ============================================================================

begin;

do $$
declare
  v_cd uuid; v_nb uuid; n integer;
  v_cup uuid; v_mon uuid;
  v_ca constant jsonb := '{"mode":"class_value","private_cap":1}'::jsonb;
begin
  select count(*) into n from public.units u where lower(btrim(u.name)) = 'camperdown';
  if n <> 1 then
    raise exception 'seed 150: expected exactly 1 unit named Camperdown, found %', n;
  end if;
  select u.id into v_cd from public.units u where lower(btrim(u.name)) = 'camperdown';

  select count(*) into n from public.units u where lower(btrim(u.name)) = 'neutral bay';
  if n <> 1 then
    raise exception 'seed 150: expected exactly 1 unit named Neutral Bay, found %', n;
  end if;
  select u.id into v_nb from public.units u where lower(btrim(u.name)) = 'neutral bay';

  if exists (select 1 from public.competitions c where c.name in ('Christmas Cup 2026', 'Monthly race')) then
    raise exception 'seed 150: a competition named Christmas Cup 2026 or Monthly race already exists; nothing written';
  end if;

  -- Christmas Cup 2026
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
  values ('Christmas Cup 2026', 'event', date '2026-11-02', date '2026-12-18', date '2026-12-19', 'active',
          '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]'::jsonb)
  returning id into v_cup;

  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort) values
    (v_cup, v_cd, 'kids',  'Camperdown Kids',    1),
    (v_cup, v_cd, 'adult', 'Camperdown Adults',  2),
    (v_cup, v_nb, 'kids',  'Neutral Bay Kids',   3),
    (v_cup, v_nb, 'adult', 'Neutral Bay Adults', 4);

  insert into public.competition_rules (competition_id, rule_key, points, params, enabled) values
    (v_cup, 'class_attended',      1, v_ca,          true),
    (v_cup, 'social_post',         2, '{}'::jsonb,   true),
    (v_cup, 'class_challenge',     3, '{}'::jsonb,   true),
    (v_cup, 'referral_trial',      3, '{}'::jsonb,   true),
    (v_cup, 'referral_conversion', 5, '{}'::jsonb,   true),
    (v_cup, 'best_attitude',       0, '{}'::jsonb,   false);   -- pending the owner's decision

  -- Monthly race (no dates: the month is supplied when it is read)
  insert into public.competitions (name, kind, status)
  values ('Monthly race', 'monthly', 'active')
  returning id into v_mon;

  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort) values
    (v_mon, v_cd, 'kids',  'Camperdown Kids',    1),
    (v_mon, v_cd, 'adult', 'Camperdown Adults',  2),
    (v_mon, v_nb, 'kids',  'Neutral Bay Kids',   3),
    (v_mon, v_nb, 'adult', 'Neutral Bay Adults', 4);

  insert into public.competition_rules (competition_id, rule_key, points, params, enabled) values
    (v_mon, 'class_attended',      1, v_ca,        true),
    (v_mon, 'referral_trial',      3, '{}'::jsonb, true),
    (v_mon, 'referral_conversion', 5, '{}'::jsonb, true);
end $$;

commit;
