-- 179_waiver_lock_rollback.sql
--
-- Undoes 179 exactly: health_waivers back to its table-level grants of before 179
-- (relacl {postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres},
-- no column privileges), and storage waivers_read back to its text of before 179
-- (qual md5 c1125fafaa8f7a1ac4fb7c1ae4e542cb). Checked after; the other storage
-- policies are checked unchanged (md5 4fd720c4037146b0b81a1ef77f66713e).
-- Run on its own:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/179_waiver_lock_rollback.sql

begin;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'waivers_read' and qual like '%can_read_full_waiver%') then
    raise exception '179 rollback: 179 is not applied (waivers_read does not call can_read_full_waiver)';
  end if;
end $$;

revoke select (id, trial_booking_id, student_id, unit_id, is_minor, signed_at, created_at,
               has_asthma, has_heart_condition, has_diabetes, has_epilepsy, is_pregnant,
               takes_medication, has_allergies, has_recent_injury, safety_notes)
  on public.health_waivers from authenticated;
grant select on public.health_waivers to anon, authenticated;

drop policy waivers_read on storage.objects;
create policy waivers_read on storage.objects
  as permissive for select to authenticated
  using ((((bucket_id = 'waivers'::text) AND (is_admin() OR (EXISTS ( SELECT 1
   FROM (health_waivers hw
     LEFT JOIN students s ON ((s.id = hw.student_id)))
  WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))))) OR ((bucket_id = 'waivers'::text) AND (EXISTS ( SELECT 1
   FROM health_waivers hw
  WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND (hw.student_id = ANY (( SELECT guardian_student_ids() AS guardian_student_ids)::uuid[]))))))));

do $$
begin
  if (select relacl::text from pg_class where oid = 'public.health_waivers'::regclass)
       <> '{postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'
     or exists (select 1 from pg_attribute where attrelid = 'public.health_waivers'::regclass and attacl is not null) then
    raise exception '179 rollback: health_waivers grants are not the ones of before 179';
  end if;
  if (select md5(qual) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'waivers_read')
       is distinct from 'c1125fafaa8f7a1ac4fb7c1ae4e542cb' then
    raise exception '179 rollback: waivers_read is not the text of before 179';
  end if;
  if (select md5(string_agg(policyname || cmd || coalesce(qual, '') || coalesce(with_check, ''), '|' order by policyname))
        from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname <> 'waivers_read')
       is distinct from '4fd720c4037146b0b81a1ef77f66713e' then
    raise exception '179 rollback: another storage.objects policy changed';
  end if;
end $$;

commit;
