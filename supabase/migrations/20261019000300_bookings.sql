-- HandiMan ¡Ya! — 0003 solicitudes y reservas ("Lo necesito ahora" y
-- "Programar para después"), estados controlados, direcciones privadas,
-- notificaciones y comisiones.

create type public.booking_mode as enum ('now', 'scheduled');

create type public.booking_status as enum (
  'draft', 'requested', 'awaiting_response', 'quote_sent', 'awaiting_confirmation',
  'confirmed', 'on_the_way', 'in_progress', 'work_finished', 'completed',
  'cancelled', 'disputed'
);

create type public.payment_method as enum ('cash', 'qr');

-- ---------------------------------------------------------------------------
-- Notificaciones (las usan casi todas las funciones de abajo)
-- ---------------------------------------------------------------------------
create table public.notifications (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

create function public.notify(p_user uuid, p_kind text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, kind, title, body, data)
  values (p_user, p_kind, p_title, p_body, coalesce(p_data, '{}'::jsonb))
$$;

create function public.mark_notifications_read(p_ids bigint[] default null) returns void
language sql security definer set search_path = public as $$
  update public.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids))
$$;

-- ---------------------------------------------------------------------------
-- Reservas
-- ---------------------------------------------------------------------------
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  customer_id uuid not null references public.profiles(id),
  professional_id uuid references public.professional_profiles(user_id),
  category_id int not null references public.service_categories(id),
  city_id smallint not null references public.cities(id),
  zone_id int references public.service_zones(id),
  mode public.booking_mode not null,
  scheduled_start timestamptz,
  scheduled_end timestamptz,
  description text not null check (char_length(description) between 5 and 1500),
  status public.booking_status not null default 'requested',
  response_deadline timestamptz,
  quote_amount numeric(10,2) check (quote_amount is null or quote_amount >= 0),
  quote_note text check (quote_note is null or char_length(quote_note) <= 500),
  final_amount numeric(10,2) check (final_amount is null or final_amount >= 0),
  payment_method public.payment_method,
  customer_paid_ack_at timestamptz,
  professional_paid_ack_at timestamptz,
  accepted_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles(id),
  cancel_reason text,
  commission_rule_id int references public.commission_rules(id),
  commission_reserved numeric(10,2) not null default 0,
  commission_captured numeric(10,2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (mode = 'now' or (scheduled_start is not null and scheduled_end > scheduled_start)),
  check (professional_id is null or professional_id <> customer_id),
  -- Un profesional no puede tener dos trabajos programados que se crucen.
  constraint bookings_no_overlap exclude using gist (
    professional_id with =,
    tstzrange(scheduled_start, scheduled_end) with &&
  ) where (mode = 'scheduled' and status in ('confirmed', 'on_the_way', 'in_progress'))
);
create index bookings_customer_idx on public.bookings (customer_id, created_at desc);
create index bookings_professional_idx on public.bookings (professional_id, status);

create trigger bookings_touch before update on public.bookings
  for each row execute function public.touch_updated_at();

-- La dirección exacta vive aparte para poder protegerla.
create table public.booking_addresses (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  address_line text not null check (char_length(address_line) between 3 and 300),
  reference text check (reference is null or char_length(reference) <= 300),
  latitude numeric(9,6),
  longitude numeric(9,6)
);

