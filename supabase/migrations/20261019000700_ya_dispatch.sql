-- HandiMan ¡Ya! — 0007 "¡Ya!": pedido inmediato tipo Uber y lecturas para la app.
--
-- El cliente pide un servicio para ahora sin elegir profesional. La solicitud
-- llega a los profesionales aprobados y disponibles de esa ciudad (y zona,
-- si la indicaron) que ofrecen ese servicio. El primero que acepta se queda
-- con el trabajo; el bloqueo de fila impide una segunda aceptación.

create table public.booking_offers (
  booking_id uuid not null references public.bookings(id) on delete cascade,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'declined', 'accepted', 'lost', 'expired')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (booking_id, professional_id)
);
create index booking_offers_pro_idx on public.booking_offers (professional_id, status);

insert into public.booking_transitions values
  ('awaiting_response', 'confirmed', 'professional'),
  ('awaiting_response', 'cancelled', 'customer'),
  ('awaiting_response', 'cancelled', 'system');

-- Profesionales que pueden recibir un pedido ¡Ya!
create function public.ya_eligible_professionals(p_category int, p_city smallint, p_zone int, p_customer uuid)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  where pp.status = 'approved'
    and pp.is_available
    and pp.user_id <> p_customer
    and pp.city_id = p_city
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and (p_zone is null
         or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
         or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone))
  order by pp.rating_avg desc, pp.available_since asc nulls last
  limit 25
$$;

