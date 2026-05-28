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

-- 2 — full UNIQUE constraint (PostgREST exige constraint, não partial index)
   alter table public.attendance drop constraint if exists attendance_student_class_uniq;
   alter table public.attendance add constraint attendance_student_class_uniq unique (student_id, class_id);