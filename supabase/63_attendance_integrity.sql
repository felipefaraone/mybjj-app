-- 63_attendance_integrity.sql
-- (1) Backfill: make `gi` boolean consistent with `modality` text.
--     modality is canonical (used by recompute_student_stats).

-- 1a — fill modality where null, from existing gi boolean
update public.attendance
set modality = case when gi then 'gi' else 'nogi' end
where modality is null;

-- 1b — fix gi where it disagrees with modality
update public.attendance
set gi = (modality = 'gi')
where modality is not null and gi <> (modality = 'gi');

-- (2) Partial UNIQUE index on (student_id, class_id) — only where class_id NOT NULL.
--     Legacy rows with class_id NULL are out of the gate (acceptable trade-off).
drop index if exists attendance_student_class_uniq;
create unique index attendance_student_class_uniq
  on public.attendance (student_id, class_id)
  where class_id is not null;
