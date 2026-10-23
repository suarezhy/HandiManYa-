-- Finanzas y Bancos (0038). Corre después de 99f (usa test.otp y test.grant de 99d).
-- Cuentas de prueba propias (…99g0…); ningún dato real cambia.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a10001', '59170099401', now(), '{"full_name": "Dueño Finanzas"}'),
  ('00000000-0000-0000-0000-000009a10002', '59170099402', now(), '{"full_name": "Gerente Finanzas"}'),
  ('00000000-0000-0000-0000-000009a10003', '59170099403', now(), '{"full_name": "Empleado Finanzas"}'),
  ('00000000-0000-0000-0000-000009a10004', '59170099404', now(), '{"full_name": "Profesional Finanzas"}'),
  ('00000000-0000-0000-0000-000009a10005', '59170099405', now(), '{"full_name": "Cliente Finanzas"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a10001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status)
values ('00000000-0000-0000-0000-000009a10004', 'Profesional Finanzas', 1, 1, 'approved');
select test.grant('00000000-0000-0000-0000-000009a10001', '00000000-0000-0000-0000-000009a10002', 'manager');
select test.grant('00000000-0000-0000-0000-000009a10001', '00000000-0000-0000-0000-000009a10003', 'employee');
select test.logout();

-- ---------------------------------------------------------------------------
-- Nadie más que el Propietario: ni gerente, ni empleado, ni profesional, ni cliente.
-- ---------------------------------------------------------------------------
do $$
declare
  u uuid;
  q text;
begin
  foreach u in array array['00000000-0000-0000-0000-000009a10002', '00000000-0000-0000-0000-000009a10003',
                           '00000000-0000-0000-0000-000009a10004', '00000000-0000-0000-0000-000009a10005']::uuid[] loop
    perform test.login(u);
    foreach q in array array[
      'select public.owner_finance_summary()',
      'select * from public.owner_finance_transactions()',
      $q$select * from public.owner_topups_reconciliation('todas')$q$,
      'select * from public.owner_receiving_accounts()',
      'select * from public.owner_finance_audit()',
      $q$select public.owner_save_receiving_account(null, 'Cuenta', 'caja_ahorro', 'Banco', 'Titular', '1234567', 'BOB', null, null, 'password')$q$,
      $q$select public.owner_reconcile_topup(1, 'conciliada', 'X', null, 'password')$q$,
      $q$select public.owner_set_receiving_account(1, false, 'sin_verificar', 'password')$q$] loop
      perform test.expect_error(q, 'HMY_FORBIDDEN');
    end loop;
    -- Ni leyendo la tabla directo.
    perform test.expect_error('select * from public.receiving_accounts', 'permission denied');
    perform test.logout();
  end loop;
end $$;
select test.login(null);
select test.expect_error('select public.owner_finance_summary()', 'permission denied');
select test.logout();

-- ---------------------------------------------------------------------------
-- Cuentas de cobro: con código nuevo, auditadas, sin el número completo en la auditoría.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a10001');
select test.expect_error($$select public.owner_save_receiving_account(null, 'BNB principal', 'caja_ahorro', 'Banco Nacional de Bolivia',
  'HandiMan Ya SRL', '1000123456', 'BOB', null, null, null)$$, 'HMY_CONFIRMATION_REQUIRED');
select test.expect_error($$select public.owner_save_receiving_account(null, 'BNB principal', 'caja_ahorro', 'Banco Nacional de Bolivia',
  'HandiMan Ya SRL', '1000123456', 'BOB', null, null, 'biometric')$$, 'HMY_CONFIRMATION_REQUIRED');
-- Un QR de otra carpeta no se acepta.
select test.otp('00000000-0000-0000-0000-000009a10001');
select test.expect_error($$select public.owner_save_receiving_account(null, 'QR', 'qr', 'Banco', 'Titular', null, 'BOB',
  '00000000-0000-0000-0000-000009a10004/qr.png', null, 'otp')$$, 'HMY_FORBIDDEN');
select test.otp('00000000-0000-0000-0000-000009a10001');
create temp table t_acc as select public.owner_save_receiving_account(null, 'BNB principal', 'caja_ahorro',
  'Banco Nacional de Bolivia', 'HandiMan Ya SRL', '1000123456', 'BOB', null, null, 'otp') as id;
grant select on t_acc to authenticated;
-- Una confirmación sirve para una sola operación.
select test.expect_error($$select public.owner_set_receiving_account((select id from t_acc), true, 'verificada', 'otp')$$,
                         'HMY_CONFIRMATION_USED');
select test.otp('00000000-0000-0000-0000-000009a10001');
select public.owner_set_receiving_account((select id from t_acc), true, 'verificada', 'otp');
select test.eq((select verification from public.owner_receiving_accounts() where id = (select id from t_acc)), 'verificada',
               'cuentas: el propietario la marca verificada');
select test.eq((select account_masked from public.owner_receiving_accounts() where id = (select id from t_acc)), '•••• 3456',
               'cuentas: el número se muestra enmascarado');
-- Cambiar el número vuelve la cuenta a "sin verificar".
select test.otp('00000000-0000-0000-0000-000009a10001');
select public.owner_save_receiving_account((select id from t_acc), 'BNB principal', 'caja_ahorro', 'Banco Nacional de Bolivia',
  'HandiMan Ya SRL', '1000999888', 'BOB', null, null, 'otp');
select test.eq((select verification from public.owner_receiving_accounts() where id = (select id from t_acc)), 'sin_verificar',
               'cuentas: cambiar el número pide volver a verificarla');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log where target_table = 'receiving_accounts'
                and target_id = (select id::text from t_acc)), 3, 'cuentas: crear, verificar y cambiar quedan auditados');
