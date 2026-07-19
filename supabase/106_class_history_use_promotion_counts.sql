-- 106_class_history_use_promotion_counts.sql
-- Corrige dois furos da get_class_history (migration 104):
--
--  (1) Quando uma promocao consome o baseline_grade (fix v328: promover zera
--      as aulas historicas que contavam para o grade), aquelas aulas sumiam
--      da timeline — a RPC so derivava periodos do attendance real, e o
--      historico nao tem data. Caso real: Felipe, 36 aulas no 4o grau
--      (31 historicas + 5 rastreadas), virou azul e a timeline passou a
--      mostrar 5. Agora, se a promocao que FECHOU o periodo tem
--      promotions.classes gravado, esse numero manda.
--
--  (2) has_full_split de periodo fechado olhava o baseline ATUAL do aluno
--      (que zera na promocao), marcando true para periodos que tiveram
--      aulas historicas sem split — a barra gi/no-gi apareceria mostrando
--      1 gi / 4 no-gi como se fossem as 36 do periodo. Agora depende de
--      gi/nogi estarem gravados na propria promocao.
--
-- SEMANTICA DE PERIODO: cada promocao ABRE um periodo; a promocao SEGUINTE
-- o fecha. Portanto a contagem gravada numa promocao descreve o periodo que
-- ela fechou — o que comecou no marker ANTERIOR. Ao montar o periodo do
-- marker N, consulta-se classes/gi/nogi do marker N+1 (via lead()).

create or replace function public.get_class_history(p_student_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_baseline_grade numeric;
  v_result jsonb := '[]'::jsonb;
  v_m record;
  v_classes numeric;
  v_gi numeric;
  v_nogi numeric;
  v_is_current boolean;
  v_has_split boolean;
  v_marker_count int;
begin
  select coalesce(baseline_grade,0) into v_baseline_grade
  from public.students where id = p_student_id;

  select count(*) into v_marker_count
  from public.promotions where student_id = p_student_id;

  -- Sem markers: um unico periodo aberto com todo o attendance + baseline_grade.
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
      'deg',  (select degree from public.students where id=p_student_id),
      'from_date', null, 'to_date', null, 'is_current', true,
      'classes', v_classes + v_baseline_grade,
      'gi', v_gi, 'nogi', v_nogi,
      'has_full_split', (v_baseline_grade = 0)
    ));
  end if;

  for v_m in
    select p.date as marker_date, p.to_belt, p.to_deg, p.type,
           lead(p.date)    over (order by p.date) as next_date,
           lead(p.classes) over (order by p.date) as next_classes,
           lead(p.gi)      over (order by p.date) as next_gi,
           lead(p.nogi)    over (order by p.date) as next_nogi
    from public.promotions p
    where p.student_id = p_student_id
    order by p.date
  loop
    v_is_current := (v_m.next_date is null);

    if v_is_current then
      -- Periodo ABERTO: do marker ate hoje. baseline_grade (historico ainda
      -- nao consumido por nenhuma promocao) pertence a este periodo.
      select
        coalesce(sum(class_value),0),
        coalesce(sum(class_value) filter (where modality='gi'),0),
        coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
      into v_classes, v_gi, v_nogi
      from public.attendance
      where student_id = p_student_id and status='present'
        and class_date > v_m.marker_date;

      v_classes := v_classes + v_baseline_grade;
      v_has_split := (v_baseline_grade = 0);

    elsif v_m.next_classes is not null then
      -- Periodo FECHADO com contagem gravada na promocao que o fechou.
      v_classes := v_m.next_classes;
      v_gi   := coalesce(v_m.next_gi,0);
      v_nogi := coalesce(v_m.next_nogi,0);
      v_has_split := (v_m.next_gi is not null and v_m.next_nogi is not null);

    else
      -- Periodo FECHADO sem contagem gravada: deriva do attendance real
      -- entre este marker e o proximo.
      select
        coalesce(sum(class_value),0),
        coalesce(sum(class_value) filter (where modality='gi'),0),
        coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
      into v_classes, v_gi, v_nogi
      from public.attendance
      where student_id = p_student_id and status='present'
        and class_date > v_m.marker_date
        and class_date <= v_m.next_date;

      v_has_split := true;
    end if;

    v_result := v_result || jsonb_build_object(
      'belt', v_m.to_belt,
      'deg',  v_m.to_deg,
      'type', v_m.type,
      'from_date', v_m.marker_date,
      'to_date',   v_m.next_date,
      'is_current', v_is_current,
      'classes', v_classes,
      'gi', v_gi, 'nogi', v_nogi,
      'has_full_split', v_has_split
    );
  end loop;

  return v_result;
end;
$$;
