-- HandiMan ¡Ya! — 0008 ubicación real (GPS), distancia y fotos.
--
-- Privacidad: la ubicación exacta del cliente sigue solo en
-- booking_addresses (cliente, admin y profesional asignado en un trabajo
-- activo). Para elegir y avisar a profesionales se usa un punto aproximado
-- (redondeado a ~1 km) que se guarda en bookings.

-- ---------------------------------------------------------------------------
-- Distancia
-- ---------------------------------------------------------------------------
create function public.hmy_distance_km(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns numeric
language sql immutable parallel safe as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null else
    round((6371 * 2 * asin(sqrt(
      power(sin(radians((lat2 - lat1)::float8) / 2), 2)
      + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2)
    )))::numeric, 1) end
$$;

create function public.hmy_valid_point(p_lat numeric, p_lng numeric) returns boolean
language sql immutable as $$
  -- Bolivia y alrededores; evita coordenadas basura.
  select (p_lat is null and p_lng is null)
      or (p_lat between -23.5 and -9.0 and p_lng between -70.0 and -57.0)
$$;

-- ---------------------------------------------------------------------------
-- Base y radio de trabajo del profesional
-- ---------------------------------------------------------------------------
-- Tabla aparte: la base puede ser el domicilio del profesional, así que
-- solo la ve su dueño (y el servidor para calcular distancias).
create table public.professional_locations (
  professional_id uuid primary key references public.professional_profiles(user_id) on delete cascade,
  base_latitude numeric(9,6) not null,
  base_longitude numeric(9,6) not null,
  service_radius_km smallint not null default 10 check (service_radius_km between 1 and 50),
  updated_at timestamptz not null default now(),
  constraint professional_base_valid check (public.hmy_valid_point(base_latitude, base_longitude))
);
alter table public.professional_locations enable row level security;
create policy professional_locations_own on public.professional_locations for select
  using (professional_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.professional_locations from anon, authenticated;

create function public.set_service_location(p_latitude numeric, p_longitude numeric, p_radius_km int default 10)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not public.hmy_valid_point(p_latitude, p_longitude) then raise exception 'HMY_INVALID_LOCATION'; end if;
  if p_radius_km is null or p_radius_km not between 1 and 50 then raise exception 'HMY_INVALID_RADIUS'; end if;
  if p_latitude is null then raise exception 'HMY_INVALID_LOCATION'; end if;
  if not exists (select 1 from public.professional_profiles where user_id = auth.uid()) then
    raise exception 'HMY_NO_APPLICATION';
  end if;
  insert into public.professional_locations (professional_id, base_latitude, base_longitude, service_radius_km)
  values (auth.uid(), round(p_latitude, 6), round(p_longitude, 6), p_radius_km)
  on conflict (professional_id) do update
  set base_latitude = excluded.base_latitude, base_longitude = excluded.base_longitude,
      service_radius_km = excluded.service_radius_km, updated_at = now();
end $$;

-- ---------------------------------------------------------------------------
-- Punto aproximado de la solicitud
-- ---------------------------------------------------------------------------
alter table public.bookings
  add column approx_latitude numeric(6,2),
  add column approx_longitude numeric(6,2);

alter table public.booking_addresses
  add constraint booking_address_point_valid check (public.hmy_valid_point(latitude, longitude));

create function public.set_booking_approx_point() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.bookings
  set approx_latitude = round(new.latitude, 2), approx_longitude = round(new.longitude, 2)
  where id = new.booking_id;
  return new;
end $$;

create trigger booking_addresses_approx
after insert or update of latitude, longitude on public.booking_addresses
for each row execute function public.set_booking_approx_point();

-- ---------------------------------------------------------------------------
-- ¡Ya! con distancia: si el pedido y el profesional tienen ubicación, manda
-- el radio del profesional; si no, se usa la zona como antes.
-- ---------------------------------------------------------------------------
drop function public.count_ya_available(int, smallint, int);
drop function public.ya_eligible_professionals(int, smallint, int, uuid);

create function public.ya_eligible_professionals(p_category int, p_city smallint, p_zone int, p_customer uuid,
                                                 p_latitude numeric default null, p_longitude numeric default null)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  left join public.professional_locations pl on pl.professional_id = pp.user_id
  where pp.status = 'approved'
    and pp.is_available
    and pp.user_id <> p_customer
    and pp.city_id = p_city
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and case
      when p_latitude is not null and pl.base_latitude is not null then
        public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) <= pl.service_radius_km
      else
        p_zone is null
        or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
        or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone)
    end
  order by public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) asc nulls last,
           pp.rating_avg desc, pp.available_since asc nulls last
  limit 25
$$;

create function public.count_ya_available(p_category int, p_city smallint, p_zone int default null,
                                          p_latitude numeric default null, p_longitude numeric default null)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.ya_eligible_professionals(
    p_category, p_city, p_zone, coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'),
    round(p_latitude, 2), round(p_longitude, 2))
$$;

