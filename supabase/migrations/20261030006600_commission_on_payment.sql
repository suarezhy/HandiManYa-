-- HandiMan ¡Ya! — 0066 la comisión se cobra cuando el cliente toca "Ya pagué".
--
-- Reglas finales del dueño (30-10-2026):
-- 1. Nada se reserva ni se descuenta al acordar el precio ni al empezar el
--    trabajo. Las reservas que quedaban en trabajos abiertos vuelven al saldo,
--    cada una con su propio movimiento; el historial no se toca.
-- 2. El 10 % se cobra una sola vez, cuando el cliente toca "Ya pagué" después
--    de que el profesional terminó el trabajo (work_finished o completed).
--    "Confirmar trabajo terminado" no cobra. "Recibí el pago" del profesional
--    tampoco. Un doble toque o un reintento no cobra dos veces: la fila del
--    pedido se bloquea, la marca se pone una vez y el movimiento lleva la
--    clave 'commission:<pedido>'.
-- 3. Saldo suficiente sin reservar: para acordar un precio o aprobar un monto
--    aparte, el saldo del profesional tiene que cubrir la comisión de ese
--    trabajo más la de sus otros trabajos todavía sin cobrar. Es solo una
--    revisión: no mueve dinero ni aparece en la billetera. Se hace con la
--    billetera bloqueada, así dos trabajos al mismo tiempo no cuentan con el
--    mismo saldo.
-- 4. Si al cobrar falta saldo (solo pasa si el propietario revirtió una
--    recarga o hizo un ajuste en contra), se cobra lo que hay y nunca queda
--    negativo. La diferencia queda anotada para el propietario
--    (commission_shortfall) y el profesional no acuerda trabajos nuevos hasta
--    que se resuelva. Ya pagué del cliente nunca falla por el saldo del
--    profesional.
-- 5. Si el profesional dice "No recibí el pago", se abre una revisión de pago
--    para el propietario (payment_reviews). Si el propietario le da la razón,
--    la comisión vuelve a su saldo. Una disputa del trabajo que el propietario
--    cierra como cancelada también devuelve la comisión.
-- 6. El propietario ve las revisiones abiertas y los trabajos completados en
--    los que el cliente no marcó "Ya pagué".
--
-- Agrega columnas, una tabla y funciones; reemplaza las funciones de comisión.

-- ---------------------------------------------------------------- Tablas
alter table public.bookings
  add column commission_charged_at timestamptz,
  add column commission_refunded_at timestamptz;

