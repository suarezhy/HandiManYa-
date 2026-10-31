-- HandiMan ¡Ya! — 0056 Cancelar sin explicar el motivo.
--
-- El cliente ya no tiene que escribir por qué cancela: si no da un motivo, el
-- historial y el aviso al profesional dicen "Cancelada por el cliente". El
-- profesional sigue dando un motivo (lo lee el cliente y queda para el equipo).
-- Cancelar dos veces no crea otro registro: la segunda vez solo devuelve
-- "cancelled". Las reglas de qué se puede cancelar no cambian: una vez que el
-- profesional va en camino, el cliente no cancela desde la app (reporta un
-- problema). No cobra nada ni borra registros.

create or replace function public.cancel_booking(p_booking uuid, p_reason text) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_actor text;
begin
  select * into b from public.bookings where id = p_booking for update;
  v_actor := case when b.customer_id = auth.uid() then 'customer'
                  when b.professional_id = auth.uid() then 'professional' end;
  if v_actor is null then raise exception 'HMY_FORBIDDEN'; end if;
  -- Doble toque o dos teléfonos a la vez: ya está cancelada, no se repite.
  if b.status = 'cancelled' then return b.status; end if;
  if v_actor = 'professional' and coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  return (public._booking_move(p_booking, 'cancelled', v_actor,
                               coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Cancelada por el cliente'))).status;
end $$;
revoke execute on function public.cancel_booking(uuid, text) from public, anon;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- La solicitud: "Cancelada" (antes "Cancelado"), igual que en la app.
create or replace function public.booking_status_label(s public.booking_status) returns text
language sql immutable as $$
  select case s
    when 'draft' then 'Borrador'
    when 'requested' then 'Solicitado'
    when 'awaiting_response' then 'Esperando respuesta'
    when 'quote_sent' then 'Cotización enviada'
    when 'awaiting_confirmation' then 'Esperando confirmación'
    when 'confirmed' then 'Confirmado'
    when 'on_the_way' then 'En camino'
    when 'in_progress' then 'En progreso'
    when 'work_finished' then 'Trabajo terminado'
    when 'completed' then 'Completado'
    when 'cancelled' then 'Cancelada'
    when 'disputed' then 'En disputa'
  end
$$;
