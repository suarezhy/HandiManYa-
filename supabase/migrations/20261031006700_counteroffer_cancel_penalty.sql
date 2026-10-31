-- 0067 · Build 42 (pedido del dueño, 31-10-2026)
--
-- 1. "No puedo" deja de confundir: un profesional que soltó un pedido ¡Ya! (o
--    programado abierto) ve por qué ya no puede aceptarlo (HMY_OFFER_DECLINED,
--    no HMY_FORBIDDEN), y mientras el pedido siga abierto puede volver a
--    tomarlo (reopen_ya_offer). Causa del 69E3FD38: "No puedo" a los 9 s y
--    después la app seguía mostrando "Aceptar".
-- 2. Contraoferta: con el precio ya acordado, cualquiera de los dos propone un
--    NUEVO TOTAL (kind 'total'). El precio acordado no cambia hasta que el otro
--    acepta; nunca se suma al anterior. Reemplaza al "monto aparte" ('extra'),
--    que ya no se puede proponer. La reparación tras una visita sigue igual.
-- 3. Penalización de Bs 3 solo al profesional que cancela después de aceptar.
--    El cliente nunca paga penalización. Una sola vez, sin saldo negativo: si
--    no alcanza, se cobra lo que hay y el resto queda anotado (no bloquea). El
--    propietario puede devolverla (emergencia, falla de la plataforma).
--    Cancelar ya no pide motivo.
-- 4. Historial de la billetera con el cambio del saldo total, el saldo total
--    después y el número de solicitud (my_wallet_history). Los movimientos de
--    reserva viejos no cambian el total y no se listan; ningún movimiento se
--    modifica.
-- 5. booking_detail: el aviso de este profesional, el porcentaje de comisión y
--    la penalización. my_bookings: "negotiating" para "Negociando precio".

-- ---------------------------------------------------------------- Tipos
alter type public.ledger_entry_type add value if not exists 'penalty';

alter table public.price_offers drop constraint price_offers_kind_check;
alter table public.price_offers add constraint price_offers_kind_check
  check (kind in ('service', 'inspection', 'repair', 'extra', 'total'));

-- El total puede bajar con una contraoferta aceptada: extras_amount es la
-- diferencia con el precio acordado al principio (puede ser negativa).
alter table public.bookings drop constraint bookings_extras_amount_check;
alter table public.bookings add constraint bookings_total_positive
  check (agreed_amount is null or agreed_amount + extras_amount > 0);
alter table public.bookings
  add column total_offer_id bigint references public.price_offers(id),
  add column cancel_penalty numeric(10,2),
  add column cancel_penalty_shortfall numeric(10,2) not null default 0,
  add column cancel_penalty_waived_at timestamptz;

-- ---------------------------------------------------------------- Precio fijo
-- Igual que en 0062, pero el total solo baja con una contraoferta aceptada de
-- ese mismo monto (total_offer_id).
create or replace function public.hmy_price_lock() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.agreed_amount is not null
     and (new.agreed_amount is distinct from old.agreed_amount or new.agreed_kind is distinct from old.agreed_kind
          or new.agreed_offer_id is distinct from old.agreed_offer_id or new.agreed_at is distinct from old.agreed_at) then
    raise exception 'HMY_PRICE_LOCKED';
  end if;
  if new.extras_amount < old.extras_amount and not (
       new.total_offer_id is distinct from old.total_offer_id
       and exists (select 1 from public.price_offers o
                   where o.id = new.total_offer_id and o.booking_id = new.id and o.kind = 'total'
                     and o.status = 'accepted' and o.amount = new.agreed_amount + new.extras_amount)) then
    raise exception 'HMY_PRICE_LOCKED';
  end if;
  if new.status = 'confirmed' and old.status in ('requested', 'awaiting_response', 'quote_sent')
     and new.agreed_amount is null then
    raise exception 'HMY_PRICE_REQUIRED';
  end if;
  if new.agreed_amount is not null then
    new.quote_amount := new.agreed_amount;
    new.final_amount := case when new.finished_at is not null then new.agreed_amount + new.extras_amount end;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- Aviso soltado
