-- HandiMan ¡Ya! — 0055 Solicitud programada sin profesional ("Pendiente de profesional").
--
-- Antes, "Programar" exigía elegir a un profesional; si en la ciudad no había
-- ninguno, el cliente no podía ni elegir el día. Ahora el cliente elige día y
-- hora y publica la solicitud: queda "Pendiente de profesional" y llega a los
-- profesionales aprobados de la zona que ofrecen ese servicio (aunque no estén
-- disponibles ahora mismo). El primero que acepta se queda con el trabajo,
-- igual que en ¡Ya!. Nadie la ve como confirmada hasta que alguien acepta.
--
-- Si un profesional se aprueba, se pone disponible o agrega el servicio
-- después, también le llegan las solicitudes pendientes que le corresponden.
-- Si nadie acepta antes de 30 minutos del horario, se cancela sola (la misma
-- limpieza de plazos de siempre) y el cliente puede volver a pedir.
--
-- Solo agrega funciones y triggers: no cambia ni borra pedidos existentes.

-- Profesionales que pueden recibir una solicitud programada: como en ¡Ya!,
-- pero no hace falta que estén disponibles en este momento.
create function public.hmy_scheduled_eligible_professionals(
  p_category int, p_city smallint, p_zone int, p_customer uuid,
  p_latitude numeric default null, p_longitude numeric default null
) returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  join public.profiles pr on pr.id = pp.user_id
  left join public.professional_locations pl on pl.professional_id = pp.user_id
  where pp.status = 'approved'
    and pr.suspended_at is null
    and pp.user_id <> p_customer
    and not public.hmy_blocked_between(pp.user_id, p_customer)
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and public.hmy_pro_cleared(pp.user_id, p_category)
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
           pp.rating_avg desc
  limit 50
$$;

