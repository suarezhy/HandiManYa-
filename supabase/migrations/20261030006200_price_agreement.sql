-- HandiMan ¡Ya! — 0062 precio acordado entre los dos antes de aceptar.
--
-- Antes, un profesional aceptaba un pedido sin precio y al terminar escribía
-- "¿Cuánto cobraste?". Ahora:
-- 1. El cliente puede poner su precio al pedir (opcional). Cualquiera de los
--    dos propone o contraoferta, sin límite de rondas, hasta que uno acepta la
--    última propuesta del otro. Todo queda en price_offers (el historial).
-- 2. Ningún trabajo se confirma sin precio acordado (HMY_PRICE_REQUIRED). Al
--    acordarlo queda fijo: nadie lo cambia solo (HMY_PRICE_LOCKED).
-- 3. ¡Ya! y programadas sin profesional: cada profesional avisado ve el precio
--    del cliente y lo acepta, propone el suyo o dice "No puedo". El cliente ve
--    las propuestas y acepta una: ese profesional se queda con el trabajo (con
--    las mismas revisiones de antes: aprobado, sin otro trabajo en curso, con
--    el horario libre). Las demás propuestas vencen.
-- 4. Servicios con visita de inspección: se acuerda el precio de la visita
--    (kind 'inspection'); la reparación se cotiza aparte ('repair') y solo se
--    suma si el cliente la acepta.
-- 5. Un cobro extra durante el trabajo ('extra') se suma solo si los dos lo
--    aceptan antes de hacerlo.
-- 6. "Terminé el trabajo" no pide monto: el monto final es el acordado más lo
--    aceptado aparte. La comisión se calcula sobre ese monto.
-- 7. Comisión: 10 % del precio acordado por defecto (el administrador la
--    cambia en Comisiones). Se reserva al aceptar, también la de cada monto
--    aparte aprobado; sin saldo, el profesional no puede proponer ni aceptar
--    ese monto y ve cuánto le falta. Nunca se calcula con una propuesta sin
--    aceptar ni deja saldo negativo.
-- claim_ya_request y accept_booking (aceptar sin precio) ya no confirman nada.
--
-- Agrega una tabla, columnas, funciones y triggers. Pasa las cotizaciones que
-- esperaban respuesta a la tabla nueva; no borra datos.

-- ---------------------------------------------------------------- Tablas
alter table public.bookings
  add column agreed_amount numeric(10,2) check (agreed_amount is null or agreed_amount > 0),
  add column agreed_kind text check (agreed_kind in ('service', 'inspection')),
  add column agreed_at timestamptz,
  add column agreed_offer_id bigint,
  add column extras_amount numeric(10,2) not null default 0 check (extras_amount >= 0);