create or replace function public.create_ya_request(
  p_category int,
  p_city smallint,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_pro uuid;
  -- Se busca con el punto aproximado, igual que verán los profesionales.
  v_lat numeric := round(p_latitude, 2);
  v_lng numeric := round(p_longitude, 2);
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not public.hmy_valid_point(p_latitude, p_longitude) then raise exception 'HMY_INVALID_LOCATION'; end if;
  if p_zone_id is not null and not exists (select 1 from public.service_zones where id = p_zone_id and city_id = p_city) then
    raise exception 'HMY_INVALID_ZONE';
  end if;
  if (select count(*) from public.bookings
      where customer_id = auth.uid() and status in ('requested', 'awaiting_response', 'quote_sent')) >= 5 then
    raise exception 'HMY_TOO_MANY_OPEN_REQUESTS';
  end if;
  if not exists (select 1 from public.ya_eligible_professionals(p_category, p_city, p_zone_id, auth.uid(), v_lat, v_lng)) then
    raise exception 'HMY_NO_PROFESSIONALS_AVAILABLE';
  end if;

  insert into public.bookings (customer_id, professional_id, category_id, city_id, zone_id, mode,
                               description, status, response_deadline, payment_method)
  values (auth.uid(), null, p_category, p_city, p_zone_id, 'now', trim(p_description), 'awaiting_response',
          now() + interval '10 minutes', p_payment_method)
  returning id into v_id;

  insert into public.booking_addresses (booking_id, address_line, reference, latitude, longitude)
  values (v_id, trim(p_address), p_address_reference, p_latitude, p_longitude);

  insert into public.booking_events (booking_id, from_status, to_status, actor_id)
  values (v_id, null, 'awaiting_response', auth.uid());

  for v_pro in select * from public.ya_eligible_professionals(p_category, p_city, p_zone_id, auth.uid(), v_lat, v_lng) loop
    insert into public.booking_offers (booking_id, professional_id) values (v_id, v_pro);
    perform public.notify(v_pro, 'ya_offer', '¡Pedido ¡Ya! cerca de ti!', left(trim(p_description), 140),
                          jsonb_build_object('booking_id', v_id));
  end loop;
  return v_id;
end $$;

-- Distancia aproximada (km) del pedido a la base del profesional que consulta.
create function public.booking_distance_for_me(p_booking uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select public.hmy_distance_km(b.approx_latitude, b.approx_longitude, pl.base_latitude, pl.base_longitude)
  from public.bookings b
  join public.professional_locations pl on pl.professional_id = auth.uid()
  where b.id = p_booking
    and (b.professional_id = auth.uid() or public.has_pending_offer(b.id))
$$;

-- ---------------------------------------------------------------------------
-- Fotos del problema
-- ---------------------------------------------------------------------------
-- El profesional que recibió la oferta puede ver las fotos del problema para
-- decidir (no ve la dirección).
create policy booking_photos_offer_read on public.booking_photos for select
  using (kind = 'problem' and public.has_pending_offer(booking_id));

create policy "hmy booking photos offer read" on storage.objects for select to authenticated
  using (bucket_id = 'booking-photos'
         and public.has_pending_offer(public.uuid_or_null(public.storage_owner_folder(name))));

create function public.limit_booking_photos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.storage_path not like new.booking_id::text || '/%' then raise exception 'HMY_INVALID_PATH'; end if;
  if (select count(*) from public.booking_photos where booking_id = new.booking_id and kind = new.kind) >= 5 then
    raise exception 'HMY_TOO_MANY_PHOTOS';
  end if;
  return new;
end $$;

create trigger booking_photos_limit before insert on public.booking_photos
for each row execute function public.limit_booking_photos();

-- ---------------------------------------------------------------------------
-- Comprobante de recarga: solo una ruta dentro de la carpeta del profesional.
-- ---------------------------------------------------------------------------
create or replace function public.request_topup(p_amount numeric, p_method int, p_reference text default null,
                                                p_proof_path text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not exists (select 1 from public.wallets where professional_id = auth.uid()) then
    raise exception 'HMY_WALLET_NOT_FOUND';
  end if;
  if not exists (select 1 from public.topup_methods where id = p_method and is_active) then
    raise exception 'HMY_INVALID_METHOD';
  end if;
  if p_proof_path is not null and p_proof_path not like auth.uid()::text || '/%' then
    raise exception 'HMY_INVALID_PATH';
  end if;
  if (select count(*) from public.topup_requests where professional_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'HMY_TOO_MANY_PENDING';
  end if;
  insert into public.topup_requests (professional_id, method_id, amount, reference, proof_path)
  values (auth.uid(), p_method, round(p_amount, 2), p_reference, p_proof_path)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Lecturas con distancia aproximada para el profesional
-- ---------------------------------------------------------------------------
drop function public.my_bookings(text);
create function public.my_bookings(p_as text default 'customer')
returns table (
  id uuid, code text, status public.booking_status, mode public.booking_mode,
  category_id int, category text, city text, zone text,
  description text, scheduled_start timestamptz, created_at timestamptz,
  other_user_id uuid, other_name text, other_photo_path text,
  quote_amount numeric, final_amount numeric, has_review boolean, is_offer boolean, distance_km numeric
)
language sql stable security definer set search_path = public as $$
  select b.id, b.code, b.status, b.mode, b.category_id, sc.name, c.name, z.name,
         b.description, b.scheduled_start, b.created_at,
         case when p_as = 'customer' then b.professional_id else b.customer_id end,
         case when p_as = 'customer' then pp.display_name
              else coalesce(nullif(split_part(cp.full_name, ' ', 1), ''), 'Cliente') end,
         case when p_as = 'customer' then pp.photo_path end,
         b.quote_amount, b.final_amount,
         exists (select 1 from public.reviews r where r.booking_id = b.id),
         b.professional_id is null,
         case when p_as = 'professional' then public.booking_distance_for_me(b.id) end
  from public.bookings b
  join public.service_categories sc on sc.id = b.category_id
  join public.cities c on c.id = b.city_id
  left join public.service_zones z on z.id = b.zone_id
  left join public.professional_profiles pp on pp.user_id = b.professional_id
  left join public.profiles cp on cp.id = b.customer_id
  where (p_as = 'customer' and b.customer_id = auth.uid())
     or (p_as = 'professional' and (b.professional_id = auth.uid() or public.has_pending_offer(b.id)))
  order by b.created_at desc
  limit 100
$$;

create or replace function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings;
  v jsonb;
begin
  select * into b from public.bookings where id = p_booking;
  if not found or not (b.customer_id = auth.uid() or b.professional_id = auth.uid()
                       or public.has_pending_offer(b.id) or public.is_admin()) then
    raise exception 'HMY_NOT_FOUND';
  end if;

  select jsonb_build_object(
    'id', b.id, 'code', b.code, 'status', b.status, 'mode', b.mode,
    'category_id', b.category_id,
    'category', (select name from public.service_categories where id = b.category_id),
    'city', (select name from public.cities where id = b.city_id),
    'zone', (select name from public.service_zones where id = b.zone_id),
    'description', b.description,
    'scheduled_start', b.scheduled_start, 'scheduled_end', b.scheduled_end,
    'response_deadline', b.response_deadline,
    'quote_amount', b.quote_amount, 'quote_note', b.quote_note, 'final_amount', b.final_amount,
    'payment_method', b.payment_method,
    'customer_paid_ack', b.customer_paid_ack_at is not null,
    'professional_paid_ack', b.professional_paid_ack_at is not null,
    'created_at', b.created_at, 'cancel_reason', b.cancel_reason,
    'viewer_role', case when b.customer_id = auth.uid() then 'customer'
                        when b.professional_id = auth.uid() or public.has_pending_offer(b.id) then 'professional'
                        else 'admin' end,
    'is_offer', b.professional_id is null,
    'distance_km', public.booking_distance_for_me(b.id),
    'customer_id', b.customer_id,
    'customer_first_name', (select coalesce(nullif(split_part(full_name, ' ', 1), ''), 'Cliente')
                            from public.profiles where id = b.customer_id),
    'professional', case when b.professional_id is null then null else (
      select jsonb_build_object('id', pp.user_id, 'display_name', pp.display_name, 'photo_path', pp.photo_path,
                                'rating_avg', pp.rating_avg, 'rating_count', pp.rating_count,
                                'is_verified', pp.status = 'approved')
      from public.professional_profiles pp where pp.user_id = b.professional_id) end,
    'address', case when public.can_see_booking_address(b.id) then (
      select jsonb_build_object('line', a.address_line, 'reference', a.reference,
                                'latitude', a.latitude, 'longitude', a.longitude)
      from public.booking_addresses a where a.booking_id = b.id) end,
    'conversation_id', (select id from public.conversations where booking_id = b.id),
    'has_review', exists (select 1 from public.reviews where booking_id = b.id),
    'offers_sent', case when b.customer_id = auth.uid() then
      (select count(*) from public.booking_offers where booking_id = b.id) end,
    'events', coalesce((select jsonb_agg(jsonb_build_object('status', e.to_status, 'note', e.note, 'at', e.created_at)
                                         order by e.id)
                        from public.booking_events e where e.booking_id = b.id), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(jsonb_build_object('path', p.storage_path, 'kind', p.kind) order by p.id)
                        from public.booking_photos p where p.booking_id = b.id), '[]'::jsonb)
  ) into v;
  return v;
end $$;

revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;
revoke execute on function public.set_booking_approx_point() from public, anon, authenticated;
revoke execute on function public.limit_booking_photos() from public, anon, authenticated;
revoke execute on function public.set_service_location(numeric, numeric, int) from public, anon;
revoke execute on function public.count_ya_available(int, smallint, int, numeric, numeric) from public, anon;
revoke execute on function public.booking_distance_for_me(uuid) from public, anon;
revoke execute on function public.my_bookings(text) from public, anon;