create table public.payment_reviews (
  id bigint generated always as identity primary key,
  booking_id uuid not null unique references public.bookings(id),
  professional_id uuid not null references public.profiles(id),
  customer_id uuid not null references public.profiles(id),
  reason text not null check (char_length(reason) between 5 and 500),
  commission_amount numeric(10,2) not null default 0,
  status text not null default 'open' check (status in ('open', 'refunded', 'rejected')),
  resolution text check (resolution is null or char_length(resolution) <= 500),
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index payment_reviews_status_idx on public.payment_reviews (status, created_at desc);

-- Solo con las funciones de abajo.
alter table public.payment_reviews enable row level security;
revoke all on public.payment_reviews from public, anon, authenticated;

-- ---------------------------------------------------------------- Cuánto
-- La comisión de un pedido con regla: porcentaje del monto final (o del
-- acordado más lo aprobado aparte) o el cargo fijo.
create function public.hmy_commission_of(b public.bookings) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((
    select coalesce(
      case when r.rate_percent is not null
                and coalesce(b.final_amount, b.agreed_amount + b.extras_amount, b.quote_amount) is not null
           then round(coalesce(b.final_amount, b.agreed_amount + b.extras_amount, b.quote_amount)
                      * r.rate_percent / 100, 2) end,
      r.fixed_fee, 0)
    from public.commission_rules r where r.id = b.commission_rule_id), 0)
$$;

-- Lo que el saldo del profesional tiene que poder cubrir: la comisión de sus
-- trabajos acordados y todavía sin cobrar. Un trabajo completado sin "Ya
-- pagué" cuenta 72 horas; después pasa a la revisión del propietario.
create function public.hmy_commission_open(p_pro uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(public.hmy_commission_of(x)), 0)
  from public.bookings x
  where x.professional_id = p_pro
    and x.commission_rule_id is not null and x.commission_charged_at is null and x.commission_captured is null
    and (x.status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished', 'disputed')
         or (x.status = 'completed' and x.completed_at > now() - interval '72 hours'))
$$;

-- Comisión de un monto y si el saldo la cubre junto con lo que ya está por
-- cobrar. p_extra: un monto aparte (solo suma el porcentaje).
create or replace function public.hmy_commission_need(p_pro uuid, p_category int, p_city smallint, p_amount numeric,
                                                      p_extra boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r public.commission_rules := public.commission_rule_for(p_category, p_city);
  v_commission numeric(10,2) := 0;
  v_needed numeric(10,2) := 0;
  v_open numeric(10,2) := public.hmy_commission_open(p_pro);
  v_available numeric(10,2) := coalesce((select available from public.wallets where professional_id = p_pro), 0);
  v_debt numeric(10,2) := (select coalesce(sum(commission_shortfall), 0) from public.bookings
                           where professional_id = p_pro and commission_shortfall > 0);
begin
  if r.id is not null then
    if p_extra then
      v_commission := case when r.rate_percent is not null then round(p_amount * r.rate_percent / 100, 2) else 0 end;
      v_needed := v_open + v_commission;
    else
      v_commission := coalesce(case when r.rate_percent is not null then round(p_amount * r.rate_percent / 100, 2) end,
                               r.fixed_fee, 0);
      v_needed := greatest(r.min_balance, v_open + v_commission);
    end if;
  end if;
  return jsonb_build_object(
    'has_rule', r.id is not null, 'rate_percent', r.rate_percent, 'fixed_fee', r.fixed_fee,
    'amount', round(p_amount, 2), 'commission', v_commission, 'net', round(p_amount, 2) - v_commission,
    'needed', v_needed, 'open_commissions', v_open, 'available', v_available, 'pending_debt', v_debt,
    'can_cover', v_debt = 0 and v_available >= v_needed,
    'missing', greatest(v_needed - v_available, 0));
end $$;

-- Proponer un precio: la misma revisión, con la billetera bloqueada.
create or replace function public._hmy_require_cover(p_pro uuid, b public.bookings, p_amount numeric, p_extra boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare n jsonb;
begin
  perform 1 from public.wallets where professional_id = p_pro for update;
  n := public.hmy_commission_need(p_pro, b.category_id, b.city_id, p_amount, p_extra);
  if (n ->> 'pending_debt')::numeric > 0 then raise exception 'HMY_COMMISSION_DEBT'; end if;
  if not (n ->> 'can_cover')::boolean then raise exception 'HMY_INSUFFICIENT_BALANCE'; end if;
end $$;

-- ---------------------------------------------------------------- Acordar
-- Al confirmar (precio acordado) se anota la regla de comisión del trabajo y
-- se revisa que el saldo cubra todo lo que queda por cobrar. No mueve dinero.
-- _booking_move la llama con este nombre desde 0003.
create or replace function public._commission_reserve(b public.bookings) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  w public.wallets;
begin
  r := public.commission_rule_for(b.category_id, b.city_id);
  if r.id is null then
    return; -- Sin regla configurada: no se cobra nada.
  end if;
  if exists (select 1 from public.bookings x where x.professional_id = b.professional_id
             and x.commission_shortfall > 0) then
    raise exception 'HMY_COMMISSION_DEBT';
  end if;
  -- Bloquea la billetera: dos trabajos confirmados a la vez se revisan de a uno.
  select * into w from public.wallets where professional_id = b.professional_id for update;
  if not found then raise exception 'HMY_WALLET_NOT_FOUND'; end if;
  update public.bookings set commission_rule_id = r.id where id = b.id;
  if w.available < greatest(r.min_balance, public.hmy_commission_open(b.professional_id)) then
    raise exception 'HMY_INSUFFICIENT_BALANCE';
  end if;
end $$;

-- Un monto aparte cuenta si el saldo cubre su comisión y todo lo demás por
-- cobrar. Tampoco mueve dinero. False: queda esperando recarga (0062).
create or replace function public._hmy_reserve_extra(b public.bookings, o public.price_offers) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  v_add numeric(10,2);
begin
  if b.commission_rule_id is null then return true; end if; -- el trabajo no tiene comisión
  select * into r from public.commission_rules where id = b.commission_rule_id;
  if r.rate_percent is null then return true; end if;
  v_add := round(o.amount * r.rate_percent / 100, 2);
  if v_add <= 0 then return true; end if;
  perform 1 from public.wallets where professional_id = b.professional_id for update;
  return coalesce((select available from public.wallets where professional_id = b.professional_id), 0)
         >= public.hmy_commission_open(b.professional_id) + v_add;
end $$;

-- Completar ya no cobra (lo llama _booking_move al pasar a completed).
create or replace function public._commission_capture(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  return; -- Desde 0066 la comisión se cobra en "Ya pagué" (_commission_charge).
end $$;

-- ---------------------------------------------------------------- Cobrar
-- Cobra la comisión del pedido una sola vez. Nunca deja saldo negativo: si
-- falta, cobra lo que hay y anota la diferencia para el propietario.
create function public._commission_charge(p_booking uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_amount numeric(10,2);
  v_available numeric(10,2);
  v_take numeric(10,2);
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.commission_rule_id is null or b.commission_charged_at is not null or b.commission_captured is not null then
    return 0;
  end if;
  v_amount := public.hmy_commission_of(b);
  select available into v_available from public.wallets where professional_id = b.professional_id for update;
  v_take := least(v_amount, coalesce(v_available, 0));
  if v_take > 0 then
    perform public.wallet_post(b.professional_id, 'commission_capture', -v_take, 0, 'commission:' || b.id, b.id, null,
                               'Comisión ' || b.code || ' (el cliente marcó "Ya pagué")');
  end if;
  update public.bookings
  set commission_captured = v_take, commission_charged_at = now(), commission_shortfall = v_amount - v_take
  where id = b.id;
  perform public.audit('commission.charge', 'bookings', b.id::text,
                       jsonb_build_object('code', b.code, 'amount', v_amount, 'charged', v_take,
                                          'shortfall', v_amount - v_take, 'final_amount', b.final_amount));
  if v_take > 0 then
    perform public.notify(b.professional_id, 'commission_charged', 'Comisión cobrada',
      'Solicitud ' || b.code || ': ' || to_char(v_take, 'FM999G990D00') || ' Bs. El cliente marcó "Ya pagué".',
      jsonb_build_object('booking_id', b.id));
  end if;
  if v_amount > v_take then
    perform public.notify(b.professional_id, 'commission_charged', 'Tu saldo no alcanzó para la comisión',
      'Solicitud ' || b.code || '. Escribe a soporte para resolverlo antes de aceptar trabajos nuevos.',
      jsonb_build_object('booking_id', b.id));
  end if;
  return v_take;
end $$;

-- Devuelve la comisión cobrada de un pedido, una sola vez.
create function public._commission_refund(p_booking uuid, p_note text) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_amount numeric(10,2);
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.commission_charged_at is null or b.commission_refunded_at is not null then return 0; end if;
  v_amount := coalesce(b.commission_captured, 0);
  if v_amount > 0 then
    perform public.wallet_post(b.professional_id, 'refund', v_amount, 0, 'commission-refund:' || b.id, b.id, null,
                               'Devolución de la comisión ' || b.code || ': ' || p_note);
    perform public.notify(b.professional_id, 'commission_refunded', 'Comisión devuelta',
      'Solicitud ' || b.code || ': ' || to_char(v_amount, 'FM999G990D00') || ' Bs volvieron a tu saldo.',
      jsonb_build_object('booking_id', b.id));
  end if;
  update public.bookings set commission_refunded_at = now(), commission_shortfall = 0 where id = b.id;
  perform public.audit('commission.refund', 'bookings', b.id::text,
                       jsonb_build_object('code', b.code, 'amount', v_amount, 'note', p_note));
  return v_amount;
end $$;

-- Una disputa que el propietario cierra como cancelada devuelve la comisión.
create function public.hmy_commission_refund_on_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._commission_refund(new.id, 'el trabajo se canceló después de la disputa');
  return null;
end $$;

create trigger bookings_commission_refund after update of status on public.bookings
  for each row when (new.status = 'cancelled' and old.status is distinct from 'cancelled'
                     and new.commission_charged_at is not null and new.commission_refunded_at is null)
  execute function public.hmy_commission_refund_on_cancel();

-- "Ya pagué" (cliente) cobra la comisión; "Recibí el pago" (profesional) solo
-- queda anotado. Repetir cualquiera de los dos no hace nada.
create or replace function public.acknowledge_payment(p_booking uuid, p_method public.payment_method)
returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.customer_id = auth.uid() then
    if b.customer_paid_ack_at is not null then return; end if;
    if b.status not in ('work_finished', 'completed') then raise exception 'HMY_INVALID_TRANSITION'; end if;
    update public.bookings set customer_paid_ack_at = now(), payment_method = coalesce(p_method, payment_method)
    where id = p_booking;
    perform public._commission_charge(p_booking);
  elsif b.professional_id = auth.uid() then
    if b.professional_paid_ack_at is not null then return; end if;
    if b.status not in ('work_finished', 'completed') then raise exception 'HMY_INVALID_TRANSITION'; end if;
    update public.bookings set professional_paid_ack_at = now(), payment_method = coalesce(payment_method, p_method)
    where id = p_booking;
  else
    raise exception 'HMY_FORBIDDEN';
  end if;
end $$;

-- ---------------------------------------------------------------- Revisión de pago
-- El profesional dice que no recibió el pago que el cliente marcó. Una vez
-- por trabajo, hasta 7 días después de "Ya pagué".
create function public.report_payment_not_received(p_booking uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_id bigint;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.professional_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(v_reason) < 5 or char_length(v_reason) > 500 then raise exception 'HMY_REASON_REQUIRED'; end if;
  if exists (select 1 from public.payment_reviews where booking_id = b.id) then raise exception 'HMY_ALREADY_REPORTED'; end if;
  if b.customer_paid_ack_at is null or b.professional_paid_ack_at is not null
     or b.customer_paid_ack_at < now() - interval '7 days' then
    raise exception 'HMY_INVALID_TRANSITION';
  end if;
  insert into public.payment_reviews (booking_id, professional_id, customer_id, reason, commission_amount)
  values (b.id, b.professional_id, b.customer_id, v_reason, coalesce(b.commission_captured, 0))
  returning id into v_id;
  perform public.notify(b.customer_id, 'payment_review', 'Revisamos tu pago',
    'Solicitud ' || b.code || ': el profesional dice que no recibió el pago. Guarda tu comprobante; el equipo te escribirá.',
    jsonb_build_object('booking_id', b.id));
  perform public.audit('payment.not_received', 'payment_reviews', v_id::text,
                       jsonb_build_object('booking_id', b.id, 'code', b.code, 'reason', v_reason));
  return jsonb_build_object('id', v_id, 'status', 'open');
end $$;

-- Propietario: revisiones de pago y trabajos completados sin "Ya pagué".
create function public.owner_payment_reviews(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
                  'open', count(*) filter (where status = 'open'),
                  'refunded', count(*) filter (where status = 'refunded'),
                  'rejected', count(*) filter (where status = 'rejected'))
                from public.payment_reviews),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'booking_id', b.id, 'booking_code', b.code, 'status', v.status, 'reason', v.reason,
        'commission_amount', v.commission_amount, 'final_amount', b.final_amount,
        'payment_method', b.payment_method, 'customer_paid_at', b.customer_paid_ack_at,
        'professional_name', coalesce(pp.display_name, pr.full_name), 'customer_name', cu.full_name,
        'customer_refunded_before', (select count(*) from public.payment_reviews x
                                     where x.customer_id = v.customer_id and x.status = 'refunded' and x.id <> v.id),
        'resolution', v.resolution, 'resolved_at', v.resolved_at, 'created_at', v.created_at)
        order by v.created_at desc)
      from (select * from public.payment_reviews
            where p_status is null or p_status = 'all' or status = p_status
            order by created_at desc limit 100) v
      join public.bookings b on b.id = v.booking_id
      left join public.professional_profiles pp on pp.user_id = v.professional_id
      left join public.profiles pr on pr.id = v.professional_id
      left join public.profiles cu on cu.id = v.customer_id), '[]'::jsonb),
    'unpaid', coalesce((
      select jsonb_agg(jsonb_build_object(
        'booking_id', b.id, 'booking_code', b.code, 'final_amount', b.final_amount,
        'commission', public.hmy_commission_of(b), 'completed_at', b.completed_at,
        'professional_paid_ack', b.professional_paid_ack_at is not null,
        'professional_name', coalesce(pp.display_name, pr.full_name), 'customer_name', cu.full_name)
        order by b.completed_at desc)
      from (select * from public.bookings
            where status = 'completed' and customer_paid_ack_at is null and commission_rule_id is not null
              and commission_captured is null and completed_at < now() - interval '72 hours'
            order by completed_at desc limit 100) b
      left join public.professional_profiles pp on pp.user_id = b.professional_id
      left join public.profiles pr on pr.id = b.professional_id
      left join public.profiles cu on cu.id = b.customer_id), '[]'::jsonb));
