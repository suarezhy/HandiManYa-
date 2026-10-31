-- HandiMan ¡Ya! — 0057 "Lo necesito ahora" más seguro.
--
-- 1. Un pedido ¡Ya! repetido (doble toque o reintento después de un corte de
--    red) no crea otro pedido ni vuelve a avisar a los profesionales: devuelve
--    el que ya está esperando para ese servicio.
-- 2. Un profesional con un trabajo en curso (en camino, trabajando o con un
--    pedido ¡Ya! aceptado) no recibe pedidos ¡Ya! nuevos ni puede aceptar otro.
-- 3. Al aceptar un pedido ¡Ya! se vuelve a revisar al profesional: si lo
--    suspendieron o le quitaron un documento después del aviso, no lo toma.
-- 4. Aceptar un pedido que el cliente canceló dice eso (HMY_REQUEST_CANCELLED),
--    no "otro profesional lo tomó".
--
-- Solo agrega y reemplaza funciones; no cambia tablas ni datos.

-- 2. --------------------------------------------------------------------------
-- Trabajo en curso que impide tomar un pedido ¡Ya! ahora.
create function public.hmy_pro_busy_now(p_pro uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bookings b
    where b.professional_id = p_pro
      and (b.status in ('on_the_way', 'in_progress') or (b.status = 'confirmed' and b.mode = 'now'))
  )
$$;

-- La misma lista de 0020 (bolivia_locations) y además sin trabajo en curso.
create or replace function public.ya_eligible_professionals(p_category int, p_city smallint, p_zone int, p_customer uuid,
                                                            p_latitude numeric default null, p_longitude numeric default null)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  join public.profiles pr on pr.id = pp.user_id
  left join public.professional_locations pl on pl.professional_id = pp.user_id
  where pp.status = 'approved'
    and pp.is_available
    and pr.suspended_at is null
    and pp.user_id <> p_customer
    and not public.hmy_blocked_between(pp.user_id, p_customer)
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and public.hmy_pro_cleared(pp.user_id, p_category)
    and not public.hmy_pro_busy_now(pp.user_id)
    and case
      when p_latitude is not null and pl.base_latitude is not null then
        public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) <= pl.service_radius_km
      else
        pp.city_id = p_city
        and (p_zone is null
             or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
             or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone))
    end
  order by public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) asc nulls last,
           pp.rating_avg desc, pp.available_since asc nulls last
$$;

-- 1. --------------------------------------------------------------------------
alter function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric,
  int[], text, text) rename to _create_ya_request_extras;
create function public.create_ya_request(
  p_category int,
  p_city smallint,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_problem_ids int[] default null,
  p_other_text text default null,
  p_destination text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_open uuid;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  -- Dos llamadas a la vez de la misma persona y servicio esperan una a la otra.
  perform pg_advisory_xact_lock(hashtextextended('hmy_ya:' || v_me::text || ':' || p_category::text, 0));
  select b.id into v_open from public.bookings b
  where b.customer_id = v_me and b.category_id = p_category and b.mode = 'now'
    and b.status = 'awaiting_response' and b.professional_id is null
    and public.hmy_response_deadline(b) > now()
  order by b.created_at desc
  limit 1;
  if v_open is not null then return v_open; end if;
  return public._create_ya_request_extras(p_category, p_city, p_description, p_address, p_address_reference,
    p_zone_id, p_payment_method, p_latitude, p_longitude, p_problem_ids, p_other_text, p_destination);
end $$;

-- 3 y 4. ----------------------------------------------------------------------
alter function public.claim_ya_request(uuid) rename to _claim_ya_request_scheduled;
create function public.claim_ya_request(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  b public.bookings;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into b from public.bookings where id = p_booking;
  if found and b.status = 'cancelled' then raise exception 'HMY_REQUEST_CANCELLED'; end if;
  if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if found and b.mode = 'now' then
    -- Un mismo profesional acepta un pedido ¡Ya! a la vez.
    perform 1 from public.professional_profiles where user_id = v_me for update;
    if not public.hmy_pro_cleared(v_me, b.category_id) then raise exception 'HMY_PRO_NOT_CLEARED'; end if;
    if public.hmy_pro_busy_now(v_me) then raise exception 'HMY_PRO_BUSY'; end if;
  end if;
  return public._claim_ya_request_scheduled(p_booking);
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_pro_busy_now(uuid) from public, anon, authenticated;
revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;
revoke execute on function public._create_ya_request_extras(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text) from public, anon, authenticated;
revoke execute on function public._claim_ya_request_scheduled(uuid) from public, anon, authenticated;
revoke execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text) from public, anon;
grant execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text) to authenticated;
revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;
