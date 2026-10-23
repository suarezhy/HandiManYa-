-- HandiMan ¡Ya! — 0046 los pedidos sin respuesta vencen de verdad.
--
-- Antes: run_booking_housekeeping() (cancela pedidos sin respuesta y confirma
-- trabajos terminados hace 72 h) existía pero nada la corría. Un pedido ¡Ya!
-- quedaba "esperando" para siempre, un profesional podía aceptarlo horas
-- después de vencido, y esos pedidos contaban para el máximo de 5 abiertos.
--
-- Además, un pedido programado tenía 12 horas para responder aunque la cita
-- fuera antes: se podía aceptar con la hora del trabajo ya pasada.
--
-- Ahora:
-- 1. Nadie acepta ni cotiza un pedido vencido (HMY_REQUEST_EXPIRED), corra o
--    no la limpieza. Un pedido vence a su plazo o a la hora de la cita, lo
--    que llegue primero.
-- 2. expire_my_overdue_bookings(): la app la llama al abrir sus pedidos y antes
--    de pedir; vence solo los pedidos de quien llama.
-- 3. Si el proyecto tiene pg_cron, la limpieza corre cada minuto.

-- 1. -------------------------------------------------------------------------
-- Hasta cuándo se puede responder un pedido.
create function public.hmy_response_deadline(b public.bookings) returns timestamptz
language sql immutable as $$
  select case when b.mode = 'scheduled' and b.scheduled_start is not null
              then least(b.response_deadline, b.scheduled_start)
              else b.response_deadline end
$$;

create function public.hmy_booking_deadline_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status in ('requested', 'awaiting_response')
     and new.status in ('confirmed', 'quote_sent')
     and public.hmy_response_deadline(old) < now() then
    raise exception 'HMY_REQUEST_EXPIRED';
  end if;
  return new;
end $$;

create trigger bookings_deadline_guard before update of status on public.bookings
  for each row execute function public.hmy_booking_deadline_guard();

revoke execute on function public.hmy_booking_deadline_guard() from public, anon, authenticated;
revoke execute on function public.hmy_response_deadline(public.bookings) from public, anon, authenticated;

-- La limpieza programada usa el mismo plazo.
create or replace function public.run_booking_housekeeping() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select b.id from public.bookings b where b.status = 'requested' and public.hmy_response_deadline(b) < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Sin respuesta del profesional a tiempo');
    n := n + 1;
  end loop;
  for r in select b.id from public.bookings b where b.status = 'awaiting_response' and public.hmy_response_deadline(b) < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Ningún profesional aceptó a tiempo. Puedes intentar de nuevo o programar para después.');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'work_finished' and finished_at < now() - interval '72 hours' loop
    perform public._booking_move(r.id, 'completed', 'system', 'Confirmado automáticamente después de 72 horas');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 2. -------------------------------------------------------------------------
create function public.expire_my_overdue_bookings() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  for r in
    select b.id, b.status from public.bookings b
    where ((b.status in ('requested', 'awaiting_response') and public.hmy_response_deadline(b) < now())
           or (b.status = 'work_finished' and b.finished_at < now() - interval '72 hours'))
      and (b.customer_id = auth.uid() or b.professional_id = auth.uid()
           or exists (select 1 from public.booking_offers o
                      where o.booking_id = b.id and o.professional_id = auth.uid()))
    for update of b skip locked
  loop
    -- Mismos textos que run_booking_housekeeping().
    if r.status = 'requested' then
      perform public._booking_move(r.id, 'cancelled', 'system', 'Sin respuesta del profesional a tiempo');
    elsif r.status = 'awaiting_response' then
      perform public._booking_move(r.id, 'cancelled', 'system',
        'Ningún profesional aceptó a tiempo. Puedes intentar de nuevo o programar para después.');
    else
      perform public._booking_move(r.id, 'completed', 'system', 'Confirmado automáticamente después de 72 horas');
    end if;
    -- Lo hizo el sistema, no quien abrió la app: igual que cuando corre la
    -- limpieza programada (sin sesión).
    update public.bookings set cancelled_by = null where id = r.id;
    update public.booking_events set actor_id = null
    where id = (select max(id) from public.booking_events where booking_id = r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.expire_my_overdue_bookings() from public, anon;
grant execute on function public.expire_my_overdue_bookings() to authenticated;

-- 3. -------------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('hmy-booking-housekeeping', '* * * * *', 'select public.run_booking_housekeeping()');
    raise notice 'Programación activada: pedidos vencidos cada minuto.';
  else
    raise notice 'pg_cron no está disponible: los pedidos vencen al abrirlos en la app.';
  end if;
end $$;