create table public.booking_photos (
  id bigserial primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  kind text not null check (kind in ('problem', 'evidence')),
  storage_path text not null,
  uploaded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.booking_events (
  id bigserial primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  from_status public.booking_status,
  to_status public.booking_status not null,
  actor_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index booking_events_booking_idx on public.booking_events (booking_id, created_at);

create table public.disputes (
  id bigserial primary key,
  booking_id uuid not null unique references public.bookings(id),
  opened_by uuid not null references public.profiles(id),
  reason text not null check (char_length(reason) between 5 and 1500),
  status text not null default 'open' check (status in ('open', 'resolved')),
  resolution text,
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create function public.booking_status_label(s public.booking_status) returns text
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

-- ---------------------------------------------------------------------------
-- Comisiones ligadas a la reserva
-- ---------------------------------------------------------------------------
create function public._commission_reserve(b public.bookings) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  w public.wallets;
begin
  r := public.commission_rule_for(b.category_id, b.city_id);
  if r.id is null then
    return; -- Sin regla configurada: no se cobra nada.
  end if;
  select * into w from public.wallets where professional_id = b.professional_id;
  if not found then raise exception 'HMY_WALLET_NOT_FOUND'; end if;
  if w.available < greatest(r.min_balance, r.reserve_amount) then
    raise exception 'HMY_INSUFFICIENT_BALANCE';
  end if;
  if r.reserve_amount > 0 then
    perform public.wallet_post(b.professional_id, 'commission_reserve', -r.reserve_amount, r.reserve_amount,
                               'reserve:' || b.id, b.id, null, 'Reserva de comisión ' || b.code);
  end if;
  update public.bookings set commission_rule_id = r.id, commission_reserved = r.reserve_amount where id = b.id;
  if r.capture_at = 'accepted' then
    perform public._commission_capture(b.id);
  end if;
end $$;

create function public._commission_capture(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  r public.commission_rules;
  w public.wallets;
  v_amount numeric(10,2);
begin
  select * into b from public.bookings where id = p_booking;
  if b.commission_rule_id is null or b.commission_captured is not null then
    return;
  end if;
  select * into r from public.commission_rules where id = b.commission_rule_id;
  v_amount := coalesce(
    case when r.rate_percent is not null and b.final_amount is not null
         then round(b.final_amount * r.rate_percent / 100, 2) end,
    r.fixed_fee,
    b.commission_reserved,
    0);
  select * into w from public.wallets where professional_id = b.professional_id for update;
  -- Nunca deja el saldo en negativo: si falta, se cobra lo posible y queda anotado.
  v_amount := least(v_amount, b.commission_reserved + w.available);
  perform public.wallet_post(b.professional_id, 'commission_capture',
                             b.commission_reserved - v_amount, -b.commission_reserved,
                             'capture:' || b.id, b.id, null, 'Comisión ' || b.code);
  update public.bookings set commission_captured = v_amount, commission_reserved = 0 where id = b.id;
end $$;

create function public._commission_release(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.commission_reserved > 0 and b.commission_captured is null then
    perform public.wallet_post(b.professional_id, 'commission_release', b.commission_reserved,
                               -b.commission_reserved, 'release:' || b.id, b.id, null,
                               'Liberación de comisión ' || b.code);
    update public.bookings set commission_reserved = 0 where id = b.id;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Máquina de estados
-- ---------------------------------------------------------------------------
create table public.booking_transitions (
  from_status public.booking_status not null,
  to_status public.booking_status not null,
  actor text not null check (actor in ('customer', 'professional', 'admin', 'system')),
  primary key (from_status, to_status, actor)
);

insert into public.booking_transitions values
  ('requested', 'confirmed', 'professional'),
  ('requested', 'quote_sent', 'professional'),
  ('requested', 'cancelled', 'professional'),
  ('requested', 'cancelled', 'customer'),
  ('requested', 'cancelled', 'system'),
  ('quote_sent', 'confirmed', 'customer'),
  ('quote_sent', 'cancelled', 'customer'),
  ('quote_sent', 'cancelled', 'professional'),
  ('confirmed', 'on_the_way', 'professional'),
  ('confirmed', 'in_progress', 'professional'),
  ('confirmed', 'cancelled', 'professional'),
  ('confirmed', 'cancelled', 'customer'),
  ('on_the_way', 'in_progress', 'professional'),
  ('on_the_way', 'cancelled', 'professional'),
  ('on_the_way', 'disputed', 'customer'),
  ('in_progress', 'work_finished', 'professional'),
  ('in_progress', 'disputed', 'customer'),
  ('in_progress', 'disputed', 'professional'),
  ('work_finished', 'completed', 'customer'),
  ('work_finished', 'disputed', 'customer'),
  ('work_finished', 'disputed', 'professional'),
  ('work_finished', 'completed', 'system'),
  ('disputed', 'completed', 'admin'),
  ('disputed', 'cancelled', 'admin');

-- Aplica un cambio de estado con bloqueo de fila. Evita aceptaciones dobles
-- y estados contradictorios.
create function public._booking_move(p_booking uuid, p_to public.booking_status, p_actor text, p_note text default null)
returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_title text;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;

  if p_actor = 'customer' and b.customer_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_actor = 'professional' and b.professional_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_actor = 'admin' and not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;

  if not exists (select 1 from public.booking_transitions
                 where from_status = b.status and to_status = p_to and actor = p_actor) then
    raise exception 'HMY_INVALID_TRANSITION: % -> %', b.status, p_to;
  end if;

  update public.bookings set
    status = p_to,
    accepted_at = case when p_to = 'confirmed' then now() else accepted_at end,
    started_at = case when p_to = 'in_progress' then now() else started_at end,
    finished_at = case when p_to = 'work_finished' then now() else finished_at end,
    completed_at = case when p_to = 'completed' then now() else completed_at end,
    cancelled_at = case when p_to = 'cancelled' then now() else cancelled_at end,
    cancelled_by = case when p_to = 'cancelled' then auth.uid() else cancelled_by end,
    cancel_reason = case when p_to = 'cancelled' then p_note else cancel_reason end
  where id = b.id
  returning * into b;

  insert into public.booking_events (booking_id, from_status, to_status, actor_id, note)
  select b.id, e.from_status, p_to, auth.uid(), p_note
  from (select (select to_status from public.booking_events where booking_id = b.id
                order by id desc limit 1) as from_status) e;

  -- Efectos de comisión
  if p_to = 'confirmed' then
    perform public._commission_reserve(b);
  elsif p_to = 'completed' then
    perform public._commission_capture(b.id);
    update public.professional_profiles set completed_jobs = completed_jobs + 1 where user_id = b.professional_id;
  elsif p_to = 'cancelled' then
    perform public._commission_release(b.id);
  end if;

  v_title := 'Solicitud ' || b.code || ': ' || public.booking_status_label(p_to);
  if p_actor <> 'customer' then
    perform public.notify(b.customer_id, 'booking_status', v_title, coalesce(p_note, ''),
                          jsonb_build_object('booking_id', b.id, 'status', p_to));
  end if;
  if p_actor <> 'professional' and b.professional_id is not null then
    perform public.notify(b.professional_id, 'booking_status', v_title, coalesce(p_note, ''),
                          jsonb_build_object('booking_id', b.id, 'status', p_to));
  end if;

  select * into b from public.bookings where id = b.id;
  return b;
end $$;

-- ---------------------------------------------------------------------------
-- Funciones públicas (RPC)
-- ---------------------------------------------------------------------------
create function public.create_booking(
  p_professional uuid,
  p_category int,
  p_mode public.booking_mode,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_scheduled_start timestamptz default null,
  p_duration_minutes int default 120,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  pro public.professional_profiles;
  v_id uuid;
  v_city smallint;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_professional = auth.uid() then raise exception 'HMY_CANNOT_BOOK_SELF'; end if;

  select * into pro from public.professional_profiles where user_id = p_professional;
  if not found or pro.status <> 'approved' then raise exception 'HMY_PROFESSIONAL_NOT_AVAILABLE'; end if;
  if p_mode = 'now' and not pro.is_available then raise exception 'HMY_PROFESSIONAL_NOT_AVAILABLE'; end if;

  if p_mode = 'scheduled' then
    if p_scheduled_start is null or p_scheduled_start < now() + interval '30 minutes' then
      raise exception 'HMY_INVALID_SCHEDULE';
    end if;
    if p_duration_minutes not between 30 and 720 then raise exception 'HMY_INVALID_SCHEDULE'; end if;
    if exists (select 1 from public.bookings
               where professional_id = p_professional and mode = 'scheduled'
                 and status in ('confirmed', 'on_the_way', 'in_progress')
                 and tstzrange(scheduled_start, scheduled_end)
                     && tstzrange(p_scheduled_start, p_scheduled_start + make_interval(mins => p_duration_minutes))) then
      raise exception 'HMY_SLOT_TAKEN';
    end if;
  end if;

  if (select count(*) from public.bookings
      where customer_id = auth.uid() and status in ('requested', 'quote_sent')) >= 5 then
    raise exception 'HMY_TOO_MANY_OPEN_REQUESTS';
  end if;

  v_city := pro.city_id;
  if p_zone_id is not null then
    select city_id into v_city from public.service_zones where id = p_zone_id;
    if v_city is null then raise exception 'HMY_INVALID_ZONE'; end if;
  end if;

  insert into public.bookings (customer_id, professional_id, category_id, city_id, zone_id, mode,
                               scheduled_start, scheduled_end, description, status,
                               response_deadline, payment_method)
  values (auth.uid(), p_professional, p_category, v_city, p_zone_id, p_mode,
          case when p_mode = 'scheduled' then p_scheduled_start end,
          case when p_mode = 'scheduled' then p_scheduled_start + make_interval(mins => p_duration_minutes) end,
          trim(p_description), 'requested',
          now() + case when p_mode = 'now' then interval '15 minutes' else interval '12 hours' end,
          p_payment_method)
  returning id into v_id;

  insert into public.booking_addresses (booking_id, address_line, reference, latitude, longitude)
  values (v_id, trim(p_address), p_address_reference, p_latitude, p_longitude);

  insert into public.booking_events (booking_id, from_status, to_status, actor_id)
  values (v_id, null, 'requested', auth.uid());

  perform public.notify(p_professional, 'booking_new',
    case when p_mode = 'now' then '¡Nueva solicitud para ahora!' else 'Nueva solicitud programada' end,
    left(trim(p_description), 140), jsonb_build_object('booking_id', v_id));
  return v_id;
end $$;

create function public.accept_booking(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  return (public._booking_move(p_booking, 'confirmed', 'professional')).status;
end $$;

create function public.decline_booking(p_booking uuid, p_reason text default null) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  return (public._booking_move(p_booking, 'cancelled', 'professional',
                               coalesce(p_reason, 'El profesional no puede atender esta solicitud'))).status;
end $$;

create function public.send_quote(p_booking uuid, p_amount numeric, p_note text default null)
returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  if p_amount is null or p_amount <= 0 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  perform 1 from public.bookings where id = p_booking and professional_id = auth.uid() and status = 'requested' for update;
  if not found then raise exception 'HMY_INVALID_TRANSITION'; end if;
  update public.bookings set quote_amount = round(p_amount, 2), quote_note = p_note where id = p_booking;
  return (public._booking_move(p_booking, 'quote_sent', 'professional', 'Cotización: Bs ' || round(p_amount, 2))).status;
end $$;

create function public.respond_quote(p_booking uuid, p_accept boolean) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    return (public._booking_move(p_booking, 'confirmed', 'customer', 'Cotización aceptada')).status;
  end if;
  return (public._booking_move(p_booking, 'cancelled', 'customer', 'Cotización rechazada')).status;
end $$;

create function public.update_job_progress(p_booking uuid, p_to public.booking_status, p_final_amount numeric default null)
returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  if p_to not in ('on_the_way', 'in_progress', 'work_finished') then raise exception 'HMY_INVALID_TRANSITION'; end if;
  if p_to = 'work_finished' and p_final_amount is not null then
    if p_final_amount < 0 then raise exception 'HMY_INVALID_AMOUNT'; end if;
    update public.bookings set final_amount = round(p_final_amount, 2)
    where id = p_booking and professional_id = auth.uid() and status = 'in_progress';
  end if;
  return (public._booking_move(p_booking, p_to, 'professional')).status;
end $$;

create function public.confirm_completion(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  return (public._booking_move(p_booking, 'completed', 'customer', 'Trabajo confirmado por el cliente')).status;
end $$;

create function public.cancel_booking(p_booking uuid, p_reason text) returns public.booking_status
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

create function public.open_dispute(p_booking uuid, p_reason text) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  v_actor text;
  v_status public.booking_status;
begin
  select case when customer_id = auth.uid() then 'customer'
              when professional_id = auth.uid() then 'professional' end
  into v_actor from public.bookings where id = p_booking;
  if v_actor is null then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(coalesce(trim(p_reason), '')) < 5 then raise exception 'HMY_REASON_REQUIRED'; end if;
  v_status := (public._booking_move(p_booking, 'disputed', v_actor, p_reason)).status;
  insert into public.disputes (booking_id, opened_by, reason) values (p_booking, auth.uid(), trim(p_reason));
  return v_status;
end $$;

create function public.resolve_dispute(p_booking uuid, p_outcome public.booking_status, p_resolution text)
returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare v_status public.booking_status;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(trim(p_resolution), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  v_status := (public._booking_move(p_booking, p_outcome, 'admin', p_resolution)).status;
  update public.disputes set status = 'resolved', resolution = p_resolution,
         resolved_by = auth.uid(), resolved_at = now()
  where booking_id = p_booking;
  perform public.audit('dispute.resolve', 'bookings', p_booking::text,
                       jsonb_build_object('outcome', p_outcome, 'resolution', p_resolution));
  return v_status;
end $$;

-- Cada parte confirma por separado que el pago directo se hizo. La
-- plataforma no verifica pagos externos.
create function public.acknowledge_payment(p_booking uuid, p_method public.payment_method)
returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status not in ('work_finished', 'completed') then raise exception 'HMY_INVALID_TRANSITION'; end if;
  if b.customer_id = auth.uid() then
    update public.bookings set customer_paid_ack_at = coalesce(customer_paid_ack_at, now()),
           payment_method = coalesce(payment_method, p_method) where id = p_booking;
  elsif b.professional_id = auth.uid() then
    update public.bookings set professional_paid_ack_at = coalesce(professional_paid_ack_at, now()),
           payment_method = coalesce(payment_method, p_method) where id = p_booking;
  else
    raise exception 'HMY_FORBIDDEN';
  end if;
end $$;

-- Para un cron (pg_cron o Edge Function programada): cierra solicitudes sin
-- respuesta y confirma trabajos terminados que el cliente no revisó en 72 h.
create function public.run_booking_housekeeping() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from public.bookings where status = 'requested' and response_deadline < now() loop
    perform public._booking_move(r.id, 'cancelled', 'system', 'Sin respuesta del profesional a tiempo');
    n := n + 1;
  end loop;
  for r in select id from public.bookings where status = 'work_finished' and finished_at < now() - interval '72 hours' loop
    perform public._booking_move(r.id, 'completed', 'system', 'Confirmado automáticamente después de 72 horas');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Detalle de reserva para sus participantes (incluye la dirección solo
-- cuando corresponde).
create function public.can_see_booking_address(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bookings b
    where b.id = p_booking and (
      b.customer_id = auth.uid()
      or public.is_admin()
      or (b.professional_id = auth.uid()
          and b.status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished', 'disputed'))
    )
  )
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_addresses enable row level security;
alter table public.booking_photos enable row level security;
alter table public.booking_events enable row level security;
alter table public.booking_transitions enable row level security;
alter table public.disputes enable row level security;

create policy notifications_own on public.notifications for select using (user_id = auth.uid());
revoke insert, update, delete on public.notifications from anon, authenticated;

create policy bookings_participants on public.bookings for select
  using (customer_id = auth.uid() or professional_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.bookings from anon, authenticated;

create policy booking_address_read on public.booking_addresses for select
  using (public.can_see_booking_address(booking_id));
revoke insert, update, delete on public.booking_addresses from anon, authenticated;

create function public.is_booking_participant(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.id = p_booking
                 and (b.customer_id = auth.uid() or b.professional_id = auth.uid()))
$$;

create policy booking_photos_read on public.booking_photos for select
  using (public.is_booking_participant(booking_id) or public.is_admin());
create policy booking_photos_insert on public.booking_photos for insert
  with check (uploaded_by = auth.uid() and public.is_booking_participant(booking_id));
revoke update, delete on public.booking_photos from anon, authenticated;

create policy booking_events_read on public.booking_events for select
  using (public.is_booking_participant(booking_id) or public.is_admin());
revoke insert, update, delete on public.booking_events from anon, authenticated;

create policy transitions_read on public.booking_transitions for select using (true);
revoke insert, update, delete on public.booking_transitions from anon, authenticated;

create policy disputes_read on public.disputes for select
  using (public.is_booking_participant(booking_id) or public.is_admin());
revoke insert, update, delete on public.disputes from anon, authenticated;

-- Internas: nadie las llama desde la app.
revoke execute on function public._booking_move(uuid, public.booking_status, text, text) from public, anon, authenticated;
revoke execute on function public._commission_reserve(public.bookings) from public, anon, authenticated;
revoke execute on function public._commission_capture(uuid) from public, anon, authenticated;
revoke execute on function public._commission_release(uuid) from public, anon, authenticated;
revoke execute on function public.notify(uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.run_booking_housekeeping() from public, anon, authenticated;
-- Públicas para usuarios con sesión.
revoke execute on function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int, public.payment_method, numeric, numeric) from public, anon;
revoke execute on function public.accept_booking(uuid) from public, anon;
revoke execute on function public.decline_booking(uuid, text) from public, anon;
revoke execute on function public.send_quote(uuid, numeric, text) from public, anon;
revoke execute on function public.respond_quote(uuid, boolean) from public, anon;
revoke execute on function public.update_job_progress(uuid, public.booking_status, numeric) from public, anon;
revoke execute on function public.confirm_completion(uuid) from public, anon;
revoke execute on function public.cancel_booking(uuid, text) from public, anon;
revoke execute on function public.open_dispute(uuid, text) from public, anon;
revoke execute on function public.resolve_dispute(uuid, public.booking_status, text) from public, anon;
revoke execute on function public.acknowledge_payment(uuid, public.payment_method) from public, anon;
revoke execute on function public.mark_notifications_read(bigint[]) from public, anon;
