-- 173 verify: read only.
do $$
declare
  v text := pg_get_functiondef('public.claim_profile()'::regprocedure);
  n int;
begin
  if v ~ 'where id = v_wl\.student_id;' then
    raise exception 'FAIL 1: an unguarded parent_user_id overwrite is still in claim_profile';
  end if;
  raise notice 'PASS 1: no unguarded whitelist overwrite';

  n := (length(v) - length(replace(v, 'and parent_user_id is null', ''))) / length('and parent_user_id is null');
  if n < 2 then raise exception 'FAIL 2: expected at least 2 whitelist guards, found %', n; end if;
  raise notice 'PASS 2: % parent_user_id null guards present', n;

  n := (length(v) - length(replace(v, '_guardianship_claim(v_uid, v_email)', ''))) / length('_guardianship_claim(v_uid, v_email)');
  if n <> 3 then raise exception 'FAIL 3: expected 3 guardianship claim calls, found %', n; end if;
  raise notice 'PASS 3: guardianship claim still runs in all 3 branches';

  if not exists (select 1 from public.guardianships
                  where student_id = '40a70b7b-8051-4e50-969f-363f42df2d9b' and status = 'active'
                    and guardian_user_id = 'd71f204e-9cff-4338-9e47-997202633733') then
    raise exception 'FAIL 4: John is not active on Alex';
  end if;
  raise notice 'PASS 4: John still active on Alex';
end $$;
