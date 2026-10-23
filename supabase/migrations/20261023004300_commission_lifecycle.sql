-- 0043: ciclo de la comisión aprobado por el dueño (Build 14, 23-10-2026):
-- "reservar, después cobrar".
--
--   1. Antes de aceptar: el profesional ve la comisión y la reserva
--      (commission_preview).
--   2. Al aceptar: se reserva la comisión COMPLETA esperada (porcentaje del
--      precio cotizado, o el cargo fijo), nunca menos que la reserva mínima
--      de la regla. Sin saldo suficiente no se acepta, como antes.
--   3. Al completar: se cobra de la reserva; la diferencia con el precio
--      final se cobra o se devuelve en el mismo movimiento.
--   4. Al cancelar: la reserva vuelve entera al saldo disponible.
--   5. Si al completar falta saldo, la diferencia queda anotada como comisión
--      pendiente (bookings.commission_shortfall), el profesional no acepta
--      trabajos nuevos hasta pagarla, y se descuenta sola de su próxima recarga
--      o ajuste a favor, con su propio movimiento en el libro.
--   6. "Comisión del mes" en el panel = lo mismo que Finanzas: movimientos de
--      cobro del libro, por fecha de cobro, en hora de La Paz.
--
-- Ya no se cobra al aceptar: las reglas con capture_at = 'accepted' pasan a
-- 'completed' y una restricción lo mantiene. Ningún saldo existente cambia:
-- solo los trabajos aceptados desde ahora siguen el ciclo nuevo; los que ya
-- tienen reserva se cobran al completar como antes.

alter table public.bookings
  add column commission_shortfall numeric(10,2) not null default 0 check (commission_shortfall >= 0);

update public.commission_rules set capture_at = 'completed' where capture_at = 'accepted';
alter table public.commission_rules
  add constraint commission_rules_capture_at_completion check (capture_at = 'completed');

-- La comisión esperada de un pedido con una regla: porcentaje del precio
-- (final, si no cotizado) o el cargo fijo.
create function public.hmy_commission_expected(b public.bookings, r public.commission_rules) returns numeric
language sql stable set search_path = public as $$
  select coalesce(
    case when r.rate_percent is not null and coalesce(b.final_amount, b.quote_amount) is not null
         then round(coalesce(b.final_amount, b.quote_amount) * r.rate_percent / 100, 2) end,
    r.fixed_fee,
    0)
$$;

-- Lo que se reserva al aceptar: la comisión esperada completa, y al menos la
-- reserva de la regla (cubre un porcentaje sin precio todavía).
create function public.hmy_commission_reserve_for(b public.bookings, r public.commission_rules) returns numeric
language sql stable set search_path = public as $$
  select greatest(public.hmy_commission_expected(b, r), r.reserve_amount)
$$;

create or replace function public._commission_reserve(b public.bookings) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.commission_rules;
  w public.wallets;
  v_reserve numeric(10,2);
begin
  r := public.commission_rule_for(b.category_id, b.city_id);
  if r.id is null then
    return; -- Sin regla configurada: no se cobra nada.
  end if;
  if exists (select 1 from public.bookings x where x.professional_id = b.professional_id
             and x.commission_shortfall > 0) then
    raise exception 'HMY_COMMISSION_DEBT';
  end if;
  select * into w from public.wallets where professional_id = b.professional_id;
  if not found then raise exception 'HMY_WALLET_NOT_FOUND'; end if;
  v_reserve := public.hmy_commission_reserve_for(b, r);
  if w.available < greatest(r.min_balance, v_reserve) then
    raise exception 'HMY_INSUFFICIENT_BALANCE';
  end if;
  if v_reserve > 0 then
    perform public.wallet_post(b.professional_id, 'commission_reserve', -v_reserve, v_reserve,
                               'reserve:' || b.id, b.id, null, 'Reserva de comisión ' || b.code);
  end if;
  update public.bookings set commission_rule_id = r.id, commission_reserved = v_reserve where id = b.id;
end $$;

