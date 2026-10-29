-- HandiMan ¡Ya! — 0058 orden de los avisos al aceptar un pedido ¡Ya!.
--
-- Si el pedido ya lo tomó alguien (incluso el mismo profesional), el mensaje
-- es "otro profesional lo tomó" (HMY_ALREADY_TAKEN) antes que "tienes un
-- trabajo en curso" (HMY_PRO_BUSY). Las mismas revisiones de 0057, en otro
-- orden. Solo reemplaza la función; no cambia tablas ni datos.

create or replace function public.claim_ya_request(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  b public.bookings;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into b from public.bookings where id = p_booking;
  if found and b.status = 'cancelled' then raise exception 'HMY_REQUEST_CANCELLED'; end if;
  if found and (b.status <> 'awaiting_response' or b.professional_id is not null) then
    raise exception 'HMY_ALREADY_TAKEN';
  end if;
  if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if found and b.mode = 'now' then
    -- Un mismo profesional acepta un pedido ¡Ya! a la vez.
    perform 1 from public.professional_profiles where user_id = v_me for update;
    if not public.hmy_pro_cleared(v_me, b.category_id) then raise exception 'HMY_PRO_NOT_CLEARED'; end if;
    if public.hmy_pro_busy_now(v_me) then raise exception 'HMY_PRO_BUSY'; end if;
  end if;
  -- La función base vuelve a revisar todo con el pedido bloqueado.
  return public._claim_ya_request_scheduled(p_booking);
end $$;

revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;
