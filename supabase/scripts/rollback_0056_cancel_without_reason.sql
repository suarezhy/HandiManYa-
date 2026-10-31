-- Vuelve cancel_booking a como estaba antes de 0056 (motivo obligatorio para todos).
create or replace function public.cancel_booking(p_booking uuid, p_reason text) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare v_actor text;
begin
  select case when customer_id = auth.uid() then 'customer'
              when professional_id = auth.uid() then 'professional' end
  into v_actor from public.bookings where id = p_booking;
  if v_actor is null then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  return (public._booking_move(p_booking, 'cancelled', v_actor, p_reason)).status;
end $$;
revoke execute on function public.cancel_booking(uuid, text) from public, anon;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- Etiqueta anterior.
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
    when 'cancelled' then 'Cancelado'
    when 'disputed' then 'En disputa'
  end
$$;
