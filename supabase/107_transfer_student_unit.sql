-- 107_transfer_student_unit.sql
-- Mover aluno entre unidades.
--
-- A policy students_write exige (is_admin() OR (is_staff() AND unit_id = current_unit())).
-- O with_check avalia o estado FINAL da linha, entao um staff que nao seja owner
-- nunca consegue gravar unit_id de outra unidade — a transferencia e exatamente a
-- operacao que a RLS por unidade foi desenhada para impedir. Isso esta correto;
-- a transferencia e uma excecao explicita via security definer, com o mesmo gate
-- de update_class_counts: owner (is_unit_owner_any) OU staff faixa-preta.
--
-- Caso real (20 Jul 2026): Artur Soldan cadastrado em Neutral Bay em vez de HQ.
-- John (staff, nao owner) nao conseguia corrigir pelo app.

create or replace function public.transfer_student_unit(
  p_legacy_id text,
  p_unit_id uuid
)
returns public.students
language plpgsql
security definer
set search_path = public
as $$
declare
  v_belt text;
  v_student public.students;
  v_from_unit uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not public.is_unit_owner_any() then
    if not public.is_staff() then
      raise exception 'not authorised: only owner or professor can transfer students';
    end if;
    select s.belt into v_belt from public.staff s where s.user_id = auth.uid() limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can transfer students';
    end if;
  end if;

  select id into v_from_unit from public.units where id = p_unit_id and active is not false;
  if v_from_unit is null then
    raise exception 'target unit not found or inactive';
  end if;

  select unit_id into v_from_unit from public.students where legacy_id = p_legacy_id;
  if v_from_unit is null then
    raise exception 'student % not found', p_legacy_id;
  end if;

  if v_from_unit = p_unit_id then
    raise exception 'student is already in that unit';
  end if;

  update public.students
  set unit_id = p_unit_id
  where legacy_id = p_legacy_id;

  select * into v_student from public.students where legacy_id = p_legacy_id;
  return v_student;
end;
$$;

revoke all on function public.transfer_student_unit(text, uuid) from public;
grant execute on function public.transfer_student_unit(text, uuid) to authenticated;
