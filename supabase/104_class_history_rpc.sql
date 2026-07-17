-- 104_class_history_rpc.sql
-- Class History Timeline (Fase 1) — RPC que retorna as aulas do aluno
-- agrupadas por PERÍODO (entre markers de promoção), com split gi/no-gi.
--
-- Modelo:
--  - Cada marker (linha em promotions) inicia um período. O período vai da
--    data do marker até o próximo marker (ou hoje, para o período atual).
--  - As aulas reais (attendance) são somadas por período via class_date,
--    com split por modality ('gi' vs 'nogi'/'mma').
--  - O baseline_grade (aulas históricas pré-app DESDE O ÚLTIMO STRIPE, sem
--    data e sem split) é somado APENAS ao período atual. Usa baseline_grade,
--    NÃO baseline_total (que é vida toda e incluiria aulas de faixas anteriores).
--  - has_full_split = true só quando o período não tem baseline sem split,
--    sinalizando ao frontend que a barra 100% gi/no-gi pode aparecer.
--
-- O frontend consome granular (um item por marker) e consolida:
-- faixas passadas viram uma barra por faixa; a faixa atual mostra stripes.

create or replace function public.get_class_history(p_student_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_baseline_grade numeric;
  v_result jsonb := '[]'::jsonb;
  v_markers record;
  v_period_start date;
  v_period_end date;
  v_classes numeric;
  v_gi numeric;
  v_nogi numeric;
  v_is_current boolean;
  v_marker_count int;
begin
  select coalesce(baseline_grade,0) into v_baseline_grade
  from public.students where id = p_student_id;

  select count(*) into v_marker_count
  from public.promotions where student_id = p_student_id;

  -- sem markers: um único período atual com attendance + baseline_grade
  if v_marker_count = 0 then
    select
      coalesce(sum(class_value),0),
      coalesce(sum(class_value) filter (where modality='gi'),0),
      coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
    into v_classes, v_gi, v_nogi
    from public.attendance
    where student_id = p_student_id and status='present';

    return jsonb_build_array(jsonb_build_object(
      'belt', (select belt from public.students where id=p_student_id),
      'deg', (select degree from public.students where id=p_student_id),
      'from_date', null,
      'to_date', null,
      'is_current', true,
      'classes', v_classes + v_baseline_grade,
      'gi', v_gi,
      'nogi', v_nogi,
      'has_full_split', (v_baseline_grade = 0)
    ));
  end if;

  -- com markers: um período por marker
  for v_markers in
    select p.date as marker_date, p.to_belt, p.to_deg, p.type,
           lead(p.date) over (order by p.date) as next_date
    from public.promotions p
    where p.student_id = p_student_id
    order by p.date
  loop
    v_period_start := v_markers.marker_date;
    v_is_current := (v_markers.next_date is null);
    v_period_end := coalesce(v_markers.next_date, current_date);

    select
      coalesce(sum(class_value),0),
      coalesce(sum(class_value) filter (where modality='gi'),0),
      coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
    into v_classes, v_gi, v_nogi
    from public.attendance
    where student_id = p_student_id and status='present'
      and class_date > v_period_start
      and (v_markers.next_date is null or class_date <= v_period_end);

    if v_is_current then
      v_classes := v_classes + v_baseline_grade;
    end if;

    v_result := v_result || jsonb_build_object(
      'belt', v_markers.to_belt,
      'deg', v_markers.to_deg,
      'type', v_markers.type,
      'from_date', v_period_start,
      'to_date', case when v_is_current then null else v_period_end end,
      'is_current', v_is_current,
      'classes', v_classes,
      'gi', v_gi,
      'nogi', v_nogi,
      'has_full_split', (case when v_is_current then v_baseline_grade = 0 else true end)
    );
  end loop;

  return v_result;
end;
$$;