end $$;

-- Propietario: resolver una revisión. Con devolución, la comisión vuelve al
-- profesional. Nota obligatoria, código nuevo y auditoría.
create function public.owner_resolve_payment_review(p_id bigint, p_refund boolean, p_note text, p_auth_method text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v public.payment_reviews;
  v_code text;
  v_refunded numeric(10,2) := 0;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into v from public.payment_reviews where id = p_id for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if v.status <> 'open' then raise exception 'HMY_ALREADY_REVIEWED'; end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.payment_review');
  if p_refund then
    v_refunded := public._commission_refund(v.booking_id, 'el cliente no pagó (revisión de pago)');
  end if;
  update public.payment_reviews
  set status = case when p_refund then 'refunded' else 'rejected' end, resolution = btrim(p_note),
      resolved_by = auth.uid(), resolved_at = now()
  where id = v.id returning * into v;
  select code into v_code from public.bookings where id = v.booking_id;
  perform public.notify(v.professional_id, 'payment_review', 'Revisión de pago resuelta',
    'Solicitud ' || v_code || ': ' || case when p_refund then 'te devolvimos la comisión.'
                                           else 'la comisión se mantiene. Escribe a soporte si necesitas ayuda.' end,
    jsonb_build_object('booking_id', v.booking_id));
  perform public.notify(v.customer_id, 'payment_review', 'Revisión de pago resuelta',
    'Solicitud ' || v_code || ': el equipo terminó de revisar el pago.', jsonb_build_object('booking_id', v.booking_id));
  perform public.audit(case when p_refund then 'payment.review_refund' else 'payment.review_reject' end,
                       'payment_reviews', v.id::text,
                       jsonb_build_object('booking_id', v.booking_id, 'refunded', v_refunded, 'note', btrim(p_note),
                                          'auth_method', p_auth_method));
  return jsonb_build_object('id', v.id, 'status', v.status, 'refunded', v_refunded);
end $$;

-- ---------------------------------------------------------------- Lectura
-- Billetera: saldo total y comisiones cobradas (menos las devueltas). Las
-- claves de antes siguen para las versiones viejas de la app.
create or replace function public.my_wallet_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'available', coalesce(w.available, 0),
    'reserved', coalesce(w.reserved, 0),
    'total', coalesce(w.available, 0) + coalesce(w.reserved, 0),
    'commissions_collected',
      coalesce((select sum(-(l.available_delta + l.reserved_delta)) from public.wallet_ledger l
                where l.professional_id = auth.uid() and l.entry_type = 'commission_capture'), 0)
      - coalesce((select sum(l.available_delta) from public.wallet_ledger l
                  where l.professional_id = auth.uid() and l.entry_type = 'refund'
                    and l.idempotency_key like 'commission-refund:%'), 0),
    'commission_pending', coalesce((select sum(commission_shortfall) from public.bookings
                                    where professional_id = auth.uid() and commission_shortfall > 0), 0),
    'extras_awaiting_funds', (select count(*) from public.price_offers o join public.bookings b on b.id = o.booking_id
                              where b.professional_id = auth.uid() and o.status = 'awaiting_funds'))
  from (select 1) one left join public.wallets w on w.professional_id = auth.uid()
