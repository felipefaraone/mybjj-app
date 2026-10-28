-- 179_waiver_lock.sql
--
-- The lock after 178 (decision 27 Oct 2026: only Patricia, Mario and the admin
-- account read the FULL waiver). Needs 178 applied and the app reading through
-- 178's RPCs (index.html v644) deployed first.
--
--   1. public.health_waivers: SELECT revoked from authenticated and anon; SELECT
--      granted back to authenticated on the alert-safe columns only (id,
--      trial_booking_id, student_id, unit_id, is_minor, signed_at, created_at,
--      the 8 flags, safety_notes). hw_select is NOT changed (it stays the row
--      rule), so no client reads answers / emergency_* / signature_path /
--      signed_by_* / participant_name / waiver_text_version directly any more,
--      not even a reader or the member: the full document comes only through
--      waiver_document (178). INSERT / UPDATE / DELETE grants and the
--      hw_insert / hw_update / hw_delete policies are untouched (the trial
--      conversion's UPDATE ... WHERE trial_booking_id / student_id only needs
--      those two columns, which stay readable).
--   2. storage.objects, policy waivers_read (bucket 'waivers', the signature
--      images) only: is_admin() becomes can_read_full_waiver(); the owner /
--      parent and active-guardian branches stay exactly as they are. Every other
--      storage policy (avatars_*, waivers_delete / _update / _write) untouched.
--
-- Before 179 (dumped live 28 Oct 2026, restored exactly by the rollback):
--   health_waivers relacl
--     {postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}
--     no column privileges
--   storage.objects waivers_read (PERMISSIVE, SELECT, {authenticated}), qual md5 c1125fafaa8f7a1ac4fb7c1ae4e542cb:
--     (((bucket_id = 'waivers'::text) AND (is_admin() OR (EXISTS ( SELECT 1
--        FROM (health_waivers hw
--          LEFT JOIN students s ON ((s.id = hw.student_id)))
--       WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))))) OR ((bucket_id = 'waivers'::text) AND (EXISTS ( SELECT 1
--        FROM health_waivers hw
--       WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND (hw.student_id = ANY (( SELECT guardian_student_ids() AS guardian_student_ids)::uuid[])))))))
--   the other 7 storage.objects policies: md5 4fd720c4037146b0b81a1ef77f66713e
--
-- Edge Functions are unaffected: waiver-submit (the only one that touches
-- health_waivers and the waivers bucket) uses the service_role client.
-- Run with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/179_waiver_lock.sql

begin;

do $$
begin
  if to_regprocedure('public.can_read_full_waiver()') is null
     or to_regprocedure('public.waiver_document(uuid,uuid)') is null
     or to_regprocedure('public.waiver_alerts(uuid)') is null
     or to_regprocedure('public.waiver_trial_link_check(uuid)') is null
     or to_regprocedure('public.waiver_trial_prefill(uuid)') is null then
    raise exception '179 preflight: 178 is not applied';
  end if;
  if (select relacl::text from pg_class where oid = 'public.health_waivers'::regclass)
       <> '{postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}'
     or exists (select 1 from pg_attribute where attrelid = 'public.health_waivers'::regclass and attacl is not null) then
    raise exception '179 preflight: health_waivers grants are not the ones dumped before 179; stop and compare';
  end if;
  if (select md5(qual) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'waivers_read')
       is distinct from 'c1125fafaa8f7a1ac4fb7c1ae4e542cb' then
    raise exception '179 preflight: storage waivers_read is not the policy dumped before 179; stop and compare';
  end if;
  if (select md5(string_agg(policyname || cmd || coalesce(qual, '') || coalesce(with_check, ''), '|' order by policyname))
        from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname <> 'waivers_read')
       is distinct from '4fd720c4037146b0b81a1ef77f66713e' then
    raise exception '179 preflight: the other storage.objects policies changed since the dump; stop and compare';
  end if;
end $$;

-- 1. health_waivers: the alert-safe columns only ------------------------------
revoke select on public.health_waivers from authenticated, anon;
grant select (id, trial_booking_id, student_id, unit_id, is_minor, signed_at, created_at,
              has_asthma, has_heart_condition, has_diabetes, has_epilepsy, is_pregnant,
              takes_medication, has_allergies, has_recent_injury, safety_notes)
  on public.health_waivers to authenticated;

-- 2. storage: signatures for readers, the owner / parent and active guardians ----
drop policy waivers_read on storage.objects;
create policy waivers_read on storage.objects
  as permissive for select to authenticated
  using (
    ((bucket_id = 'waivers'::text) AND (public.can_read_full_waiver() OR (EXISTS ( SELECT 1
       FROM (public.health_waivers hw
         LEFT JOIN public.students s ON ((s.id = hw.student_id)))
      WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))))
    OR ((bucket_id = 'waivers'::text) AND (EXISTS ( SELECT 1
       FROM public.health_waivers hw
      WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND (hw.student_id = ANY (( SELECT public.guardian_student_ids() AS guardian_student_ids)::uuid[]))))))
  );

do $$
declare
  c text;
begin
  if has_table_privilege('authenticated', 'public.health_waivers', 'select')
     or has_table_privilege('anon', 'public.health_waivers', 'select')
     or not has_table_privilege('authenticated', 'public.health_waivers', 'insert')
     or not has_table_privilege('authenticated', 'public.health_waivers', 'update')
     or not has_table_privilege('authenticated', 'public.health_waivers', 'delete')
     or not has_table_privilege('service_role', 'public.health_waivers', 'select') then
    raise exception '179: table grants are not as intended';
  end if;
  for c in select attname from pg_attribute where attrelid = 'public.health_waivers'::regclass and attnum > 0 and not attisdropped loop
    if has_column_privilege('authenticated', 'public.health_waivers', c, 'select')
         <> (c in ('id', 'trial_booking_id', 'student_id', 'unit_id', 'is_minor', 'signed_at', 'created_at',
                   'has_asthma', 'has_heart_condition', 'has_diabetes', 'has_epilepsy', 'is_pregnant',
                   'takes_medication', 'has_allergies', 'has_recent_injury', 'safety_notes'))
       or has_column_privilege('anon', 'public.health_waivers', c, 'select') then
      raise exception '179: column grant of % is not as intended', c;
    end if;
  end loop;
  if (select md5(string_agg(policyname || cmd || coalesce(qual, '') || coalesce(with_check, ''), '|' order by policyname))
        from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname <> 'waivers_read')
       is distinct from '4fd720c4037146b0b81a1ef77f66713e' then
    raise exception '179: another storage.objects policy changed';
  end if;
end $$;

commit;
