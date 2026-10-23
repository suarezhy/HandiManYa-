-- HandiMan ¡Ya! — 0015 Ubicación en vivo del profesional y viaje compartido.
--
-- Ubicación en vivo:
-- - Solo mientras el pedido está "en camino" y la llegada no está verificada.
--   La app del profesional la manda con la pantalla abierta (sin segundo plano)
--   y muestra que la está compartiendo; puede pausarla.
-- - Se guarda solo el último punto (sin historial del recorrido). Se borra al
--   verificar la llegada, al cancelar o al salir de "en camino".
-- - Solo la ven el cliente de ese pedido, el equipo y un contacto de confianza
--   con el enlace que el cliente compartió. Nadie más.
--
-- Viaje compartido con un contacto de confianza (por WhatsApp, desde el
-- teléfono del cliente; no usa un servicio pago):
-- - El cliente crea un enlace con un código al azar. Se guarda solo su huella
--   (sha256). El enlace muestra el nombre del profesional, si está verificado,
--   el estado, la llegada verificada y la ubicación en vivo mientras viaja.
--   Nunca la dirección del cliente, su teléfono ni el del profesional.
-- - Vence a las 12 horas o cuando el trabajo termina o se cancela, y el
--   cliente puede anularlo cuando quiera. Máximo 3 enlaces activos por pedido.

do $$ begin
  if to_regclass('public.booking_arrivals') is null then
    raise exception 'HMY: falta la migración 0014; no se aplicó nada.';
  end if;
  if to_regclass('public.trip_locations') is not null then
    raise exception 'HMY: la migración 0015 ya estaba aplicada; no se aplicó nada.';
  end if;
end $$;

create table public.trip_locations (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  latitude numeric(9,6) not null,
  longitude numeric(9,6) not null,
  accuracy_m int check (accuracy_m is null or accuracy_m between 0 and 5000),
  updated_at timestamptz not null default now(),
  constraint trip_location_valid check (public.hmy_valid_point(latitude, longitude))
);

create table public.trip_shares (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  token_hash text not null unique,
  contact_name text check (contact_name is null or char_length(contact_name) <= 80),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_viewed_at timestamptz
);
create index trip_shares_booking_idx on public.trip_shares (booking_id);

alter table public.trip_locations enable row level security;
alter table public.trip_shares enable row level security;
revoke all on public.trip_locations, public.trip_shares from anon, authenticated;

