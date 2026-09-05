-- ============================================================================
-- 125 — a backdated grading must not wipe the student's baseline
--       (+ audit the columns that made this take five hours to find)
-- ============================================================================
--
-- WHAT HAPPENED
--
-- promotion_reset_grade_baseline zeroed students.baseline_grade on EVERY
-- promotion INSERT or DELETE. That is correct for a promotion happening now:
-- the count toward the next stripe restarts at zero.
--
-- It is wrong for a graduation being RECORDED LATE. baseline_grade holds the
-- classes a student did before the app, typed in by a human, and when the
-- graduation date is months in the past those classes fall AFTER it and still
-- count. Zeroing destroyed a number nobody could recompute.
--
-- The trigger was never reviewed. It predates migration 111, which captured it
-- from the live database with the comment "captured from the live DB (never
-- committed)" and versioned it verbatim. Capturing is not reviewing: that was
-- the first time anyone read it, and the question of whether it was correct was
-- never asked. The comment immediately below it in 111 does exactly that kind
-- of analysis for a different trigger, so the habit existed — it just was not
-- applied here.
--
-- The row already carried the answer. Backdated entries are written with
-- hidden=true, the app's own mark for "this is history, not an announcement".
-- The trigger never read it.
--
-- SCALE
--
-- It fired on more than 170 backdated records across July and August. On
-- 23 August at 20:31 the head instructor entered 23 old gradings in 17 minutes
-- and lost 23 baselines in one sitting. By 5 September, 109 students held
-- baseline_total > 0 with baseline_grade = 0 — the signature of the damage.
--
-- He noticed because three students went backwards: a white belt sitting at
-- 63/20 for his blue dropped to 16/20, and he had already told the student he
-- was close. He was right every time he said the numbers had moved.
--
-- THE FIX
--
-- Only a promotion dated within the last 7 days restarts the count. In the real
-- data, normal use lands 0 to a few days after the graduation and every bulk
-- backfill sits 58 to 201 days out; no row in the base falls in between. A late
-- entry now leaves the baseline alone, and whoever records it adjusts "since
-- last promotion" in the Edit class counts modal if it needs adjusting — which
-- works correctly as of migration 124.
--
-- RECOVERY (done 2026-09-05, recorded here because it is not reproducible)
--
-- The original values were unrecoverable by every route: promotions.classes is
-- null on 23 of the 24 rows from 23 August, students.journey carries
-- classes:null, audit_log only starts 2026-09-04 20:55, and the project is on a
-- plan with no backups. Paid tiers would not have helped either — the damage
-- was 13 days old and retention is 7.
--
-- What made recovery possible was a pattern: of the 141 students who still had
-- a baseline_grade, 135 had baseline_grade = baseline_total. The import had set
-- them equal. Three independent confirmations: the four students whose
-- baselines survived the 23 August batch were all equal; a July backup table
-- for one student showed 100/100; and the head instructor remembered one modal
-- showing the same number in both fields.
--
--   create table public._bak_students_baseline_20260905 as
--     select id, full_name, baseline_total, baseline_grade, total, grade,
--            last_marker_date from public.students;          -- 453 rows
--
--   update public.students set baseline_grade = baseline_total
--    where coalesce(baseline_total,0) > 0
--      and coalesce(baseline_grade,0) = 0;                   -- 109 rows
--
--   do $$ declare r record; begin
--     for r in select id from public.students
--               where coalesce(baseline_grade,0) > 0 loop
--       perform public.recompute_student_stats(r.id);
--     end loop; end $$;
--
-- 109 students, 2506 credits returned, smallest 1 and largest 100. Verified:
-- zero students left with baseline_total > 0 and baseline_grade = 0, in any
-- active state.
--
-- NOTE for whoever runs a recompute in bulk later: `select f(id) from t` does
-- NOT execute for every row in the Supabase SQL editor — it returned 100 empty
-- rows and changed nothing, which read exactly like the fix having failed. Use
-- the do-block loop above.
-- ============================================================================

create or replace function public.promotion_reset_grade_baseline()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_sid  uuid := coalesce(NEW.student_id, OLD.student_id);
  v_date date := coalesce(NEW.date, OLD.date);
begin
  -- Declared history is the student's own account of their pre-app past and
  -- never touches the grading clock (migration 123).
  if coalesce(NEW.source, OLD.source, 'academy') = 'declared' then
    return coalesce(NEW, OLD);
  end if;
  if v_sid is null then return coalesce(NEW, OLD); end if;

  -- Only a promotion that actually happened in the last 7 days restarts the
  -- count. A graduation being recorded late leaves the baseline alone.
  if v_date is not null and v_date >= current_date - 7 then
    update public.students set baseline_grade = 0 where id = v_sid;
  end if;

  perform public.recompute_student_stats(v_sid);
  return coalesce(NEW, OLD);
end;
$function$;

-- ============================================================================
-- AUDIT — grade and last_marker_date
-- ============================================================================
-- audit_log watched belt, degree, journey, the two baselines and active, but
-- not grade and not last_marker_date. So when the head instructor asked "did
-- this number change?", the database had no answer, and an update that touched
-- only grade left no trace at all. That gap is most of why this took five hours
-- to diagnose, and it is why the recovery above rests on an inferred pattern
-- rather than on recorded values.
--
-- Cost: grade changes on every attendance mark, so audit_log now grows by
-- roughly one row per check-in. Accepted — it is the column that cannot be
-- reconstructed from anything else.
--
-- General rule this produced: a trigger that deletes human-entered data needs
-- the same scrutiny as a manual DELETE. It never passes a grep gate, it runs on
-- every write, and nothing backs it up.
-- ============================================================================

drop trigger if exists trg_audit_students on public.students;
create trigger trg_audit_students
after insert or update or delete on public.students
for each row execute function public.audit_row(
  'belt','degree','journey','bjj_start_date','training_started_at',
  'baseline_total','baseline_grade','active','grade','last_marker_date'
);
