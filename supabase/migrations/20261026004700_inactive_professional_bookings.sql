-- HandiMan ¡Ya! — 0047 un profesional suspendido no sigue con sus pedidos.
--
-- Antes: suspender a un profesional (o pedirle que se verifique de nuevo, o
-- rechazarlo) lo sacaba de las búsquedas y del ¡Ya!, pero sus pedidos abiertos
-- seguían igual. Podía aceptar un pedido que ya tenía, ir "en camino" y ver la
-- dirección del cliente. Lo mismo con un cliente suspendido: el profesional
-- seguía yendo a su casa.
--
-- Ahora:
-- 1. Solo un profesional aprobado y con la cuenta activa acepta, cotiza, sale
--    o empieza un trabajo (HMY_PROFESSIONAL_NOT_APPROVED). Terminar un trabajo
--    que ya empezó, o abrir una disputa, sigue permitido: si no, el pedido
--    quedaría trabado.
-- 2. Cuando un profesional deja de estar aprobado, sus pedidos que todavía no
--    empezaron se cancelan y el cliente recibe un aviso para pedir a otro. El
--    aviso no dice el motivo. Sus ofertas ¡Ya! pendientes se cierran.
-- 3. Cuando se suspende una cuenta, sus pedidos que no empezaron se cancelan,
--    como cliente y como profesional.
-- 4. La dirección del cliente solo la ve un profesional aprobado y activo, o
--    uno que ya está en el lugar (trabajo empezado o terminado).
-- Los trabajos ya empezados no se tocan: el equipo los ve en el panel y el
-- cliente puede abrir una disputa.

-- La cancelación la hace el sistema, desde estos estados.
insert into public.booking_transitions values
  ('quote_sent', 'cancelled', 'system'),
  ('confirmed', 'cancelled', 'system'),
  ('on_the_way', 'cancelled', 'system')
on conflict do nothing;

create function public.hmy_professional_active(p_pro uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.professional_profiles where user_id = p_pro and status = 'approved')
     and not public.is_suspended(p_pro)
$$;

-- 1. -------------------------------------------------------------------------
create function public.hmy_booking_pro_active_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status
     and new.status in ('confirmed', 'quote_sent', 'on_the_way', 'in_progress')
     and new.professional_id is not null
     and not public.hmy_professional_active(new.professional_id) then
    raise exception 'HMY_PROFESSIONAL_NOT_APPROVED';
  end if;
  return new;
end $$;

create trigger bookings_pro_active_guard before update of status on public.bookings
  for each row execute function public.hmy_booking_pro_active_guard();

-- 2 y 3. ---------------------------------------------------------------------
-- Cancela los pedidos de p_user que todavía no empezaron. p_as: 'professional'
-- o 'customer' (de qué lado está la cuenta que ya no puede seguir).
create function public.hmy_cancel_unstarted_bookings(p_user uuid, p_as text) returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select b.id from public.bookings b
    where b.status in ('requested', 'awaiting_response', 'quote_sent', 'confirmed', 'on_the_way')
      and ((p_as = 'professional' and b.professional_id = p_user) or (p_as = 'customer' and b.customer_id = p_user))
    order by b.created_at
    for update of b
  loop
    perform public._booking_move(r.id, 'cancelled', 'system',
      case when p_as = 'professional'
           then 'El profesional ya no está disponible. Cancelamos esta solicitud: puedes pedir a otro profesional.'
           else 'La cuenta del cliente no está activa. Cancelamos esta solicitud.' end);
    update public.bookings set cancelled_by = null where id = r.id;
    n := n + 1;
  end loop;
  if p_as = 'professional' then
    update public.booking_offers set status = 'expired', responded_at = now()
    where professional_id = p_user and status = 'pending';
  end if;
  return n;
end $$;

create function public.hmy_pro_inactive_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'approved' and new.status is distinct from 'approved' then
    perform public.hmy_cancel_unstarted_bookings(new.user_id, 'professional');
  end if;
  return new;
end $$;

create trigger professional_profiles_inactive_cleanup after update of status on public.professional_profiles
  for each row execute function public.hmy_pro_inactive_cleanup();

create function public.hmy_suspension_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.suspended_at is null and new.suspended_at is not null then
    perform public.hmy_cancel_unstarted_bookings(new.id, 'customer');
    perform public.hmy_cancel_unstarted_bookings(new.id, 'professional');
  end if;
  return new;
end $$;

create trigger profiles_suspension_cleanup after update of suspended_at on public.profiles
  for each row execute function public.hmy_suspension_cleanup();

-- 4. -------------------------------------------------------------------------
create or replace function public.can_see_booking_address(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bookings b
    where b.id = p_booking and (
      b.customer_id = auth.uid()
      or public.is_admin()
      or (b.professional_id = auth.uid()
          and (b.status in ('in_progress', 'work_finished')
               or (b.status in ('confirmed', 'on_the_way', 'disputed') and public.hmy_professional_active(auth.uid()))))
    )
  )
$$;

revoke execute on function public.hmy_professional_active(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_booking_pro_active_guard() from public, anon, authenticated;
revoke execute on function public.hmy_cancel_unstarted_bookings(uuid, text) from public, anon, authenticated;
revoke execute on function public.hmy_pro_inactive_cleanup() from public, anon, authenticated;
revoke execute on function public.hmy_suspension_cleanup() from public, anon, authenticated;
