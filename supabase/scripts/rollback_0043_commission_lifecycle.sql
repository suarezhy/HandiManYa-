-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0043
-- (20261023004300_commission_lifecycle) en el proyecto de DESARROLLO.
--
-- Vuelve a las funciones de comisión de 0003 (reserva fija de la regla,
-- cobro al completar o al aceptar según la regla) y al panel de 0037.
-- Qué se pierde: la columna bookings.commission_shortfall (lo pendiente de
-- cobro). Si hay algo pendiente, el script se detiene: primero hay que
-- decidir qué hacer con eso. Las reglas que tenían "al aceptar" antes de
-- 0043 quedan "al completar" (no se guardó cuáles eran).
-- Lo que NO se deshace a propósito: los movimientos del libro (historial).
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0043_commission_lifecycle.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if to_regprocedure('public._owner_dashboard_0037()') is null then
    raise exception 'HMY: 0043 no está aplicada; no se revirtió nada.';
  end if;
  if exists (select 1 from public.bookings where commission_shortfall > 0) then
    raise exception 'HMY: hay comisiones pendientes de cobro; decide qué hacer con ellas antes de revertir.';
  end if;
end $$;

drop trigger wallet_ledger_collect_debts on public.wallet_ledger;
drop function public.hmy_ledger_collect_debts();
drop function public._commission_collect_debts(uuid);
drop function public.commission_preview(uuid);
drop function public.owner_commission_debts();
drop function public.owner_dashboard();
alter function public._owner_dashboard_0037() rename to owner_dashboard;
revoke execute on function public.owner_dashboard() from public, anon;
grant execute on function public.owner_dashboard() to authenticated;
alter table public.commission_rules drop constraint commission_rules_capture_at_completion;

-- Funciones de comisión como en 0003.
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

create or replace function public._commission_capture(p_booking uuid) returns void
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

create or replace function public._commission_release(p_booking uuid) returns void
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


drop function public.hmy_commission_reserve_for(public.bookings, public.commission_rules);
drop function public.hmy_commission_expected(public.bookings, public.commission_rules);
alter table public.bookings drop column commission_shortfall;
revoke execute on function public._commission_reserve(public.bookings) from public, anon, authenticated;
revoke execute on function public._commission_capture(uuid) from public, anon, authenticated;
revoke execute on function public._commission_release(uuid) from public, anon, authenticated;
delete from supabase_migrations.schema_migrations where version = '20261023004300';

commit;