create function public.hmy_trip_live(p_status public.booking_status, p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_status = 'on_the_way'
     and not exists (select 1 from public.booking_arrivals where booking_id = p_booking and verified_at is not null)
$$;

-- El profesional manda su posición. Si llega más de una vez cada 5 segundos, se ignora.
create function public.share_trip_location(p_booking uuid, p_latitude numeric, p_longitude numeric,
                                           p_accuracy_m int default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.professional_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if not public.hmy_trip_live(b.status, b.id) then raise exception 'HMY_TRIP_NOT_ACTIVE'; end if;
  if p_latitude is null or p_longitude is null or not public.hmy_valid_point(p_latitude, p_longitude) then
    raise exception 'HMY_INVALID_LOCATION';
  end if;
  insert into public.trip_locations as t (booking_id, professional_id, latitude, longitude, accuracy_m)
  values (b.id, b.professional_id, round(p_latitude, 6), round(p_longitude, 6), least(greatest(p_accuracy_m, 0), 5000))
  on conflict (booking_id) do update set
    latitude = excluded.latitude, longitude = excluded.longitude, accuracy_m = excluded.accuracy_m, updated_at = now()
  where t.updated_at < now() - interval '5 seconds';
  return found;
end $$;

-- El profesional pausa o deja de compartir: se borra el punto.
create function public.stop_trip_location(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.bookings where id = p_booking and professional_id = auth.uid()) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  delete from public.trip_locations where booking_id = p_booking;
end $$;

create function public.hmy_trip_json(b public.bookings) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.hmy_trip_live(b.status, b.id) and t.booking_id is not null then
    jsonb_build_object(
      'latitude', t.latitude, 'longitude', t.longitude, 'accuracy_m', t.accuracy_m, 'updated_at', t.updated_at,
      'stale', t.updated_at < now() - interval '2 minutes')
  end
  from (select 1) x left join public.trip_locations t on t.booking_id = b.id
$$;

-- Para el cliente (y el equipo): posición, distancia a su dirección y tiempo estimado.
create function public.trip_location(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings;
  v_trip jsonb;
  v_km numeric;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.customer_id is distinct from auth.uid() and not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  v_trip := public.hmy_trip_json(b);
  if v_trip is null then return jsonb_build_object('live', public.hmy_trip_live(b.status, b.id)); end if;
  select public.hmy_distance_km((v_trip ->> 'latitude')::numeric, (v_trip ->> 'longitude')::numeric, a.latitude, a.longitude)
    into v_km from public.booking_addresses a where a.booking_id = b.id;
  return v_trip || jsonb_build_object(
    'live', true,
    'distance_km', v_km,
    -- Estimación simple en ciudad (~20 km/h), redondeada; es orientativa.
    'eta_minutes', case when v_km is not null then greatest(1, ceil(v_km / 20 * 60))::int end);
end $$;

-- El cliente crea un enlace para su contacto de confianza. Devuelve el código una sola vez.
create function public.create_trip_share(p_booking uuid, p_contact_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_token text;
  v_expires timestamptz := now() + interval '12 hours';
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.customer_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if b.status not in ('confirmed', 'on_the_way', 'in_progress', 'work_finished') then
    raise exception 'HMY_INVALID_TRANSITION: % -> share', b.status;
  end if;
  if (select count(*) from public.trip_shares
       where booking_id = b.id and revoked_at is null and expires_at > now()) >= 3 then
    raise exception 'HMY_TOO_MANY_SHARES';
  end if;
  v_token := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_');
  insert into public.trip_shares (booking_id, customer_id, token_hash, contact_name, expires_at)
  values (b.id, b.customer_id, encode(extensions.digest(v_token, 'sha256'), 'hex'),
          nullif(left(btrim(coalesce(p_contact_name, '')), 80), ''), v_expires);
  return jsonb_build_object('token', v_token, 'expires_at', v_expires);
end $$;

create function public.my_trip_shares(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'contact_name', s.contact_name, 'created_at', s.created_at, 'expires_at', s.expires_at,
           'last_viewed_at', s.last_viewed_at) order by s.created_at desc, s.id desc), '[]'::jsonb)
  from public.trip_shares s
  where s.booking_id = p_booking and s.customer_id = auth.uid() and s.revoked_at is null and s.expires_at > now()
$$;

create function public.revoke_trip_share(p_share bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.trip_shares set revoked_at = now()
   where id = p_share and customer_id = auth.uid() and revoked_at is null;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
end $$;

-- Lo que ve el contacto de confianza con el enlace (sin cuenta).
create function public.trip_share_view(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.trip_shares;
  b public.bookings;
  p public.professional_profiles;
  a public.booking_arrivals;
begin
  if coalesce(p_token, '') !~ '^[A-Za-z0-9_=-]{20,64}$' then raise exception 'HMY_SHARE_NOT_FOUND'; end if;
  select * into s from public.trip_shares where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found or s.revoked_at is not null or s.expires_at <= now() then raise exception 'HMY_SHARE_NOT_FOUND'; end if;
  select * into b from public.bookings where id = s.booking_id;
  if b.status in ('completed', 'cancelled') then raise exception 'HMY_SHARE_NOT_FOUND'; end if;
  update public.trip_shares set last_viewed_at = now() where id = s.id;
  select * into p from public.professional_profiles where user_id = b.professional_id;
  select * into a from public.booking_arrivals where booking_id = b.id;
  return jsonb_build_object(
    'code', b.code,
    'status', b.status,
    'status_label', public.booking_status_label(b.status),
    'customer_first_name', (select split_part(full_name, ' ', 1) from public.profiles where id = b.customer_id),
    'professional_name', p.display_name,
    'professional_verified', p.status = 'approved',
    'category', (select name from public.service_categories where id = b.category_id),
    'arrival_verified_at', a.verified_at,
    'trip', public.hmy_trip_json(b),
    'expires_at', s.expires_at);
end $$;

-- Al verificar la llegada o salir de "en camino", se borra la ubicación.
-- Al terminar o cancelar el pedido, los enlaces dejan de servir.
create function public.hmy_trip_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'bookings' then
    if new.status is distinct from 'on_the_way' then
      delete from public.trip_locations where booking_id = new.id;
    end if;
    if new.status in ('completed', 'cancelled') then
      update public.trip_shares set revoked_at = now() where booking_id = new.id and revoked_at is null;
    end if;
  elsif new.verified_at is not null then
    delete from public.trip_locations where booking_id = new.booking_id;
  end if;
  return null;
end $$;

create trigger bookings_trip_cleanup after update of status on public.bookings
  for each row execute function public.hmy_trip_cleanup();
create trigger booking_arrivals_trip_cleanup after insert or update of verified_at on public.booking_arrivals
  for each row execute function public.hmy_trip_cleanup();

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_trip_live(public.booking_status, uuid) from public, anon, authenticated;
revoke execute on function public.hmy_trip_json(public.bookings) from public, anon, authenticated;
revoke execute on function public.hmy_trip_cleanup() from public, anon, authenticated;
revoke execute on function public.share_trip_location(uuid, numeric, numeric, int) from public, anon;
revoke execute on function public.stop_trip_location(uuid) from public, anon;
revoke execute on function public.trip_location(uuid) from public, anon;
revoke execute on function public.create_trip_share(uuid, text) from public, anon;
revoke execute on function public.my_trip_shares(uuid) from public, anon;
revoke execute on function public.revoke_trip_share(bigint) from public, anon;
revoke execute on function public.trip_share_view(text) from public;
grant execute on function public.share_trip_location(uuid, numeric, numeric, int) to authenticated;
grant execute on function public.stop_trip_location(uuid) to authenticated;
grant execute on function public.trip_location(uuid) to authenticated;
grant execute on function public.create_trip_share(uuid, text) to authenticated;
grant execute on function public.my_trip_shares(uuid) to authenticated;
grant execute on function public.revoke_trip_share(bigint) to authenticated;
grant execute on function public.trip_share_view(text) to anon, authenticated;