create function public.count_ya_available(p_category int, p_city smallint, p_zone int default null)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.ya_eligible_professionals(p_category, p_city, p_zone,
                                                              coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
$$;

create function public.create_ya_request(
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
  v_n int := 0;
  v_pro uuid;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_zone_id is not null and not exists (select 1 from public.service_zones where id = p_zone_id and city_id = p_city) then
    raise exception 'HMY_INVALID_ZONE';
  end if;
  if (select count(*) from public.bookings
      where customer_id = auth.uid() and status in ('requested', 'awaiting_response', 'quote_sent')) >= 5 then
    raise exception 'HMY_TOO_MANY_OPEN_REQUESTS';
  end if;
  if not exists (select 1 from public.ya_eligible_professionals(p_category, p_city, p_zone_id, auth.uid())) then
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

  for v_pro in select * from public.ya_eligible_professionals(p_category, p_city, p_zone_id, auth.uid()) loop
    insert into public.booking_offers (booking_id, professional_id) values (v_id, v_pro);
    perform public.notify(v_pro, 'ya_offer', '¡Pedido ¡Ya! cerca de ti!', left(trim(p_description), 140),
                          jsonb_build_object('booking_id', v_id));
    v_n := v_n + 1;
  end loop;
  return v_id;
end $$;

-- El primero que acepta se queda con el trabajo.
create function public.claim_ya_request(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status <> 'awaiting_response' or b.professional_id is not null then
    raise exception 'HMY_ALREADY_TAKEN';
  end if;
  if not exists (select 1 from public.booking_offers
                 where booking_id = b.id and professional_id = auth.uid() and status = 'pending') then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if not exists (select 1 from public.professional_profiles where user_id = auth.uid() and status = 'approved') then
    raise exception 'HMY_PROFESSIONAL_NOT_APPROVED';
  end if;

  update public.bookings set professional_id = auth.uid() where id = b.id;
  update public.booking_offers
  set status = case when professional_id = auth.uid() then 'accepted' else 'lost' end, responded_at = now()
  where booking_id = b.id and status = 'pending';

  return (public._booking_move(b.id, 'confirmed', 'professional', 'Aceptado por el profesional')).status;
end $$;

create function public.decline_ya_offer(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.booking_offers set status = 'declined', responded_at = now()
  where booking_id = p_booking and professional_id = auth.uid() and status = 'pending';
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
end $$;

-- Las ofertas pendientes caducan cuando la solicitud deja de esperar.
create function public.close_offers_on_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'awaiting_response' and old.status = 'awaiting_response' then
    update public.booking_offers set status = 'expired', responded_at = now()
    where booking_id = new.id and status = 'pending';
  end if;
  return new;
end $$;

create trigger bookings_close_offers after update of status on public.bookings
  for each row execute function public.close_offers_on_status();

-- Limpieza periódica: también vence pedidos ¡Ya! sin respuesta.
create or replace function public.run_booking_housekeeping() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from public.bookings where status = 'requested' and response_deadline < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Sin respuesta del profesional a tiempo');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'awaiting_response' and response_deadline < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Ningún profesional aceptó a tiempo. Puedes intentar de nuevo o programar para después.');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'work_finished' and finished_at < now() - interval '72 hours' loop
    perform public._booking_move(r.id, 'completed', 'system', 'Confirmado automáticamente después de 72 horas');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Visibilidad: un profesional con oferta pendiente ve la solicitud (sin la
-- dirección exacta, que sigue protegida por booking_addresses).
-- ---------------------------------------------------------------------------
create function public.has_pending_offer(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.booking_offers
                 where booking_id = p_booking and professional_id = auth.uid() and status = 'pending')
$$;

drop policy bookings_participants on public.bookings;
create policy bookings_participants on public.bookings for select
  using (customer_id = auth.uid() or professional_id = auth.uid() or public.is_admin()
         or public.has_pending_offer(id));

alter table public.booking_offers enable row level security;
create policy offers_own on public.booking_offers for select
  using (professional_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.bookings b where b.id = booking_id and b.customer_id = auth.uid()));
revoke insert, update, delete on public.booking_offers from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lecturas para la app (unen datos que el usuario sí puede ver).
-- ---------------------------------------------------------------------------
create function public.my_bookings(p_as text default 'customer')
returns table (
  id uuid, code text, status public.booking_status, mode public.booking_mode,
  category_id int, category text, city text, zone text,
  description text, scheduled_start timestamptz, created_at timestamptz,
  other_user_id uuid, other_name text, other_photo_path text,
  quote_amount numeric, final_amount numeric, has_review boolean, is_offer boolean
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
         b.professional_id is null
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

create function public.booking_detail(p_booking uuid) returns jsonb
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

-- Perfil del usuario con roles y estado profesional, en una sola llamada.
create function public.my_account() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'email', u.email, 'full_name', p.full_name, 'phone', p.phone, 'city_id', p.city_id,
    'active_role', p.active_role,
    'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = p.id), '[]'::jsonb),
    'professional_status', coalesce((select status::text from public.professional_profiles where user_id = p.id), 'not_started'),
    'onboarding_completed', p.onboarding_completed_at is not null,
    'deletion_requested', p.deletion_requested_at is not null
  )
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid()
$$;

-- Resumen del panel profesional.
create function public.pro_dashboard() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'is_available', pp.is_available,
    'status', pp.status,
    'rating_avg', pp.rating_avg, 'rating_count', pp.rating_count, 'completed_jobs', pp.completed_jobs,
    'wallet_available', coalesce(w.available, 0), 'wallet_reserved', coalesce(w.reserved, 0),
    'incoming', (select count(*) from public.bookings b
                 where (b.professional_id = pp.user_id and b.status = 'requested') or public.has_pending_offer(b.id)),
    'active', (select count(*) from public.bookings b
               where b.professional_id = pp.user_id and b.status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished')),
    'upcoming', (select count(*) from public.bookings b
                 where b.professional_id = pp.user_id and b.mode = 'scheduled' and b.status = 'confirmed'
                   and b.scheduled_start > now()),
    'earnings_month', coalesce((select sum(final_amount) from public.bookings b
                                where b.professional_id = pp.user_id and b.status = 'completed'
                                  and b.completed_at >= date_trunc('month', now())), 0)
  )
  from public.professional_profiles pp
  left join public.wallets w on w.professional_id = pp.user_id
  where pp.user_id = auth.uid()
$$;

revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid) from public, anon, authenticated;
revoke execute on function public.close_offers_on_status() from public, anon, authenticated;
revoke execute on function public.run_booking_housekeeping() from public, anon, authenticated;
revoke execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric) from public, anon;
revoke execute on function public.claim_ya_request(uuid) from public, anon;
revoke execute on function public.decline_ya_offer(uuid) from public, anon;
revoke execute on function public.my_bookings(text) from public, anon;
revoke execute on function public.booking_detail(uuid) from public, anon;
revoke execute on function public.my_account() from public, anon;
revoke execute on function public.pro_dashboard() from public, anon;