$$;

-- El detalle del pedido dice si hay una revisión de pago y, al profesional,
-- cuánto se le cobró de comisión.
alter function public.booking_detail(uuid) rename to _booking_detail_0065;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_0065(p_booking); -- valida quién puede verlo
  b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  return v || jsonb_build_object('payment', jsonb_build_object(
    'customer_paid_at', b.customer_paid_ack_at,
    'professional_paid_at', b.professional_paid_ack_at,
    'review_status', (select status from public.payment_reviews where booking_id = b.id),
    'commission_charged', case when b.professional_id = auth.uid() or public.is_admin()
                               then case when b.commission_refunded_at is null then b.commission_captured else 0 end end,
    'commission_refunded', b.commission_refunded_at is not null));
end $$;

create or replace function public.hmy_push_text(p_kind text) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'ya_offer' then 'Ábrelo para ver el pedido y responder a tiempo.'
    when 'booking_new' then 'Ábrelo para ver la solicitud.'
    when 'message' then 'Ábrelo para leerlo.'
    when 'push_test' then 'Si ves esto en tu teléfono, los avisos funcionan.'
    when 'wallet_credited' then 'Tu saldo ya está disponible.'
    when 'wallet_verifying' then 'Ábrelo para ver el estado de tu recarga.'
    when 'wallet_rejected' then 'Ábrelo para ver el estado de tu recarga.'
    when 'wallet_reversed' then 'Ábrelo para ver el historial de tu billetera.'
    when 'commission_charged' then 'Ábrelo para ver el historial de tu billetera.'
    when 'commission_refunded' then 'Ábrelo para ver el historial de tu billetera.'
    when 'payment_review' then 'Ábrelo para ver el detalle.'
    else 'Ábrelo en HandiMan ¡Ya! para ver el detalle.'
  end