select test.eq((select count(*)::int from public.admin_audit_log where target_table = 'receiving_accounts'
                and target_id = (select id::text from t_acc) and details::text like '%1000%'), 0,
               'cuentas: la auditoría no guarda el número completo');

-- ---------------------------------------------------------------------------
-- Billeteras vs. ingresos, con datos de prueba conocidos.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a10001');
create temp table f0 as select public.owner_finance_summary() as s;
select test.logout();
-- Una recarga acreditada de Bs 100 (comprobante subido, sin verificar en el banco)
-- y una pendiente de Bs 40.
insert into public.topup_requests (id, professional_id, amount, reference, status, reviewed_at)
values (99000701, '00000000-0000-0000-0000-000009a10004', 100, 'Comprobante 701', 'approved', now()),
       (99000702, '00000000-0000-0000-0000-000009a10004', 40, 'Comprobante 702', 'pending', null);
select public.wallet_post('00000000-0000-0000-0000-000009a10004', 'topup', 100, 0, 'test99g:topup', null, 99000701, 'Recarga');
-- Un trabajo reserva Bs 15 de comisión y cobra Bs 12.
select public.wallet_post('00000000-0000-0000-0000-000009a10004', 'commission_reserve', -15, 15, 'test99g:reserve', null, null, 'Reserva');
select public.wallet_post('00000000-0000-0000-0000-000009a10004', 'commission_capture', 3, -15, 'test99g:capture', null, null, 'Comisión');
select test.login('00000000-0000-0000-0000-000009a10001');
create temp table f1 as select public.owner_finance_summary() as s;
select test.eq((select (f1.s ->> 'commission_earned_bs')::numeric - (f0.s ->> 'commission_earned_bs')::numeric from f0, f1), 12::numeric,
               'finanzas: el ingreso es solo la comisión cobrada (12), no la recarga');
select test.eq((select (f1.s ->> 'wallet_funds_received_bs')::numeric - (f0.s ->> 'wallet_funds_received_bs')::numeric from f0, f1),
               100::numeric, 'finanzas: la recarga cuenta como fondos de billetera');
select test.eq((select (f1.s ->> 'wallet_funds_unverified_bs')::numeric - (f0.s ->> 'wallet_funds_unverified_bs')::numeric from f0, f1),
               100::numeric, 'finanzas: un comprobante no prueba que llegó al banco: sin verificar');
select test.eq((select (f1.s ->> 'topups_pending_bs')::numeric - (f0.s ->> 'topups_pending_bs')::numeric from f0, f1),
               40::numeric, 'finanzas: la recarga pendiente no suma a nada acreditado');
select test.eq((select (f1.s ->> 'wallets_available_bs')::numeric - (f0.s ->> 'wallets_available_bs')::numeric from f0, f1),
               88::numeric, 'finanzas: saldo del profesional = 100 - 12 de comisión');
select test.eq((select f1.s ->> 'bank_integration' from f1), 'pendiente_configuracion',
               'finanzas: sin banco conectado, se dice');
select test.eq((select jsonb_array_length(f1.s -> 'months') from f1), 6, 'finanzas: seis meses de historia');

-- Movimientos con referencia y estado bancario.
select test.eq((select topup_bank_status from public.owner_finance_transactions('topup') where topup_id = 99000701),
               'sin_verificar', 'movimientos: la recarga muestra su estado bancario');
select test.eq((select count(*)::int from public.owner_finance_transactions() where professional_id = '00000000-0000-0000-0000-000009a10004'),
               3, 'movimientos: recarga, reserva y cobro');

-- Conciliar: solo recargas acreditadas, con referencia del banco y código nuevo.
select test.otp('00000000-0000-0000-0000-000009a10001');
select test.expect_error($$select public.owner_reconcile_topup(99000702, 'conciliada', 'BNB-1', null, 'otp')$$,
                         'HMY_TOPUP_NOT_CREDITED');
select test.otp('00000000-0000-0000-0000-000009a10001');
select test.expect_error($$select public.owner_reconcile_topup(99000701, 'conciliada', '  ', null, 'otp')$$,
                         'HMY_BANK_REFERENCE_REQUIRED');
select test.expect_error($$select public.owner_reconcile_topup(99000701, 'conciliada', 'BNB-1', null, null)$$,
                         'HMY_CONFIRMATION_REQUIRED');
select test.otp('00000000-0000-0000-0000-000009a10001');
select public.owner_reconcile_topup(99000701, 'conciliada', 'BNB-778812', (select id from t_acc), 'otp');
create temp table f2 as select public.owner_finance_summary() as s;
select test.eq((select (f2.s ->> 'wallet_funds_reconciled_bs')::numeric - (f1.s ->> 'wallet_funds_reconciled_bs')::numeric from f1, f2),
               100::numeric, 'conciliación: pasa a conciliada');
select test.eq((select bank_reference from public.owner_topups_reconciliation('conciliada') where id = 99000701), 'BNB-778812',
               'conciliación: guarda la referencia del banco');
select test.eq((select count(*)::int from public.owner_finance_audit() where action = 'finance.reconcile' and target_id = '99000701'),
               1, 'conciliación: queda en la auditoría de finanzas');
select test.logout();
-- El profesional ve su recarga, pero no puede cambiar su estado bancario.
select test.login('00000000-0000-0000-0000-000009a10004');
select test.expect_error($$update public.topup_requests set bank_status = 'conciliada' where id = 99000702$$, 'permission denied');
select test.logout();
