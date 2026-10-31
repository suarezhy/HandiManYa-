-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0046
-- (20261023004600_booking_deadlines) en el proyecto de DESARROLLO. Los pedidos
-- que ya vencieron quedan cancelados (o confirmados, los de 72 horas): es su
-- estado correcto. Después de revertir, un pedido vencido vuelve a poder
-- aceptarse tarde.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0046_booking_deadlines.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if to_regprocedure('public.expire_my_overdue_bookings()') is null then
    raise exception 'HMY: 0046 no está aplicada; no se revirtió nada.';
  end if;
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'hmy-booking-housekeeping'$q$;
  end if;
end $$;
drop trigger bookings_deadline_guard on public.bookings;
drop function public.hmy_booking_deadline_guard();
drop function public.expire_my_overdue_bookings();
-- La limpieza vuelve a la versión de 0007.
create or replace function public.run_booking_housekeeping() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from public.bookings where status = 'requested' and response_deadline < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Sin respuesta del profesional a tiempo');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'awaiting_response' and response_deadline < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Ningún profesional aceptó a tiempo. Puedes intentar de nuevo o programar para después.');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'work_finished' and finished_at < now() - interval '72 hours' loop
    perform public._booking_move(r.id, 'completed', 'system', 'Confirmado automáticamente después de 72 horas');
    n := n + 1;
  end loop;
  return n;
end $$;
drop function public.hmy_response_deadline(public.bookings);
delete from supabase_migrations.schema_migrations where version = '20261023004600';
commit;
\echo 'Reversión de 0046 terminada.'