create or replace function public._commission_capture(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  r public.commission_rules;
  w public.wallets;
  v_amount numeric(10,2);
  v_take numeric(10,2);
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
  -- Nunca deja el saldo en negativo: se cobra lo posible y el resto queda
  -- como comisión pendiente, a la vista del propietario.
  v_take := least(v_amount, b.commission_reserved + w.available);
  perform public.wallet_post(b.professional_id, 'commission_capture',
                             b.commission_reserved - v_take, -b.commission_reserved,
                             'capture:' || b.id, b.id, null,
                             'Comisión ' || b.code
                             || case when v_take < v_amount then ' (falta ' || (v_amount - v_take) || ' Bs)' else '' end);
  update public.bookings
  set commission_captured = v_take, commission_reserved = 0, commission_shortfall = v_amount - v_take
  where id = b.id;
end $$;

-- Cobra las comisiones pendientes de un profesional con su saldo disponible,
-- la más vieja primero. Cada cobro es un movimiento propio en el libro.
create function public._commission_collect_debts(p_professional uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  b record;
  v_available numeric(10,2);
  v_take numeric(10,2);
  v_n int;
begin
  for b in select id, code, commission_shortfall from public.bookings
           where professional_id = p_professional and commission_shortfall > 0
           order by completed_at nulls last, id
           for update loop
    select available into v_available from public.wallets where professional_id = p_professional;
    exit when coalesce(v_available, 0) <= 0;
    v_take := least(b.commission_shortfall, v_available);
    select count(*) into v_n from public.wallet_ledger where booking_id = b.id and idempotency_key like 'debt:%';
    perform public.wallet_post(p_professional, 'commission_capture', -v_take, 0,
                               'debt:' || b.id || ':' || (v_n + 1), b.id, null,
                               'Comisión pendiente ' || b.code);
    update public.bookings
    set commission_shortfall = commission_shortfall - v_take,
        commission_captured = coalesce(commission_captured, 0) + v_take
    where id = b.id;
  end loop;
end $$;

-- Una recarga acreditada o un ajuste a favor pagan primero lo pendiente.
create function public.hmy_ledger_collect_debts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.bookings where professional_id = new.professional_id and commission_shortfall > 0) then
    perform public._commission_collect_debts(new.professional_id);
  end if;
  return null;
end $$;

create trigger wallet_ledger_collect_debts after insert on public.wallet_ledger
  for each row when (new.entry_type in ('topup', 'adjustment') and new.available_delta > 0)
  execute function public.hmy_ledger_collect_debts();

-- El profesional ve la comisión antes de aceptar (pedido directo u oferta ¡Ya!).
create function public.commission_preview(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings;
  r public.commission_rules;
  v_me uuid := auth.uid();
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if v_me is null or not (b.professional_id = v_me
     or exists (select 1 from public.booking_offers o where o.booking_id = b.id and o.professional_id = v_me
                and o.status = 'pending')) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  r := public.commission_rule_for(b.category_id, b.city_id);
  return jsonb_build_object(
    'has_rule', r.id is not null,
    'rate_percent', r.rate_percent,
    'fixed_fee', r.fixed_fee,
    'expected', case when r.id is null then 0 else public.hmy_commission_expected(b, r) end,
    'reserve', case when r.id is null then 0 else public.hmy_commission_reserve_for(b, r) end,
    'min_balance', coalesce(r.min_balance, 0),
    'available', (select available from public.wallets where professional_id = v_me),
    'pending_debt', (select coalesce(sum(commission_shortfall), 0) from public.bookings
                     where professional_id = v_me and commission_shortfall > 0));
end $$;

-- Propietario: comisiones pendientes de cobro.
create function public.owner_commission_debts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return (
    select jsonb_build_object(
      'total', count(*), 'sum_bs', coalesce(sum(b.commission_shortfall), 0),
      'items', coalesce(jsonb_agg(jsonb_build_object(
        'booking_id', b.id, 'booking_code', b.code, 'professional_id', b.professional_id,
        'professional_name', coalesce(pp.display_name, p.full_name), 'amount', b.commission_shortfall,
        'captured', b.commission_captured, 'completed_at', b.completed_at)
        order by b.completed_at desc nulls last), '[]'::jsonb))
    from public.bookings b
    left join public.professional_profiles pp on pp.user_id = b.professional_id
    left join public.profiles p on p.id = b.professional_id
    where b.commission_shortfall > 0);
end $$;

-- Panel del propietario: la comisión del mes con la misma definición que
-- Finanzas (cobros del libro por fecha de cobro, hora de La Paz) y lo
-- pendiente de cobro. El resto del panel no cambia.
alter function public.owner_dashboard() rename to _owner_dashboard_0037;
revoke execute on function public._owner_dashboard_0037() from public, anon, authenticated;

create function public.owner_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_month timestamptz := date_trunc('month', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public._owner_dashboard_0037() || jsonb_build_object(
    'commission_month', (select coalesce(sum(-(available_delta + reserved_delta)), 0) from public.wallet_ledger
                         where entry_type = 'commission_capture' and created_at >= v_month),
    'commission_owed', (select coalesce(sum(commission_shortfall), 0) from public.bookings
                        where commission_shortfall > 0));
end $$;

revoke execute on function public.hmy_commission_expected(public.bookings, public.commission_rules) from public, anon, authenticated;
revoke execute on function public.hmy_commission_reserve_for(public.bookings, public.commission_rules) from public, anon, authenticated;
revoke execute on function public._commission_reserve(public.bookings) from public, anon, authenticated;
revoke execute on function public._commission_capture(uuid) from public, anon, authenticated;
revoke execute on function public._commission_collect_debts(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_ledger_collect_debts() from public, anon, authenticated;
revoke execute on function public.commission_preview(uuid) from public, anon;
revoke execute on function public.owner_commission_debts() from public, anon;
revoke execute on function public.owner_dashboard() from public, anon;
grant execute on function public.commission_preview(uuid) to authenticated;
grant execute on function public.owner_commission_debts() to authenticated;
grant execute on function public.owner_dashboard() to authenticated;