create table public.price_offers (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  -- La conversación de precio: el profesional con quien se negocia. Null = el
  -- precio del cliente para todos los avisados (¡Ya! o programada sin profesional).
  professional_id uuid references public.professional_profiles(user_id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  author_role text not null check (author_role in ('customer', 'professional')),
  kind text not null check (kind in ('service', 'inspection', 'repair', 'extra')),
  amount numeric(10,2) not null check (amount > 0 and amount <= 100000),
  note text check (note is null or char_length(note) <= 300),
  status text not null default 'open'
    check (status in ('open', 'accepted', 'rejected', 'superseded', 'withdrawn', 'expired')),
  responded_by uuid references public.profiles(id),
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  check (author_role = 'customer' or professional_id = author_id)
);
create index price_offers_booking_idx on public.price_offers (booking_id, id);
create index price_offers_open_idx on public.price_offers (booking_id, professional_id) where status = 'open';

alter table public.bookings add constraint bookings_agreed_offer_fk
  foreign key (agreed_offer_id) references public.price_offers(id);

-- Solo se lee y escribe con las funciones de abajo.
alter table public.price_offers enable row level security;
revoke all on public.price_offers from public, anon, authenticated;

-- Aceptar también lo hace el cliente (el precio que propuso el profesional).
insert into public.booking_transitions values
  ('requested', 'confirmed', 'customer'),
  ('awaiting_response', 'confirmed', 'customer'),
  ('quote_sent', 'confirmed', 'professional')
on conflict do nothing;

-- ---------------------------------------------------------------- Reglas fijas
create function public.hmy_price_lock() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.agreed_amount is not null
     and (new.agreed_amount is distinct from old.agreed_amount or new.agreed_kind is distinct from old.agreed_kind
          or new.agreed_offer_id is distinct from old.agreed_offer_id or new.agreed_at is distinct from old.agreed_at) then
    raise exception 'HMY_PRICE_LOCKED';
  end if;
  if new.extras_amount < old.extras_amount then raise exception 'HMY_PRICE_LOCKED'; end if;
  if new.status = 'confirmed' and old.status in ('requested', 'awaiting_response', 'quote_sent')
     and new.agreed_amount is null then
    raise exception 'HMY_PRICE_REQUIRED';
  end if;
  if new.agreed_amount is not null then
    -- Lo que usan las comisiones y las listas: siempre el precio acordado.
    new.quote_amount := new.agreed_amount;
    new.final_amount := case when new.finished_at is not null then new.agreed_amount + new.extras_amount end;
  end if;
  return new;
end $$;

create trigger bookings_price_lock before update on public.bookings
  for each row execute function public.hmy_price_lock();

-- Las propuestas abiertas vencen cuando ya no se pueden aceptar.
create function public.hmy_price_offers_close() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('cancelled', 'work_finished', 'completed', 'disputed') then
      update public.price_offers set status = 'expired', responded_at = now()
      where booking_id = new.id and status = 'open';
    elsif new.status = 'confirmed' then
      update public.price_offers set status = 'expired', responded_at = now()
      where booking_id = new.id and status = 'open' and kind in ('service', 'inspection');
    end if;
  end if;
  return new;
end $$;

create trigger bookings_price_offers_close after update of status on public.bookings
  for each row execute function public.hmy_price_offers_close();

-- Un profesional que ya no recibe el pedido (dijo "No puedo", lo tomó otro o
-- venció) deja de negociar.
create function public.hmy_price_offers_close_for_pro() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'pending' and old.status = 'pending' then
    update public.price_offers set status = 'expired', responded_at = now()
    where booking_id = new.booking_id and professional_id = new.professional_id and status = 'open'
      and kind in ('service', 'inspection');
  end if;
  return new;
end $$;

create trigger booking_offers_close_price after update of status on public.booking_offers
  for each row execute function public.hmy_price_offers_close_for_pro();

-- ---------------------------------------------------------------- Comisión
-- Comisión general por defecto: 10 % del precio acordado, sin reserva mínima.
insert into public.commission_rules (name, rate_percent, reserve_amount, min_balance, capture_at, is_active)
select 'Comisión general (10 %)', 10, 0, 0, 'completed', true
where not exists (select 1 from public.commission_rules where is_active);

-- Cuánto es la comisión de un monto y si el saldo del profesional la cubre.
-- p_extra: un monto aparte durante el trabajo (solo suma el porcentaje).
create function public.hmy_commission_need(p_pro uuid, p_category int, p_city smallint, p_amount numeric,
                                           p_extra boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r public.commission_rules := public.commission_rule_for(p_category, p_city);
  v_commission numeric(10,2) := 0;
  v_needed numeric(10,2) := 0;
  v_available numeric(10,2) := coalesce((select available from public.wallets where professional_id = p_pro), 0);
  v_debt numeric(10,2) := (select coalesce(sum(commission_shortfall), 0) from public.bookings
                           where professional_id = p_pro and commission_shortfall > 0);
begin
  if r.id is not null then
    if p_extra then
      v_commission := case when r.rate_percent is not null then round(p_amount * r.rate_percent / 100, 2) else 0 end;
      v_needed := v_commission;
    else
      v_commission := coalesce(case when r.rate_percent is not null then round(p_amount * r.rate_percent / 100, 2) end,
                               r.fixed_fee, 0);
      v_needed := greatest(r.min_balance, v_commission, r.reserve_amount);
    end if;
  end if;
  return jsonb_build_object(
    'has_rule', r.id is not null, 'rate_percent', r.rate_percent, 'fixed_fee', r.fixed_fee,
    'amount', round(p_amount, 2), 'commission', v_commission, 'net', round(p_amount, 2) - v_commission,
    'needed', v_needed, 'available', v_available, 'pending_debt', v_debt,
    'can_cover', v_debt = 0 and v_available >= v_needed,
    'missing', greatest(v_needed - v_available, 0));
end $$;

-- Para la app: la comisión de un monto en este pedido, antes de proponerlo o aceptarlo.
create function public.commission_for_amount(p_booking uuid, p_amount numeric) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if not found or public.hmy_price_role(b, auth.uid()) is distinct from 'professional' then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  return public.hmy_commission_need(auth.uid(), b.category_id, b.city_id, p_amount, b.agreed_amount is not null);
end $$;

-- El profesional solo propone o acepta un monto cuya comisión puede cubrir.
create function public._hmy_require_cover(p_pro uuid, b public.bookings, p_amount numeric, p_extra boolean) returns void
language plpgsql security definer set search_path = public as $$
declare n jsonb := public.hmy_commission_need(p_pro, b.category_id, b.city_id, p_amount, p_extra);
begin
  if (n ->> 'pending_debt')::numeric > 0 then raise exception 'HMY_COMMISSION_DEBT'; end if;
  if not (n ->> 'can_cover')::boolean then raise exception 'HMY_INSUFFICIENT_BALANCE'; end if;
end $$;

-- ---------------------------------------------------------------- Proponer
-- Quién mira el pedido y desde qué lado: 'customer', 'professional' o null.
create function public.hmy_price_role(b public.bookings, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when b.customer_id = p_user then 'customer'
    when b.professional_id = p_user then 'professional'
    when b.professional_id is null and exists (select 1 from public.booking_offers o
           where o.booking_id = b.id and o.professional_id = p_user and o.status = 'pending') then 'professional'
  end
$$;

create function public.propose_price(
  p_booking uuid,
  p_amount numeric,
  p_kind text default 'service',
  p_note text default null,
  p_professional uuid default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  b public.bookings;
  v_role text;
  v_thread uuid;
  v_amount numeric(10,2) := round(p_amount, 2);
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_pre boolean;
  v_same bigint;
  v_id bigint;
  v_who text;
  v_pro uuid;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  v_role := public.hmy_price_role(b, v_me);
  if v_role is null then raise exception 'HMY_FORBIDDEN'; end if;
  if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;

  v_pre := b.agreed_amount is null and b.status in ('requested', 'awaiting_response', 'quote_sent');
  if v_pre then
    if coalesce(p_kind, 'service') not in ('service', 'inspection') then raise exception 'HMY_INVALID_PRICE_KIND'; end if;
    if public.hmy_response_deadline(b) < now() then raise exception 'HMY_REQUEST_EXPIRED'; end if;
  elsif b.agreed_amount is not null and b.status in ('confirmed', 'on_the_way', 'in_progress') then
    if p_kind not in ('extra', 'repair') then raise exception 'HMY_INVALID_PRICE_KIND'; end if;
    if p_kind = 'repair' and (b.agreed_kind <> 'inspection' or exists (
         select 1 from public.price_offers where booking_id = b.id and kind = 'repair' and status = 'accepted')) then
      raise exception 'HMY_INVALID_PRICE_KIND';
    end if;
  else
    raise exception 'HMY_NOT_NEGOTIABLE';
  end if;

  -- Con quién se negocia.
  if v_role = 'professional' then
    v_thread := v_me;
  elsif b.professional_id is not null then
    v_thread := b.professional_id;
  else
    v_thread := p_professional; -- null: el precio para todos los avisados
    if v_thread is not null and not exists (
         select 1 from public.booking_offers o
         where o.booking_id = b.id and o.professional_id = v_thread and o.status = 'pending') then
      raise exception 'HMY_PRO_UNAVAILABLE';
    end if;
  end if;

  if v_role = 'professional' then perform public._hmy_require_cover(v_me, b, v_amount, not v_pre); end if;

  if (select count(*) from public.price_offers where booking_id = b.id and author_id = v_me) >= 40 then
    raise exception 'HMY_TOO_MANY_OFFERS';
  end if;

  -- Doble toque: la misma propuesta abierta no se repite.
  select id into v_same from public.price_offers
  where booking_id = b.id and professional_id is not distinct from v_thread and author_id = v_me
    and status = 'open' and kind = coalesce(p_kind, 'service') and amount = v_amount
    and note is not distinct from v_note;
  if v_same is not null then return v_same; end if;

  -- Una propuesta nueva reemplaza la que estaba abierta en esa conversación.
  update public.price_offers set status = 'superseded', responded_at = now()
  where booking_id = b.id and professional_id is not distinct from v_thread and status = 'open'
    and (kind in ('service', 'inspection')) = v_pre;

  insert into public.price_offers (booking_id, professional_id, author_id, author_role, kind, amount, note)
  values (b.id, v_thread, v_me, v_role, coalesce(p_kind, 'service'), v_amount, v_note)
  returning id into v_id;

  -- Un pedido directo con la primera propuesta del profesional queda "Cotización enviada".
  if v_pre and v_role = 'professional' and b.status = 'requested' then
    perform public._booking_move(b.id, 'quote_sent', 'professional', 'Propuesta de precio: Bs ' || v_amount);
  end if;

  v_who := case p_kind when 'inspection' then 'Visita de inspección' when 'repair' then 'Reparación'
                       when 'extra' then 'Cobro extra' else 'Precio' end;
  if v_role = 'professional' then
    perform public.notify(b.customer_id, 'price_offer',
      case when v_pre then 'Te propusieron un precio' else 'Te pidieron aprobar un monto' end,
      v_who || ': Bs ' || v_amount || ' · ' || coalesce((select display_name from public.professional_profiles
                                                       where user_id = v_me), 'Profesional'),
      jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
  elsif v_thread is not null then
    perform public.notify(v_thread, 'price_offer', 'El cliente propone un precio', v_who || ': Bs ' || v_amount,
                          jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
  elsif exists (select 1 from public.price_offers where booking_id = b.id and id < v_id and author_id = v_me) then
    -- El cliente cambió su precio: avisa a los que todavía pueden aceptar.
    for v_pro in select o.professional_id from public.booking_offers o
                 where o.booking_id = b.id and o.status = 'pending' loop
      perform public.notify(v_pro, 'price_offer', 'El cliente cambió su precio', 'Bs ' || v_amount,
                            jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
    end loop;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- Aceptar
-- Asigna un pedido abierto (¡Ya! o programada) al profesional del precio
-- acordado, con las revisiones de claim_ya_request (0055, 0057, 0060).
create function public._hmy_assign_pro(p_booking uuid, p_pro uuid, p_actor text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_err text;
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.status <> 'awaiting_response' or b.professional_id is not null then raise exception 'HMY_ALREADY_TAKEN'; end if;
  -- Un mismo profesional toma un trabajo a la vez.
  perform 1 from public.professional_profiles where user_id = p_pro for update;
  v_err := case
    when not exists (select 1 from public.booking_offers
                     where booking_id = b.id and professional_id = p_pro and status = 'pending') then 'HMY_FORBIDDEN'
    when public.is_suspended(p_pro) then 'HMY_ACCOUNT_SUSPENDED'
    when not exists (select 1 from public.professional_profiles where user_id = p_pro and status = 'approved')
      then 'HMY_PROFESSIONAL_NOT_APPROVED'
    when not public.hmy_pro_cleared(p_pro, b.category_id) then 'HMY_PRO_NOT_CLEARED'
    when b.mode = 'now' and public.hmy_pro_busy_now(p_pro) then 'HMY_PRO_BUSY'
    when b.mode = 'scheduled' and exists (
      select 1 from public.bookings x
      where x.professional_id = p_pro and x.mode = 'scheduled' and x.id <> b.id
        and x.status in ('confirmed', 'on_the_way', 'in_progress')
        and tstzrange(x.scheduled_start, x.scheduled_end) && tstzrange(b.scheduled_start, b.scheduled_end)) then 'HMY_SLOT_TAKEN'
  end;
  if v_err is not null then
    -- Al cliente no se le dice por qué ese profesional no puede.
    raise exception '%', case when p_actor = 'customer' then 'HMY_PRO_UNAVAILABLE' else v_err end;
  end if;

  update public.bookings set professional_id = p_pro where id = b.id;
  update public.booking_offers
  set status = case when professional_id = p_pro then 'accepted' else 'lost' end, responded_at = now()
  where booking_id = b.id and status = 'pending';
  begin
    return public._booking_move(b.id, 'confirmed', p_actor, 'Precio acordado: Bs ' || b.agreed_amount);
  exception when others then
    if p_actor = 'customer' and sqlerrm in ('HMY_INSUFFICIENT_BALANCE', 'HMY_WALLET_NOT_FOUND') then
      raise exception 'HMY_PRO_UNAVAILABLE';
    end if;
    raise;
  end;
end $$;

-- La comisión de un monto aparte se reserva al aprobarlo, con su propia clave
-- (un doble toque no la reserva dos veces). Sin saldo, no se aprueba.
create function public._hmy_reserve_extra(b public.bookings, o public.price_offers, p_actor text) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  v_add numeric(10,2);
begin
  if b.commission_rule_id is null then return; end if; -- el trabajo no tiene comisión
  select * into r from public.commission_rules where id = b.commission_rule_id;
  if r.rate_percent is null then return; end if;
  v_add := round(o.amount * r.rate_percent / 100, 2);
  if v_add <= 0 then return; end if;
  begin
    perform public.wallet_post(b.professional_id, 'commission_reserve', -v_add, v_add,
                               'reserve:' || b.id || ':' || o.id, b.id, null,
                               'Reserva de comisión ' || b.code || ' (monto aparte)');
  exception when others then
    if sqlerrm = 'HMY_INSUFFICIENT_BALANCE' and p_actor = 'customer' then raise exception 'HMY_PRO_NEEDS_BALANCE'; end if;
    raise;
  end;
  update public.bookings set commission_reserved = commission_reserved + v_add where id = b.id;
end $$;

create function public.accept_price_offer(p_offer bigint) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  o public.price_offers;
  b public.bookings;
  v_role text;
  v_pro uuid;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into o from public.price_offers where id = p_offer;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  select * into b from public.bookings where id = o.booking_id for update;
  select * into o from public.price_offers where id = p_offer for update;

  if b.status = 'cancelled' then raise exception 'HMY_REQUEST_CANCELLED'; end if;
  v_role := public.hmy_price_role(b, v_me);
  if v_role is null then
    -- Avisado antes, pero el pedido ya es de otro.
    if b.professional_id is not null
       and exists (select 1 from public.booking_offers where booking_id = b.id and professional_id = v_me) then
      raise exception 'HMY_ALREADY_TAKEN';
    end if;
    if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
    raise exception 'HMY_FORBIDDEN';
  end if;
  if o.kind in ('service', 'inspection')
     and (b.agreed_amount is not null or b.status not in ('requested', 'awaiting_response', 'quote_sent')) then
    -- Un pedido abierto ya tomado (también por uno mismo) dice eso, como en 0058.
    raise exception '%', case when exists (select 1 from public.booking_offers where booking_id = b.id)
                              then 'HMY_ALREADY_TAKEN' else 'HMY_INVALID_TRANSITION' end;
  end if;
  if v_role = o.author_role
     or (v_role = 'professional' and o.professional_id is distinct from v_me and o.professional_id is not null) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  -- Un profesional que ya no puede trabajar lo frena la base al confirmar (0047).
  if v_role = 'customer' and public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if o.status <> 'open' then raise exception 'HMY_OFFER_CHANGED'; end if;

  if o.kind in ('repair', 'extra') then
    if b.status not in ('confirmed', 'on_the_way', 'in_progress') then raise exception 'HMY_NOT_NEGOTIABLE'; end if;
    perform public._hmy_reserve_extra(b, o, v_role);
    update public.price_offers set status = 'accepted', responded_by = v_me, responded_at = now() where id = o.id;
    update public.bookings set extras_amount = extras_amount + o.amount where id = b.id;
    perform public.notify(case when v_role = 'customer' then b.professional_id else b.customer_id end,
      'price_offer', 'Monto aprobado',
      case o.kind when 'repair' then 'Reparación' else 'Cobro extra' end || ': Bs ' || o.amount,
      jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
    return b.status;
  end if;

  -- El precio del cliente para todos: si el cliente ya le hizo otra propuesta
  -- a este profesional, vale esa.
  if o.professional_id is null and exists (
       select 1 from public.price_offers where booking_id = b.id and professional_id = v_me
         and author_role = 'customer' and status = 'open') then
    raise exception 'HMY_OFFER_CHANGED';
  end if;
  if public.hmy_response_deadline(b) < now() then raise exception 'HMY_REQUEST_EXPIRED'; end if;

  update public.price_offers set status = 'accepted', responded_by = v_me, responded_at = now() where id = o.id;
  update public.bookings
  set agreed_amount = o.amount, agreed_kind = o.kind, agreed_at = now(), agreed_offer_id = o.id, quote_note = o.note
  where id = b.id;

  v_pro := coalesce(b.professional_id, case when v_role = 'professional' then v_me else o.professional_id end);
  if b.professional_id is null then
    return (public._hmy_assign_pro(b.id, v_pro, v_role)).status;
  end if;
  return (public._booking_move(b.id, 'confirmed', v_role, 'Precio acordado: Bs ' || o.amount)).status;
end $$;

-- Rechazar la propuesta del otro, sin contraofertar. El pedido sigue abierto.
-- El precio del cliente para todos no se rechaza: el profesional propone el
-- suyo o dice "No puedo".
create function public.reject_price_offer(p_offer bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  o public.price_offers;
  b public.bookings;
  v_role text;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into o from public.price_offers where id = p_offer;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  select * into b from public.bookings where id = o.booking_id for update;
  select * into o from public.price_offers where id = p_offer for update;
  v_role := public.hmy_price_role(b, v_me);
  if v_role is null or v_role = o.author_role or o.professional_id is null
     or (v_role = 'professional' and o.professional_id <> v_me) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if o.status <> 'open' then raise exception 'HMY_OFFER_CHANGED'; end if;
  update public.price_offers set status = 'rejected', responded_by = v_me, responded_at = now() where id = o.id;
  perform public.notify(o.author_id, 'price_offer', 'No aceptaron tu propuesta',
    'Bs ' || o.amount || '. Puedes proponer otro monto.', jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
end $$;

-- ---------------------------------------------------------------- Lo de antes
-- Aceptar sin precio ya no confirma: las versiones viejas de la app reciben
-- este aviso y piden actualizar.
create or replace function public.claim_ya_request(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'HMY_PRICE_REQUIRED';
end $$;

create or replace function public.accept_booking(p_booking uuid) returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'HMY_PRICE_REQUIRED';
end $$;

-- La cotización de un pedido directo es una propuesta del profesional.
create or replace function public.send_quote(p_booking uuid, p_amount numeric, p_note text default null)
returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  perform 1 from public.bookings where id = p_booking and professional_id = auth.uid() and status = 'requested' for update;
  if not found then raise exception 'HMY_INVALID_TRANSITION'; end if;
  -- Un profesional que ya no puede trabajar no cotiza (0047).
  if not public.hmy_professional_active(auth.uid()) then raise exception 'HMY_PROFESSIONAL_NOT_APPROVED'; end if;
  select * into b from public.bookings where id = p_booking;
  if public.hmy_response_deadline(b) < now() then raise exception 'HMY_REQUEST_EXPIRED'; end if;
  perform public.propose_price(p_booking, p_amount, 'service', p_note);
  return (select status from public.bookings where id = p_booking);
end $$;

-- Aceptar la cotización = aceptar la última propuesta abierta del profesional.
-- Rechazarla cancela la solicitud, como antes.
create or replace function public.respond_quote(p_booking uuid, p_accept boolean) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_offer bigint;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if not p_accept then
    return (public._booking_move(p_booking, 'cancelled', 'customer', 'Cotización rechazada')).status;
  end if;
  if b.customer_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  select id into v_offer from public.price_offers
  where booking_id = b.id and author_role = 'professional' and status = 'open' and kind in ('service', 'inspection')
  order by id desc limit 1;
  if v_offer is not null then return public.accept_price_offer(v_offer); end if;
  -- Una cotización anterior a 0062 sin propuesta guardada.
  if b.status = 'quote_sent' and b.quote_amount is not null and b.agreed_amount is null then
    update public.bookings set agreed_amount = b.quote_amount, agreed_kind = 'service', agreed_at = now() where id = b.id;
    return (public._booking_move(p_booking, 'confirmed', 'customer', 'Cotización aceptada')).status;
  end if;
  raise exception 'HMY_PRICE_REQUIRED';
end $$;

-- "No puedo" en un pedido abierto: igual que antes; sus propuestas vencen (trigger).
-- "Terminé el trabajo": el monto final ya no se escribe (trigger hmy_price_lock).
-- Solo para pedidos anteriores a 0062 sin precio acordado se guarda el que llega.
create or replace function public.update_job_progress(p_booking uuid, p_to public.booking_status,
                                                      p_final_amount numeric default null)
returns public.booking_status
language plpgsql security definer set search_path = public as $$
begin
  if p_to not in ('on_the_way', 'in_progress', 'work_finished') then raise exception 'HMY_INVALID_TRANSITION'; end if;
  if p_to = 'work_finished' and p_final_amount is not null then
    if p_final_amount < 0 then raise exception 'HMY_INVALID_AMOUNT'; end if;
    update public.bookings set final_amount = round(p_final_amount, 2)
    where id = p_booking and professional_id = auth.uid() and status = 'in_progress' and agreed_amount is null;
  end if;
  return (public._booking_move(p_booking, p_to, 'professional')).status;
end $$;

-- ---------------------------------------------------------------- Pedir con precio
alter function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric,
  int[], text, text) rename to _create_ya_request_unpriced;
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
  p_destination text default null,
  p_budget numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_budget is not null and (p_budget <= 0 or p_budget > 100000) then raise exception 'HMY_INVALID_AMOUNT'; end if;
  v_id := public._create_ya_request_unpriced(p_category, p_city, p_description, p_address, p_address_reference,
    p_zone_id, p_payment_method, p_latitude, p_longitude, p_problem_ids, p_other_text, p_destination);
  if p_budget is not null then perform public.propose_price(v_id, p_budget); end if;
  return v_id;
end $$;

alter function public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text) rename to _create_scheduled_request_unpriced;
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
  p_destination text default null,
  p_budget numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_budget is not null and (p_budget <= 0 or p_budget > 100000) then raise exception 'HMY_INVALID_AMOUNT'; end if;
  v_id := public._create_scheduled_request_unpriced(p_category, p_city, p_description, p_address, p_scheduled_start,
    p_duration_minutes, p_address_reference, p_zone_id, p_payment_method, p_latitude, p_longitude, p_problem_ids,
    p_other_text, p_destination);
  if p_budget is not null then perform public.propose_price(v_id, p_budget); end if;
  return v_id;
end $$;

alter function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int,
  public.payment_method, numeric, numeric, int[], text, text) rename to _create_booking_unpriced;
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
  p_longitude numeric default null,
  p_problem_ids int[] default null,
  p_other_text text default null,
  p_destination text default null,
  p_budget numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_budget is not null and (p_budget <= 0 or p_budget > 100000) then raise exception 'HMY_INVALID_AMOUNT'; end if;
  v_id := public._create_booking_unpriced(p_professional, p_category, p_mode, p_description, p_address,
    p_address_reference, p_zone_id, p_scheduled_start, p_duration_minutes, p_payment_method, p_latitude, p_longitude,
    p_problem_ids, p_other_text, p_destination);
  if p_budget is not null then perform public.propose_price(v_id, p_budget); end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- Lectura
-- El detalle del pedido trae el precio: lo acordado, lo aceptado aparte y el
-- historial. El cliente ve todas las propuestas; un profesional, solo el precio
-- del cliente para todos y su propia conversación.
alter function public.booking_detail(uuid) rename to _booking_detail_unpriced;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_unpriced(p_booking); -- valida quién puede verlo
  b public.bookings;
  v_customer boolean;
begin
  select * into b from public.bookings where id = p_booking;
  v_customer := b.customer_id = auth.uid() or public.is_admin();
  return v || jsonb_build_object('price', jsonb_build_object(
    'agreed_amount', b.agreed_amount,
    'agreed_kind', b.agreed_kind,
    'agreed_at', b.agreed_at,
    'extras_amount', b.extras_amount,
    'total', case when b.agreed_amount is not null then b.agreed_amount + b.extras_amount end,
    'offers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'professional_id', o.professional_id, 'author_role', o.author_role, 'kind', o.kind,
        'amount', o.amount, 'note', o.note, 'status', o.status, 'created_at', o.created_at,
        'professional', case when v_customer and o.professional_id is not null then (
          select jsonb_build_object('id', pp.user_id, 'display_name', pp.display_name, 'photo_path', pp.photo_path,
                                    'rating_avg', pp.rating_avg, 'rating_count', pp.rating_count,
                                    'is_verified', pp.status = 'approved' and not pp.test_fixture)
          from public.professional_profiles pp where pp.user_id = o.professional_id) end
      ) order by o.id)
      from public.price_offers o
      where o.booking_id = b.id
        and (v_customer or o.professional_id is null or o.professional_id = auth.uid())), '[]'::jsonb)
  ));
end $$;

-- ---------------------------------------------------------------- Datos
-- Las cotizaciones que esperaban respuesta pasan a ser propuestas abiertas.
insert into public.price_offers (booking_id, professional_id, author_id, author_role, kind, amount, note, created_at)
select b.id, b.professional_id, b.professional_id, 'professional', 'service', b.quote_amount,
       left(b.quote_note, 300), b.updated_at
from public.bookings b
where b.status = 'quote_sent' and b.quote_amount > 0 and b.professional_id is not null;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_price_lock() from public, anon, authenticated;
revoke execute on function public.hmy_price_offers_close() from public, anon, authenticated;
revoke execute on function public.hmy_price_offers_close_for_pro() from public, anon, authenticated;
revoke execute on function public.hmy_price_role(public.bookings, uuid) from public, anon, authenticated;
revoke execute on function public._hmy_assign_pro(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.hmy_commission_need(uuid, int, smallint, numeric, boolean) from public, anon, authenticated;
revoke execute on function public._hmy_require_cover(uuid, public.bookings, numeric, boolean) from public, anon, authenticated;
revoke execute on function public._hmy_reserve_extra(public.bookings, public.price_offers, text) from public, anon, authenticated;
revoke execute on function public.commission_for_amount(uuid, numeric) from public, anon;
grant execute on function public.commission_for_amount(uuid, numeric) to authenticated;
revoke execute on function public._create_ya_request_unpriced(int, smallint, text, text, text, int,
  public.payment_method, numeric, numeric, int[], text, text) from public, anon, authenticated;
revoke execute on function public._create_scheduled_request_unpriced(int, smallint, text, text, timestamptz, int, text,
  int, public.payment_method, numeric, numeric, int[], text, text) from public, anon, authenticated;
revoke execute on function public._create_booking_unpriced(uuid, int, public.booking_mode, text, text, text, int,
  timestamptz, int, public.payment_method, numeric, numeric, int[], text, text) from public, anon, authenticated;
revoke execute on function public._booking_detail_unpriced(uuid) from public, anon, authenticated;

revoke execute on function public.propose_price(uuid, numeric, text, text, uuid) from public, anon;
grant execute on function public.propose_price(uuid, numeric, text, text, uuid) to authenticated;
revoke execute on function public.accept_price_offer(bigint) from public, anon;
grant execute on function public.accept_price_offer(bigint) to authenticated;
revoke execute on function public.reject_price_offer(bigint) from public, anon;
grant execute on function public.reject_price_offer(bigint) to authenticated;
revoke execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text, numeric) from public, anon;
grant execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text, numeric) to authenticated;
revoke execute on function public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text, numeric) from public, anon;
grant execute on function public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text, numeric) to authenticated;
revoke execute on function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz,
  int, public.payment_method, numeric, numeric, int[], text, text, numeric) from public, anon;
grant execute on function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz,
  int, public.payment_method, numeric, numeric, int[], text, text, numeric) to authenticated;
revoke execute on function public.booking_detail(uuid) from public, anon;
grant execute on function public.booking_detail(uuid) to authenticated;
