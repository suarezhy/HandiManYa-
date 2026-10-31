-- HandiMan ¡Ya! — 0060 dos arreglos pequeños.
--
-- 1. Aceptar una solicitud programada también bloquea al profesional mientras
--    revisa su horario. Antes, dos aceptaciones al mismo tiempo de dos
--    programadas que se cruzan terminaban en un "deadlock" de la base (la
--    restricción bookings_no_overlap ya impedía los dos trabajos); ahora una
--    gana y la otra recibe HMY_SLOT_TAKEN.
-- 2. Calificar dos veces el mismo servicio (doble toque) da HMY_ALREADY_RATED
--    en vez de un error de la base.
--
-- Solo reemplaza funciones; no cambia tablas ni datos.

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
  -- Un mismo profesional acepta una solicitud a la vez (¡Ya! o programada).
  perform 1 from public.professional_profiles where user_id = v_me for update;
  if found and b.mode = 'now' then
    if not public.hmy_pro_cleared(v_me, b.category_id) then raise exception 'HMY_PRO_NOT_CLEARED'; end if;
    if public.hmy_pro_busy_now(v_me) then raise exception 'HMY_PRO_BUSY'; end if;
  end if;
  -- La función base vuelve a revisar todo con el pedido bloqueado.
  return public._claim_ya_request_scheduled(p_booking);
end $$;

create or replace function public.submit_review(p_booking uuid, p_rating int, p_comment text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_id bigint;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found or b.customer_id <> auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if b.status <> 'completed' then raise exception 'HMY_REVIEW_NOT_ALLOWED'; end if;
  if p_rating not between 1 and 5 then raise exception 'HMY_INVALID_RATING'; end if;
  if exists (select 1 from public.reviews where booking_id = b.id) then raise exception 'HMY_ALREADY_RATED'; end if;
  insert into public.reviews (booking_id, customer_id, professional_id, rating, comment)
  values (b.id, b.customer_id, b.professional_id, p_rating, nullif(trim(p_comment), ''))
  returning id into v_id;
  perform public.notify(b.professional_id, 'review', 'Recibiste una reseña',
                        p_rating || ' de 5 estrellas', jsonb_build_object('booking_id', b.id));
  return v_id;
end $$;

revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;
revoke execute on function public.submit_review(uuid, int, text) from public, anon;
grant execute on function public.submit_review(uuid, int, text) to authenticated;
