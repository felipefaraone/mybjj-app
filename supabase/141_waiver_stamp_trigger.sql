-- 141_waiver_stamp_trigger.sql (10 Oct 2026). Applied in the SQL Editor before this file was committed.
-- Why: students.waiver_signed_at (the roster badge, waiverStatus) was never stamped by the kid
-- convert path, which only re-linked health_waivers.student_id. 19 students had a signed, linked
-- waiver while the app showed "No waiver". Fix at the source: linking a waiver to a student stamps
-- the student, whatever path did the linking.
-- Rules: stamp only when NULL (never overwrite a manual or earlier stamp). When the waiver that
-- produced the stamp is deleted or unlinked, fall back to the next linked waiver, or NULL.
-- Backup taken first: _bak_students_waiver_20261010, _bak_health_waivers_link_20261010.

create or replace function public.health_waiver_stamp_student()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.student_id is not null then
      update public.students
         set waiver_signed_at = coalesce(new.signed_at, new.created_at, now())
       where id = new.student_id and waiver_signed_at is null;
    end if;

  elsif tg_op = 'UPDATE' then
    if new.student_id is distinct from old.student_id then
      if old.student_id is not null then
        update public.students s
           set waiver_signed_at = (select max(coalesce(w.signed_at, w.created_at))
                                     from public.health_waivers w
                                    where w.student_id = old.student_id and w.id <> old.id)
         where s.id = old.student_id
           and s.waiver_signed_at = coalesce(old.signed_at, old.created_at);
      end if;
      if new.student_id is not null then
        update public.students
           set waiver_signed_at = coalesce(new.signed_at, new.created_at, now())
         where id = new.student_id and waiver_signed_at is null;
      end if;
    end if;

  elsif tg_op = 'DELETE' then
    if old.student_id is not null then
      update public.students s
         set waiver_signed_at = (select max(coalesce(w.signed_at, w.created_at))
                                   from public.health_waivers w
                                  where w.student_id = old.student_id and w.id <> old.id)
       where s.id = old.student_id
         and s.waiver_signed_at = coalesce(old.signed_at, old.created_at);
    end if;
  end if;
  return null;
end;
$$;

revoke all on function public.health_waiver_stamp_student() from public, anon, authenticated;

drop trigger if exists trg_health_waiver_stamp_student on public.health_waivers;
create trigger trg_health_waiver_stamp_student
  after insert or update of student_id or delete on public.health_waivers
  for each row execute function public.health_waiver_stamp_student();

-- Backfill: every student with a linked waiver and no stamp (19 on 10 Oct 2026).
update public.students s
   set waiver_signed_at = w.latest
  from (select student_id, max(coalesce(signed_at, created_at)) as latest
          from public.health_waivers
         where student_id is not null
         group by student_id) w
 where s.id = w.student_id
   and s.waiver_signed_at is null;
