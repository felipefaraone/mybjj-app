-- 121_post_milestones_disabled.sql
-- 5 September 2026
--
-- PURPOSE
-- Version the automatic class-milestone posts, applied directly in the SQL
-- Editor. Depends on migration 119 (posts.kind / subject_student_id / milestone
-- and the posts_milestone_uniq index).
--
-- SHIPPED, THEN TURNED OFF THE SAME DAY. READ THIS BEFORE ENABLING IT.
-- The trigger is created DISABLED, which is how it runs in production. That is
-- deliberate, not an oversight, and the file exists so a rebuilt database
-- reproduces the OFF state rather than quietly switching it on.
--
-- The feature worked. The measurements were fine: 50 and 100 are rare enough not
-- to flood the feed, the card rendered correctly, the copy had twelve variants.
-- What was wrong was the premise. Asked whether hitting 50 or 100 classes is
-- something people at the gym talk about, the head instructor said: "not really
-- a thing". The app was inventing a ritual that does not exist on the mats.
--
-- Belt promotions are different and stay: the academy already celebrates those
-- in person, and the Wall only records what is already happening.
--
-- The trigger and columns are kept rather than dropped because the shape is
-- reusable if milestones ever return inside a weekly summary post — a line among
-- the gym's numbers rather than a card of its own — which is where they belonged
-- in the first place.
--
-- WHY A TRIGGER ON students AND NOT ON attendance
-- A milestone needs the total BEFORE and AFTER to know a threshold was crossed.
-- students.total already carries the historical import baseline plus real
-- attendance, so counting attendance rows would give the wrong number for the
-- 150 adults who have a baseline. The AFTER UPDATE OF total trigger has both
-- values in scope and needs no arithmetic of its own.
--
-- NO RETROACTIVE POSTS, BY CONSTRUCTION
-- The trigger only sees updates, so anyone already past 50 never gets a post.
-- That is correct: the milestone happened before the app existed.
--
-- THE > 5 GUARD
-- Editing baseline_total from 0 to 100 would cross both thresholds at once and
-- celebrate a data repair. A real class moves the total by at most 1.

create or replace function public.post_milestone_trigger()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_marks int[] := array[50,100];
  v_m int;
  v_old numeric := coalesce(OLD.total,0);
  v_new numeric := coalesce(NEW.total,0);
begin
  if NEW.prog <> 'adult' then return NEW; end if;
  if NEW.active is not true then return NEW; end if;
  if NEW.unit_id is null then return NEW; end if;
  -- A jump larger than a single class is an administrative correction
  -- (baseline edited, rows imported), not someone crossing a milestone
  -- on the mats. Never celebrate a data fix.
  if v_new - v_old > 5 then return NEW; end if;

  foreach v_m in array v_marks loop
    if v_old < v_m and v_new >= v_m then
      insert into public.posts (unit_id, author_user_id, author_name, body,
                                kind, subject_student_id, milestone)
      values (NEW.unit_id, null, null, v_m || ' classes',
              'milestone', NEW.id, v_m)
      on conflict do nothing;
    end if;
  end loop;
  return NEW;
end $function$;

drop trigger if exists trg_posts_milestone on public.students;
create trigger trg_posts_milestone
after update of total on public.students
for each row
when (new.total is distinct from old.total)
execute function public.post_milestone_trigger();

-- Matches production. To turn milestones back on:
--   alter table public.students enable trigger trg_posts_milestone;
alter table public.students disable trigger trg_posts_milestone;