$$;

-- ---------------------------------------------------------------- Datos
-- Las reservas de trabajos sin cobrar vuelven al saldo. Cada una es un
-- movimiento nuevo; ningún movimiento viejo cambia.
do $$
declare b record;
begin
  for b in select id, code, professional_id, commission_reserved from public.bookings
           where commission_reserved > 0 and commission_captured is null
           order by created_at loop
    perform public.wallet_post(b.professional_id, 'commission_release', b.commission_reserved, -b.commission_reserved,
                               'release-0066:' || b.id, b.id, null,
                               'Reserva devuelta ' || b.code || ': la comisión se cobra cuando el cliente marca "Ya pagué"');
    update public.bookings set commission_reserved = 0 where id = b.id;
  end loop;
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_commission_of(public.bookings) from public, anon, authenticated;
revoke execute on function public.hmy_commission_open(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_commission_need(uuid, int, smallint, numeric, boolean) from public, anon, authenticated;
revoke execute on function public._hmy_require_cover(uuid, public.bookings, numeric, boolean) from public, anon, authenticated;
revoke execute on function public._commission_reserve(public.bookings) from public, anon, authenticated;
revoke execute on function public._hmy_reserve_extra(public.bookings, public.price_offers) from public, anon, authenticated;
revoke execute on function public._commission_capture(uuid) from public, anon, authenticated;
revoke execute on function public._commission_charge(uuid) from public, anon, authenticated;
revoke execute on function public._commission_refund(uuid, text) from public, anon, authenticated;
revoke execute on function public.hmy_commission_refund_on_cancel() from public, anon, authenticated;
revoke execute on function public._booking_detail_0065(uuid) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.acknowledge_payment(uuid, public.payment_method)', 'public.report_payment_not_received(uuid, text)',
    'public.owner_payment_reviews(text)', 'public.owner_resolve_payment_review(bigint, boolean, text, text)',
    'public.my_wallet_summary()', 'public.booking_detail(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
