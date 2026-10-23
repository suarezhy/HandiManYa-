-- Cada tarjeta de Finanzas y Bancos abre su lista (0042). Corre después de 99j
-- (usa test.grant de 99d). Cuentas propias (…9a2000…); ningún dato real cambia.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a20001', '59170099701', now(), '{"full_name": "Dueño Tarjetas"}'),
  ('00000000-0000-0000-0000-000009a20002', '59170099702', now(), '{"full_name": "Gerente Tarjetas"}'),
  ('00000000-0000-0000-0000-000009a20003', '59170099703', now(), '{"full_name": "Empleado Tarjetas"}'),
  ('00000000-0000-0000-0000-000009a20004', '59170099704', now(), '{"full_name": "Plomero Tarjetas"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a20001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status)
values ('00000000-0000-0000-0000-000009a20004', 'Plomero Tarjetas', 1, 1, 'approved');
select test.grant('00000000-0000-0000-0000-000009a20001', '00000000-0000-0000-0000-000009a20002', 'manager');
select test.grant('00000000-0000-0000-0000-000009a20001', '00000000-0000-0000-0000-000009a20003', 'employee');
select test.logout();

-- Recargas: acreditada sin verificar (50), acreditada conciliada (30), acreditada
-- no encontrada (20), por revisar (10). Y una comisión cobrada de 7.
insert into public.topup_requests (id, professional_id, amount, reference, status, reviewed_at, bank_status, bank_reference)
values (99000801, '00000000-0000-0000-0000-000009a20004', 50, 'TARJ-801', 'approved', now(), 'sin_verificar', null),
       (99000802, '00000000-0000-0000-0000-000009a20004', 30, 'TARJ-802', 'approved', now(), 'conciliada', 'BNB-TARJ'),
       (99000803, '00000000-0000-0000-0000-000009a20004', 20, 'TARJ-803', 'approved', now(), 'no_encontrada', null),
       (99000804, '00000000-0000-0000-0000-000009a20004', 10, 'TARJ-804', 'pending', null, 'sin_verificar', null);
select public.wallet_post('00000000-0000-0000-0000-000009a20004', 'topup', 50, 0, 'test99k:t1', null, 99000801, 'Recarga');
select public.wallet_post('00000000-0000-0000-0000-000009a20004', 'commission_reserve', -7, 7, 'test99k:r', null, null, 'Reserva');
select public.wallet_post('00000000-0000-0000-0000-000009a20004', 'commission_capture', 0, -7, 'test99k:c', null, null, 'Comisión');

-- ---------------------------------------------------------------------------
-- Solo el Propietario.
-- ---------------------------------------------------------------------------
do $$
declare
  u uuid;
begin
  foreach u in array array['00000000-0000-0000-0000-000009a20002', '00000000-0000-0000-0000-000009a20003',
                           '00000000-0000-0000-0000-000009a20004']::uuid[] loop
    perform test.login(u);
    perform test.expect_error('select public.owner_finance_ledger()', 'HMY_FORBIDDEN');
    perform test.expect_error($q$select public.owner_finance_topups('todas')$q$, 'HMY_FORBIDDEN');
    perform test.logout();
  end loop;
end $$;
select test.login(null);
select test.expect_error('select public.owner_finance_ledger()', 'permission denied');
select test.expect_error($$select public.owner_finance_topups('todas')$$, 'permission denied');
select test.logout();

-- ---------------------------------------------------------------------------
-- Cada tarjeta = su lista (mismo mes, mismas definiciones).
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a20001');
create temp table k_sum as select public.owner_finance_summary() as s,
  date_trunc('month', (now() at time zone 'America/La_Paz'))::date as m;
grant select on k_sum to authenticated;
create function pg_temp.led(k text) returns jsonb language sql as
  $$ select public.owner_finance_ledger(k, (select m from k_sum)) $$;
create function pg_temp.top(k text, all_months boolean default false) returns jsonb language sql as
  $$ select public.owner_finance_topups(k, case when all_months then null else (select m from k_sum) end) $$;

select test.eq((pg_temp.led('commission_capture') ->> 'sum_bs')::numeric, (select (s ->> 'commission_earned_bs')::numeric from k_sum),
               'tarjetas: Comisiones cobradas = suma de su lista');
select test.eq((pg_temp.led('commission_capture') ->> 'total')::int, (select (s ->> 'commissions_count')::int from k_sum),
               'tarjetas: Trabajos con comisión = filas de su lista');
select test.eq((pg_temp.led('refund') ->> 'sum_bs')::numeric, (select (s ->> 'commission_refunded_bs')::numeric from k_sum),
               'tarjetas: Devoluciones = suma de su lista');
select test.eq((pg_temp.led('adjustment') ->> 'sum_bs')::numeric, (select (s ->> 'manual_adjustments_bs')::numeric from k_sum),
               'tarjetas: Ajustes manuales = suma de su lista');
select test.eq((pg_temp.top('acreditadas') ->> 'sum_bs')::numeric, (select (s ->> 'wallet_funds_received_bs')::numeric from k_sum),
               'tarjetas: Recargas acreditadas = suma de su lista');
select test.eq((pg_temp.top('acreditadas') ->> 'total')::int, (select (s ->> 'wallet_funds_received_count')::int from k_sum),
               'tarjetas: Recargas acreditadas = filas de su lista');
select test.eq((pg_temp.top('conciliada') ->> 'sum_bs')::numeric, (select (s ->> 'wallet_funds_reconciled_bs')::numeric from k_sum),
               'tarjetas: Conciliadas con el banco = suma de su lista');
select test.eq((pg_temp.top('sin_verificar') ->> 'sum_bs')::numeric, (select (s ->> 'wallet_funds_unverified_bs')::numeric from k_sum),
               'tarjetas: Sin verificar en el banco = suma de su lista');
select test.eq((pg_temp.top('no_encontrada') ->> 'sum_bs')::numeric, (select (s ->> 'wallet_funds_not_found_bs')::numeric from k_sum),
               'tarjetas: No aparecen en el banco = suma de su lista');
select test.eq((pg_temp.top('pendiente', true) ->> 'total')::int, (select (s ->> 'topups_pending')::int from k_sum),
               'tarjetas: Recargas por revisar = filas de su lista');
select test.eq((pg_temp.top('sin_verificar', true) ->> 'total')::int, (select (s ->> 'topups_unverified_total')::int from k_sum),
               'tarjetas: Acreditadas sin conciliar (todos los meses) = filas de su lista');
select test.eq((pg_temp.top('sin_verificar', true) ->> 'sum_bs')::numeric,
               (select (s ->> 'topups_unverified_total_bs')::numeric from k_sum),
               'tarjetas: Acreditadas sin conciliar (todos los meses) = suma de su lista');

-- Filas con lo que hace falta: referencia, estado del banco, profesional.
select test.eq((select r ->> 'bank_reference' from jsonb_array_elements(pg_temp.top('conciliada') -> 'items') r
                where (r ->> 'id')::bigint = 99000802), 'BNB-TARJ', 'tarjetas: la conciliada trae la referencia del banco');
select test.eq((select r ->> 'professional_name' from jsonb_array_elements(pg_temp.top('no_encontrada') -> 'items') r
                where (r ->> 'id')::bigint = 99000803), 'Plomero Tarjetas', 'tarjetas: cada recarga dice de quién es');
-- Buscar por referencia y por nombre.
select test.eq((public.owner_finance_topups('todas', null, 'tarj-80') ->> 'total')::int, 4, 'tarjetas: busca por referencia');
select test.eq((public.owner_finance_ledger(null, null, 'plomero tarj') ->> 'total')::int, 3,
               'tarjetas: busca movimientos por nombre (recarga, reserva y comisión)');
-- Otro mes: vacío, no inventa nada.
select test.eq((public.owner_finance_topups('acreditadas', '2001-01-01') ->> 'total')::int, 0, 'tarjetas: otro mes viene vacío');
select test.eq((public.owner_finance_topups('acreditadas', '2001-01-01') ->> 'sum_bs')::numeric, 0::numeric,
               'tarjetas: otro mes suma 0');
select test.expect_error($$select public.owner_finance_topups('cualquiera')$$, 'HMY_INVALID_STATUS');
select test.expect_error($$select public.owner_finance_ledger('cualquiera')$$, 'HMY_INVALID_STATUS');
select test.logout();