-- Por qué un profesional sin rol en el pedido no puede negociar.
create function public.hmy_not_my_request(b public.bookings, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when b.professional_id is not null and exists (select 1 from public.booking_offers
           where booking_id = b.id and professional_id = p_user) then 'HMY_ALREADY_TAKEN'
    when public.is_suspended(p_user) then 'HMY_ACCOUNT_SUSPENDED'
    when (select status from public.booking_offers where booking_id = b.id and professional_id = p_user) = 'declined'
      then 'HMY_OFFER_DECLINED'
    when (select status from public.booking_offers where booking_id = b.id and professional_id = p_user) = 'expired'
      then 'HMY_REQUEST_EXPIRED'
    else 'HMY_FORBIDDEN'
  end
$$;

-- Volver a tomar un pedido al que se dijo "No puedo", si sigue abierto y el
-- profesional todavía puede trabajar. Las mismas revisiones que al aceptar
-- vuelven a correr en _hmy_assign_pro.
create function public.reopen_ya_offer(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform 1 from public.booking_offers
  where booking_id = b.id and professional_id = auth.uid() and status = 'declined' for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status = 'cancelled' then raise exception 'HMY_REQUEST_CANCELLED'; end if;
  if b.status <> 'awaiting_response' or b.professional_id is not null then raise exception 'HMY_ALREADY_TAKEN'; end if;
  if public.hmy_response_deadline(b) < now() then raise exception 'HMY_REQUEST_EXPIRED'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if not public.hmy_professional_active(auth.uid()) then raise exception 'HMY_PROFESSIONAL_NOT_APPROVED'; end if;
  update public.booking_offers set status = 'pending', responded_at = null
  where booking_id = b.id and professional_id = auth.uid();
end $$;

-- "No puedo" dos veces (doble toque) no falla.
create or replace function public.decline_ya_offer(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.booking_offers set status = 'declined', responded_at = now()
  where booking_id = p_booking and professional_id = auth.uid() and status = 'pending';
  if not found and not exists (select 1 from public.booking_offers
                               where booking_id = p_booking and professional_id = auth.uid() and status = 'declined') then
    raise exception 'HMY_NOT_FOUND';
  end if;
end $$;

-- ---------------------------------------------------------------- Contraoferta
-- La comisión que falta cubrir si el total pasa a p_total: la diferencia con
-- la del total de ahora (cero si baja).
create function public.hmy_total_extra_commission(b public.bookings, p_total numeric) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare r public.commission_rules;
begin
  if b.commission_rule_id is null then return 0; end if;
  select * into r from public.commission_rules where id = b.commission_rule_id;
  if r.rate_percent is null then return 0; end if;
  return greatest(round((p_total - (b.agreed_amount + b.extras_amount)) * r.rate_percent / 100, 2), 0);
end $$;

-- ¿Alcanza el saldo para la comisión de la reparación o del total nuevo?
-- Solo revisa: no mueve dinero (0066).
create or replace function public._hmy_reserve_extra(b public.bookings, o public.price_offers) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  v_add numeric(10,2);
begin
  if b.commission_rule_id is null then return true; end if; -- el trabajo no tiene comisión
  select * into r from public.commission_rules where id = b.commission_rule_id;
  if r.rate_percent is null then return true; end if;
  v_add := case when o.kind = 'total' then public.hmy_total_extra_commission(b, o.amount)
                else round(o.amount * r.rate_percent / 100, 2) end;
  if v_add <= 0 then return true; end if;
  perform 1 from public.wallets where professional_id = b.professional_id for update;
  return coalesce((select available from public.wallets where professional_id = b.professional_id), 0)
         >= public.hmy_commission_open(b.professional_id) + v_add;
end $$;

-- Los dos aceptaron la reparación o el total nuevo: cuenta si el saldo cubre
-- su comisión; si no, espera la recarga del profesional.
create or replace function public._hmy_extra_effective(p_offer bigint) returns text
language plpgsql security definer set search_path = public as $$
declare
  o public.price_offers;
  b public.bookings;
  v_what text;
begin
  select * into o from public.price_offers where id = p_offer for update;
  select * into b from public.bookings where id = o.booking_id for update;
  v_what := case o.kind when 'repair' then 'Reparación: Bs ' || o.amount
                        when 'total' then 'Nuevo total: Bs ' || o.amount
                        else 'Cobro extra: Bs ' || o.amount end;
  if not public._hmy_reserve_extra(b, o) then
    update public.price_offers set status = 'awaiting_funds' where id = o.id;
    perform public.notify(b.professional_id, 'price_offer', 'Recarga tu saldo para el precio nuevo',
      v_what || '. El cliente lo aceptó; cuenta cuando tu saldo cubra su comisión.',
      jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
    perform public.notify(b.customer_id, 'price_offer', 'Precio nuevo en espera',
      v_what || '. Todavía no cuenta: el precio acordado sigue igual.', jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
    return 'awaiting_funds';
  end if;
  update public.price_offers set status = 'accepted' where id = o.id;
  if o.kind = 'total' then
    update public.bookings set extras_amount = o.amount - agreed_amount, total_offer_id = o.id where id = b.id;
  else
    update public.bookings set extras_amount = extras_amount + o.amount where id = b.id;
  end if;
  perform public.audit('price.change_accepted', 'bookings', b.id::text,
    jsonb_build_object('code', b.code, 'offer_id', o.id, 'kind', o.kind, 'amount', o.amount,
                       'total_before', b.agreed_amount + b.extras_amount,
                       'total_after', case when o.kind = 'total' then o.amount else b.agreed_amount + b.extras_amount + o.amount end));
  perform public.notify(b.customer_id, 'price_offer',
    case when o.kind = 'total' then 'Nuevo precio acordado' else 'Monto aprobado' end, v_what,
    jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
  perform public.notify(b.professional_id, 'price_offer',
    case when o.kind = 'total' then 'Nuevo precio acordado' else 'Monto aprobado' end, v_what,
    jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
  return 'accepted';
end $$;

-- Igual que 0062, con: la contraoferta del total (cualquiera de los dos), el
-- "monto aparte" que ya no se propone, y el motivo claro si el profesional
-- soltó el pedido.
create or replace function public.propose_price(
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
  v_kind text := coalesce(p_kind, 'service');
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  v_role := public.hmy_price_role(b, v_me);
  if v_role is null then raise exception '%', public.hmy_not_my_request(b, v_me); end if;
  if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;

  v_pre := b.agreed_amount is null and b.status in ('requested', 'awaiting_response', 'quote_sent');
  if v_pre then
    if v_kind not in ('service', 'inspection') then raise exception 'HMY_INVALID_PRICE_KIND'; end if;
    if public.hmy_response_deadline(b) < now() then raise exception 'HMY_REQUEST_EXPIRED'; end if;
  elsif b.agreed_amount is not null and b.status in ('confirmed', 'on_the_way', 'in_progress') then
    -- Desde 0067 solo la contraoferta del total o la reparación (después de una visita).
    if v_kind not in ('total', 'repair') then raise exception 'HMY_INVALID_PRICE_KIND'; end if;
    if v_kind = 'repair' and (b.agreed_kind <> 'inspection' or exists (
         select 1 from public.price_offers where booking_id = b.id and kind = 'repair' and status = 'accepted')) then
      raise exception 'HMY_INVALID_PRICE_KIND';
    end if;
    if v_kind = 'total' and v_amount = b.agreed_amount + b.extras_amount then raise exception 'HMY_SAME_PRICE'; end if;
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

  -- El profesional solo propone lo que su saldo cubre (la comisión se cobra en "Ya pagué").
  if v_role = 'professional' and v_pre then perform public._hmy_require_cover(v_me, b, v_amount, false); end if;
  if v_role = 'professional' and v_kind = 'total' and public.hmy_total_extra_commission(b, v_amount) > 0 then
    perform 1 from public.wallets where professional_id = v_me for update;
    if coalesce((select available from public.wallets where professional_id = v_me), 0)
       < public.hmy_commission_open(v_me) + public.hmy_total_extra_commission(b, v_amount) then
      raise exception 'HMY_INSUFFICIENT_BALANCE';
    end if;
  end if;

  if (select count(*) from public.price_offers where booking_id = b.id and author_id = v_me) >= 40 then
    raise exception 'HMY_TOO_MANY_OFFERS';
  end if;

  -- Doble toque: la misma propuesta abierta no se repite.
  select id into v_same from public.price_offers
  where booking_id = b.id and professional_id is not distinct from v_thread and author_id = v_me
    and status = 'open' and kind = v_kind and amount = v_amount
    and note is not distinct from v_note;
  if v_same is not null then return v_same; end if;

  -- Una propuesta nueva reemplaza la que estaba abierta en esa conversación
  -- (la del otro también: es una contraoferta). Un total nuevo reemplaza
  -- también al que esperaba recarga.
  update public.price_offers set status = 'superseded', responded_at = now()
  where booking_id = b.id and professional_id is not distinct from v_thread
    and (status = 'open' or (v_kind = 'total' and status = 'awaiting_funds' and kind = 'total'))
    and (kind in ('service', 'inspection')) = v_pre;

  insert into public.price_offers (booking_id, professional_id, author_id, author_role, kind, amount, note)
  values (b.id, v_thread, v_me, v_role, v_kind, v_amount, v_note)
  returning id into v_id;

  if v_pre and v_role = 'professional' and b.status = 'requested' then
    perform public._booking_move(b.id, 'quote_sent', 'professional', 'Propuesta de precio: Bs ' || v_amount);
  end if;

  v_who := case v_kind when 'inspection' then 'Visita de inspección' when 'repair' then 'Reparación'
                       when 'total' then 'Nuevo total' else 'Precio' end;
  if v_kind = 'total' then
    perform public.notify(case when v_role = 'professional' then b.customer_id else b.professional_id end,
      'price_offer', 'Contraoferta: nuevo precio total',
      'Bs ' || v_amount || ' (ahora Bs ' || (b.agreed_amount + b.extras_amount) || '). El precio no cambia hasta que la aceptes.',
      jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
  elsif v_role = 'professional' then
    perform public.notify(b.customer_id, 'price_offer',
      case when v_pre then 'Te propusieron un precio' else 'Te pidieron aprobar un monto' end,
      v_who || ': Bs ' || v_amount || ' · ' || coalesce((select display_name from public.professional_profiles
                                                       where user_id = v_me), 'Profesional'),
      jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
  elsif v_thread is not null then
    perform public.notify(v_thread, 'price_offer', 'El cliente propone un precio', v_who || ': Bs ' || v_amount,
                          jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
  elsif exists (select 1 from public.price_offers where booking_id = b.id and id < v_id and author_id = v_me) then
    for v_pro in select o.professional_id from public.booking_offers o
                 where o.booking_id = b.id and o.status = 'pending' loop
      perform public.notify(v_pro, 'price_offer', 'El cliente cambió su precio', 'Bs ' || v_amount,
                            jsonb_build_object('booking_id', b.id, 'offer_id', v_id));
    end loop;
  end if;
  return v_id;
end $$;

-- Igual que 0062, con el motivo claro si el profesional soltó el pedido y la
-- contraoferta del total: si la acepta el profesional, su saldo tiene que
-- cubrir la comisión del total nuevo.
create or replace function public.accept_price_offer(p_offer bigint) returns public.booking_status
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
  if v_role is null then raise exception '%', public.hmy_not_my_request(b, v_me); end if;
  if o.kind in ('service', 'inspection')
     and (b.agreed_amount is not null or b.status not in ('requested', 'awaiting_response', 'quote_sent')) then
    raise exception '%', case when exists (select 1 from public.booking_offers where booking_id = b.id)
                              then 'HMY_ALREADY_TAKEN' else 'HMY_INVALID_TRANSITION' end;
  end if;
  if v_role = o.author_role
     or (v_role = 'professional' and o.professional_id is distinct from v_me and o.professional_id is not null) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if v_role = 'customer' and public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if o.status <> 'open' then raise exception 'HMY_OFFER_CHANGED'; end if;

  if o.kind in ('repair', 'extra', 'total') then
    if b.status not in ('confirmed', 'on_the_way', 'in_progress') then raise exception 'HMY_NOT_NEGOTIABLE'; end if;
    if v_role = 'professional' and o.kind = 'total' and not public._hmy_reserve_extra(b, o) then
      raise exception 'HMY_INSUFFICIENT_BALANCE';
    end if;
    update public.price_offers set responded_by = v_me, responded_at = now() where id = o.id;
    perform public._hmy_extra_effective(o.id);
    return b.status;
  end if;

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

-- Rechazar una contraoferta del total también avisa con el precio que sigue.
create or replace function public.reject_price_offer(p_offer bigint) returns void
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
    'Bs ' || o.amount || case when o.kind = 'total'
                              then '. El precio sigue en Bs ' || (b.agreed_amount + b.extras_amount) || '.'
                              else '. Puedes proponer otro monto.' end,
    jsonb_build_object('booking_id', b.id, 'offer_id', o.id));
end $$;

-- ---------------------------------------------------------------- Penalización
create function public.hmy_cancel_penalty_amount() returns numeric
language sql immutable as $$ select 3.00::numeric(10,2) $$;

-- Cobra la penalización de un pedido cancelado por el profesional, una sola
-- vez. Nunca deja saldo negativo.
create function public._hmy_charge_cancel_penalty(p_booking uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_amount numeric(10,2) := public.hmy_cancel_penalty_amount();
  v_available numeric(10,2);
  v_take numeric(10,2);
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.cancel_penalty is not null or b.professional_id is null then return 0; end if;
  select available into v_available from public.wallets where professional_id = b.professional_id for update;
  v_take := least(v_amount, coalesce(v_available, 0));
  if v_take > 0 then
    perform public.wallet_post(b.professional_id, 'penalty', -v_take, 0, 'cancel-penalty:' || b.id, b.id, null,
                               'Penalización por cancelación ' || b.code);
  end if;
  update public.bookings set cancel_penalty = v_take, cancel_penalty_shortfall = v_amount - v_take where id = b.id;
  perform public.audit('cancel_penalty.charge', 'bookings', b.id::text,
                       jsonb_build_object('code', b.code, 'amount', v_amount, 'charged', v_take,
                                          'shortfall', v_amount - v_take));
  perform public.notify(b.professional_id, 'cancel_penalty', 'Penalización por cancelación',
    'Solicitud ' || b.code || ': ' || to_char(v_take, 'FM999G990D00') || ' Bs descontados de tu billetera.'
    || case when v_amount > v_take then ' Tu saldo no alcanzó para todo; el equipo lo revisará.' else '' end,
    jsonb_build_object('booking_id', b.id));
  return v_take;
end $$;

-- Cancelar: el motivo es opcional para los dos. El profesional que ya había
-- aceptado paga la penalización; el cliente nunca.
create or replace function public.cancel_booking(p_booking uuid, p_reason text) returns public.booking_status
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_actor text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_status public.booking_status;
begin
  select * into b from public.bookings where id = p_booking for update;
  v_actor := case when b.customer_id = auth.uid() then 'customer'
                  when b.professional_id = auth.uid() then 'professional' end;
  if v_actor is null then raise exception 'HMY_FORBIDDEN'; end if;
  -- Doble toque o dos teléfonos a la vez: ya está cancelada, no se repite.
  if b.status = 'cancelled' then return b.status; end if;
  if v_reason is not null and char_length(v_reason) > 500 then raise exception 'HMY_REASON_REQUIRED'; end if;
  v_status := (public._booking_move(p_booking, 'cancelled', v_actor,
                 coalesce(v_reason, case when v_actor = 'professional' then 'Cancelada por el profesional'
                                         else 'Cancelada por el cliente' end))).status;
  if v_actor = 'professional' and b.status in ('confirmed', 'on_the_way') then
    perform public._hmy_charge_cancel_penalty(p_booking);
  end if;
  return v_status;
end $$;

-- El propietario devuelve una penalización (emergencia, falla de la
-- plataforma u otra excepción aprobada). Nota y confirmación fuerte.
create function public.owner_waive_cancel_penalty(p_booking uuid, p_note text, p_auth_method text) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_amount numeric(10,2);
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found or b.cancel_penalty is null then raise exception 'HMY_NOT_FOUND'; end if;
  if b.cancel_penalty_waived_at is not null then raise exception 'HMY_ALREADY_REVIEWED'; end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.cancel_penalty');
  v_amount := b.cancel_penalty;
  if v_amount > 0 then
    perform public.wallet_post(b.professional_id, 'refund', v_amount, 0, 'cancel-penalty-refund:' || b.id, b.id, null,
                               'Devolución de la penalización ' || b.code || ': ' || btrim(p_note));
  end if;
  update public.bookings set cancel_penalty_waived_at = now(), cancel_penalty_shortfall = 0 where id = b.id;
  perform public.audit('cancel_penalty.waive', 'bookings', b.id::text,
                       jsonb_build_object('code', b.code, 'refunded', v_amount, 'note', btrim(p_note),
                                          'auth_method', p_auth_method));
  perform public.notify(b.professional_id, 'cancel_penalty', 'Penalización devuelta',
    'Solicitud ' || b.code || ': ' || to_char(v_amount, 'FM999G990D00') || ' Bs volvieron a tu saldo.',
    jsonb_build_object('booking_id', b.id));
  return v_amount;
end $$;

-- Pagos en revisión (0066) más las penalizaciones de los últimos 30 días.
alter function public.owner_payment_reviews(text) rename to _owner_payment_reviews_0066;
create function public.owner_payment_reviews(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public._owner_payment_reviews_0066(p_status) || jsonb_build_object('penalties', coalesce((
    select jsonb_agg(jsonb_build_object(
      'booking_id', b.id, 'booking_code', b.code, 'charged', b.cancel_penalty,
      'shortfall', b.cancel_penalty_shortfall, 'waived', b.cancel_penalty_waived_at is not null,
      'cancelled_at', b.cancelled_at, 'professional_name', coalesce(pp.display_name, pr.full_name))
      order by b.cancelled_at desc)
    from (select * from public.bookings where cancel_penalty is not null
            and coalesce(cancelled_at, updated_at) > now() - interval '30 days'
          order by cancelled_at desc limit 100) b
    left join public.professional_profiles pp on pp.user_id = b.professional_id
    left join public.profiles pr on pr.id = b.professional_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- Historial
-- Movimientos de la billetera propia: el cambio del saldo total (disponible +
-- reservado) y el total después. Una reserva vieja o su liberación no cambian
-- el total y no se muestran.
create function public.my_wallet_history(p_limit int default 50) returns table (
  id bigint, entry_type public.ledger_entry_type, amount numeric, balance_after numeric,
  booking_id uuid, booking_code text, note text, created_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select l.id, l.entry_type, l.available_delta + l.reserved_delta, l.available_after + l.reserved_after,
         l.booking_id, b.code, l.note, l.created_at
  from public.wallet_ledger l
  left join public.bookings b on b.id = l.booking_id
  where l.professional_id = auth.uid() and l.available_delta + l.reserved_delta <> 0
  order by l.created_at desc, l.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200)
$$;

-- ---------------------------------------------------------------- Detalle
alter function public.booking_detail(uuid) rename to _booking_detail_0066;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_0066(p_booking); -- valida quién puede verlo
  b public.bookings;
  v_pro boolean;
begin
  select * into b from public.bookings where id = p_booking;
  v_pro := b.professional_id = auth.uid() or public.is_admin();
  return v
    || jsonb_build_object('my_invite', (select status from public.booking_offers
                                        where booking_id = b.id and professional_id = auth.uid()))
    || jsonb_build_object('payment', coalesce(v -> 'payment', '{}'::jsonb) || jsonb_build_object(
         'commission_rate', case when v_pro then (select rate_percent from public.commission_rules
                                                  where id = b.commission_rule_id) end,
         'commission_amount', case when v_pro and b.commission_rule_id is not null
                                   then public.hmy_commission_of(b) end))
    || jsonb_build_object('cancel_penalty', case when v_pro and b.cancel_penalty is not null then jsonb_build_object(
         'charged', b.cancel_penalty, 'shortfall', b.cancel_penalty_shortfall,
         'waived', b.cancel_penalty_waived_at is not null) end);
end $$;

-- ---------------------------------------------------------------- Mis solicitudes
-- my_bookings (0064) más "negotiating": hay una propuesta de precio de un
-- profesional esperando (en la lista del profesional, la suya).
drop function public.my_bookings(text);
create function public.my_bookings(p_as text default 'customer')
returns table (
  id uuid, code text, status public.booking_status, mode public.booking_mode,
  category_id int, category text, city text, zone text,
  description text, scheduled_start timestamptz, created_at timestamptz,
  other_user_id uuid, other_name text, other_photo_path text,
  quote_amount numeric, final_amount numeric, has_review boolean, is_offer boolean, distance_km numeric,
  problems text[], agreed_amount numeric, extras_amount numeric, negotiating boolean
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
         case when p_as = 'professional' then public.booking_distance_for_me(b.id) end,
         coalesce(b.problem_labels, '{}'),
         b.agreed_amount, b.extras_amount,
         b.agreed_amount is null and b.status in ('requested', 'awaiting_response', 'quote_sent')
           and exists (select 1 from public.price_offers po
                       where po.booking_id = b.id and po.status = 'open' and po.author_role = 'professional'
                         and po.kind in ('service', 'inspection')
                         and (p_as = 'customer' or po.professional_id = auth.uid()))
  from public.bookings b
  join public.service_categories sc on sc.id = b.category_id
  join public.cities c on c.id = b.city_id
  left join public.service_zones z on z.id = b.zone_id
  left join public.professional_profiles pp on pp.user_id = b.professional_id
  left join public.profiles cp on cp.id = b.customer_id
  where (p_as = 'customer' and b.customer_id = auth.uid())
     or (p_as = 'professional' and (b.professional_id = auth.uid() or public.has_pending_offer(b.id)))
  order by b.status in ('completed', 'cancelled'), b.created_at desc
  limit 100 + (select count(*) from public.bookings x
               where x.status not in ('completed', 'cancelled')
                 and ((p_as = 'customer' and x.customer_id = auth.uid())
                      or (p_as = 'professional' and x.professional_id = auth.uid())))
$$;

-- ---------------------------------------------------------------- Textos de avisos
-- (hmy_push_text ya usa el título y el cuerpo de la notificación.)

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_not_my_request(public.bookings, uuid) from public, anon, authenticated;
revoke execute on function public.hmy_total_extra_commission(public.bookings, numeric) from public, anon, authenticated;
revoke execute on function public._hmy_reserve_extra(public.bookings, public.price_offers) from public, anon, authenticated;
revoke execute on function public._hmy_extra_effective(bigint) from public, anon, authenticated;
revoke execute on function public._hmy_charge_cancel_penalty(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_cancel_penalty_amount() from public, anon, authenticated;
revoke execute on function public._owner_payment_reviews_0066(text) from public, anon, authenticated;
revoke execute on function public._booking_detail_0066(uuid) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.reopen_ya_offer(uuid)', 'public.decline_ya_offer(uuid)',
    'public.propose_price(uuid, numeric, text, text, uuid)', 'public.accept_price_offer(bigint)',
    'public.reject_price_offer(bigint)', 'public.cancel_booking(uuid, text)',
    'public.owner_waive_cancel_penalty(uuid, text, text)', 'public.owner_payment_reviews(text)',
    'public.my_wallet_history(int)', 'public.booking_detail(uuid)', 'public.my_bookings(text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