-- Avisa a los profesionales que todavía no recibieron esta solicitud.
create function public._hmy_offer_scheduled(p_booking uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  a public.booking_addresses;
  v_pro uuid;
  n int := 0;
begin
  select * into b from public.bookings where id = p_booking;
  if b.status <> 'awaiting_response' or b.mode <> 'scheduled' or b.professional_id is not null then return 0; end if;
  select * into a from public.booking_addresses where booking_id = p_booking;
  for v_pro in
    select e from public.hmy_scheduled_eligible_professionals(b.category_id, b.city_id, b.zone_id, b.customer_id,
                                                              round(a.latitude, 2), round(a.longitude, 2)) e
    where not exists (select 1 from public.booking_offers o where o.booking_id = b.id and o.professional_id = e)
  loop
    insert into public.booking_offers (booking_id, professional_id) values (b.id, v_pro);
    perform public.notify(v_pro, 'booking_new', 'Solicitud programada cerca de ti',
                          left(coalesce(array_to_string(b.problem_labels, ' · '), b.description), 140),
                          jsonb_build_object('booking_id', b.id));
    n := n + 1;
  end loop;
  return n;
end $$;

create function public.create_scheduled_request(
  p_category int,
  p_city smallint,
  p_description text,
  p_address text,
  p_scheduled_start timestamptz,
  p_duration_minutes int default 120,
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
  v_labels text[];
  v_dest text;
  v_id uuid;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not exists (select 1 from public.service_categories where id = p_category and is_active) then
    raise exception 'HMY_INVALID_CATEGORY';
  end if;
  v_labels := public.hmy_problem_labels(p_category, p_problem_ids, p_other_text);
  v_dest := public.hmy_check_booking_extras(p_category, p_problem_ids, p_destination);
  if not public.hmy_valid_point(p_latitude, p_longitude) then raise exception 'HMY_INVALID_LOCATION'; end if;
  if p_zone_id is not null and not exists (select 1 from public.service_zones where id = p_zone_id and city_id = p_city) then
    raise exception 'HMY_INVALID_ZONE';
  end if;
  if p_scheduled_start is null or p_scheduled_start < now() + interval '30 minutes'
     or p_scheduled_start > now() + interval '60 days'
     or coalesce(p_duration_minutes, 0) not between 30 and 720 then
    raise exception 'HMY_INVALID_SCHEDULE';
  end if;
  if char_length(coalesce(trim(p_address), '')) < 5 then raise exception 'HMY_ADDRESS_REQUIRED'; end if;
  if (select count(*) from public.bookings
      where customer_id = v_me and status in ('requested', 'awaiting_response', 'quote_sent')) >= 5 then
    raise exception 'HMY_TOO_MANY_OPEN_REQUESTS';
  end if;
  -- La misma solicitud dos veces (por ejemplo, un doble toque): mismo servicio
  -- y un horario que se cruza con otra que sigue pendiente.
  if exists (select 1 from public.bookings
             where customer_id = v_me and category_id = p_category and mode = 'scheduled'
               and status in ('requested', 'awaiting_response', 'quote_sent')
               and tstzrange(scheduled_start, scheduled_end)
                   && tstzrange(p_scheduled_start, p_scheduled_start + make_interval(mins => p_duration_minutes))) then
    raise exception 'HMY_DUPLICATE_REQUEST';
  end if;

  insert into public.bookings (customer_id, professional_id, category_id, city_id, zone_id, mode, scheduled_start,
                               scheduled_end, description, status, response_deadline, payment_method,
                               problem_ids, problem_labels)
  values (v_me, null, p_category, p_city, p_zone_id, 'scheduled', p_scheduled_start,
          p_scheduled_start + make_interval(mins => p_duration_minutes),
          left(coalesce(nullif(trim(p_description), ''), array_to_string(v_labels, '. '), ''), 2000),
          'awaiting_response', p_scheduled_start - interval '30 minutes', p_payment_method,
          case when v_labels is not null then p_problem_ids end, v_labels)
  returning id into v_id;

  insert into public.booking_addresses (booking_id, address_line, reference, latitude, longitude, destination)
  values (v_id, left(trim(p_address), 300), nullif(trim(coalesce(p_address_reference, '')), ''),
          p_latitude, p_longitude, v_dest);

  insert into public.booking_events (booking_id, from_status, to_status, actor_id)
  values (v_id, null, 'awaiting_response', v_me);

  perform public._hmy_offer_scheduled(v_id);
  return v_id;
end $$;

-- Aceptar una solicitud programada: como ¡Ya!, y además el profesional no
-- puede tener otro trabajo confirmado en ese horario.
alter function public.claim_ya_request(uuid) rename to _claim_ya_request_base;
create function public.claim_ya_request(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if found and b.mode = 'scheduled' then
    if not public.hmy_pro_cleared(auth.uid(), b.category_id) then raise exception 'HMY_PRO_NOT_CLEARED'; end if;
    if exists (select 1 from public.bookings x
               where x.professional_id = auth.uid() and x.mode = 'scheduled' and x.id <> b.id
                 and x.status in ('confirmed', 'on_the_way', 'in_progress')
                 and tstzrange(x.scheduled_start, x.scheduled_end) && tstzrange(b.scheduled_start, b.scheduled_end)) then
      raise exception 'HMY_SLOT_TAKEN';
    end if;
  end if;
  return public._claim_ya_request_base(p_booking);
end $$;

-- Un profesional que recién puede recibir trabajo (aprobado, disponible o con
-- un servicio nuevo) recibe las solicitudes programadas pendientes de su zona.
create function public._hmy_offer_pending_to(p_pro uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select b.id from public.bookings b
    where b.status = 'awaiting_response' and b.mode = 'scheduled' and b.professional_id is null
      and public.hmy_response_deadline(b) > now()
      and not exists (select 1 from public.booking_offers o where o.booking_id = b.id and o.professional_id = p_pro)
      and (b.category_id in (select s.category_id from public.professional_services s where s.professional_id = p_pro)
           or b.category_id = (select primary_category_id from public.professional_profiles where user_id = p_pro))
    order by b.scheduled_start
    limit 50
  loop
    perform public._hmy_offer_scheduled(r.id);
  end loop;
end $$;

create function public.hmy_offer_pending_on_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved'
     and (old.status is distinct from 'approved' or (new.is_available and not coalesce(old.is_available, false))) then
    perform public._hmy_offer_pending_to(new.user_id);
  end if;
  return new;
end $$;
create trigger professional_profiles_offer_pending after update of status, is_available on public.professional_profiles
  for each row execute function public.hmy_offer_pending_on_profile();

create function public.hmy_offer_pending_on_service() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.professional_profiles where user_id = new.professional_id and status = 'approved') then
    perform public._hmy_offer_pending_to(new.professional_id);
  end if;
  return new;
end $$;
create trigger professional_services_offer_pending after insert on public.professional_services
  for each row execute function public.hmy_offer_pending_on_service();

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_scheduled_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;
revoke execute on function public._hmy_offer_scheduled(uuid) from public, anon, authenticated;
revoke execute on function public._hmy_offer_pending_to(uuid) from public, anon, authenticated;
revoke execute on function public._claim_ya_request_base(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_offer_pending_on_profile() from public, anon, authenticated;
revoke execute on function public.hmy_offer_pending_on_service() from public, anon, authenticated;

revoke execute on function public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text) from public, anon;
grant execute on function public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text) to authenticated;
revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;
