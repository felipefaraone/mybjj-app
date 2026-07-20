-- 108_bring_a_friend.sql
-- Bring a Friend no formulario de trial.
--
-- O convidado vira uma RESERVA DE VERDADE: linha propria em trial_bookings,
-- waiver_token proprio, aparece na aula, converte em aluno pelo caminho normal.
-- Um nome anotado no booking de outra pessoa faria o amigo chegar sem waiver
-- assinado — exatamente o que o sistema de trial existe para evitar.
--
-- email/phone viram nullable porque quem convida raramente sabe os DOIS de
-- cabeca. Exigir ambos faria a pessoa inventar dado ou desistir. A validacao
-- de "pelo menos um" fica na Edge Function trial-booking.
--
-- ATENCAO: sem email o app nao consegue avisar o convidado (nao ha SMS). A
-- reserva existe e o staff a ve, mas quem convida precisa falar com o amigo —
-- a tela do trial diz isso explicitamente.

alter table public.trial_bookings
  alter column email drop not null,
  alter column phone drop not null,
  add column if not exists invited_by_booking_id uuid
    references public.trial_bookings(id) on delete set null;

comment on column public.trial_bookings.invited_by_booking_id is
  'Reserva de quem convidou (Bring a Friend). SET NULL: se a reserva original sumir, a do convidado sobrevive.';
