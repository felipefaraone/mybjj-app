-- 105_promotions_class_counts.sql
-- Fase 2 do Class History: o historico de aulas por faixa mora nas PROMOTIONS.
-- Cada promocao passa a poder carregar as aulas feitas no periodo que ela FECHOU.
-- Periodo aberto (faixa atual) continua no students.baseline_grade — sem duplicacao.
-- gi/nogi ficam nullable e SEM campo na tela (cartoes pre-app nao separam);
-- existem para nao exigir migracao no dia em que houver o dado.

alter table public.promotions
  add column if not exists classes numeric,
  add column if not exists gi numeric,
  add column if not exists nogi numeric;

comment on column public.promotions.classes is
  'Aulas feitas no periodo que esta promocao fechou (historico pre-app). Null = desconhecido.';
comment on column public.promotions.gi is
  'Split gi do periodo. Null quando o periodo nao foi 100% rastreado.';
comment on column public.promotions.nogi is
  'Split no-gi do periodo. Null quando o periodo nao foi 100% rastreado.';
