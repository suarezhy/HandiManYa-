-- 0065: recargas por QR. Solo se acredita con el aviso verificado del
-- proveedor (aquí, el simulado de desarrollo), una sola vez, con monto y
-- moneda revisados. Cuentas propias (…9aa0…). Usa test.otp de 99d.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table za_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');
create temp table za_setting as select * from public.app_settings where key = 'qr_recharge_provider';
delete from public.app_settings where key = 'qr_recharge_provider';

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009aa0001', 'zqr-01@test.bo', '{"full_name": "Dueño QR"}'),
  ('00000000-0000-0000-0000-000009aa0002', 'zqr-02@test.bo', '{"full_name": "Profesional QR"}'),
  ('00000000-0000-0000-0000-000009aa0003', 'zqr-03@test.bo', '{"full_name": "Otro Profesional QR"}'),
  ('00000000-0000-0000-0000-000009aa0004', 'zqr-04@test.bo', '{"full_name": "Cliente QR"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009aa0001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available, test_fixture)
values ('00000000-0000-0000-0000-000009aa0002', 'Profesional QR', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true, true),
       ('00000000-0000-0000-0000-000009aa0003', 'Otro Profesional QR', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true, false);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009aa0002'), ('00000000-0000-0000-0000-000009aa0003')
  on conflict do nothing;

create temp table tqr (k text primary key, v text);
grant all on tqr to authenticated;
create function pg_temp.qr_wallet() returns text language sql as $$
  select available || '/' || reserved from public.wallets where professional_id = '00000000-0000-0000-0000-000009aa0002'
$$;
create function pg_temp.qr(k text) returns uuid language sql as $$ select v::uuid from tqr where tqr.k = $1 $$;
grant execute on function pg_temp.qr(text) to authenticated;

-- Sin proveedor configurado no hay QR (como hoy en producción).
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.expect_error($$select public.create_qr_recharge(50)$$, 'HMY_QR_UNAVAILABLE');
select test.logout();

insert into public.app_settings (key, value) values ('qr_recharge_provider', '{"provider": "dev_mock"}');

-- El QR simulado es solo para perfiles de prueba.
select test.login('00000000-0000-0000-0000-000009aa0003');
select test.expect_error($$select public.create_qr_recharge(50)$$, 'HMY_QR_UNAVAILABLE');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa0004');
select test.expect_error($$select public.create_qr_recharge(50)$$, 'HMY_WALLET_NOT_FOUND');
select test.eq(public.recharge_bank_accounts(), '[]'::jsonb, 'un cliente no ve cuentas de cobro');
select test.logout();

select test.login('00000000-0000-0000-0000-000009aa0002');
select test.expect_error($$select public.create_qr_recharge(5)$$, 'HMY_INVALID_AMOUNT');
select test.expect_error($$select public.create_qr_recharge(6000)$$, 'HMY_INVALID_AMOUNT');
insert into tqr select 'ok', public.create_qr_recharge(50) ->> 'id';
select test.eq((select (s ->> 'status') || '/' || (s ->> 'simulated') || '/' || (s ->> 'amount') || '/' || (s ->> 'currency')
                from (select public.qr_recharge_status(pg_temp.qr('ok')) s) x), 'pending_payment/true/50.00/BOB',
               'QR simulado: pendiente de pago, Bs 50');
select test.eq((public.qr_recharge_status(pg_temp.qr('ok')) ->> 'qr_payload') like '%SIMULADO-NO-PAGAR%', true,
               'el QR dice que es simulado y no se paga');
select test.eq((select (s ->> 'expires_at')::timestamptz - (s ->> 'created_at')::timestamptz
                from (select public.qr_recharge_status(pg_temp.qr('ok')) s) x), interval '15 minutes', 'vence en 15 minutos');
select test.eq((select (public.qr_recharge_status(pg_temp.qr('ok')) ->> 'reference') ~ '^HMY[0-9A-F]{10}$'), true,
               'referencia única HMY…');
-- Decir que pagó no acredita nada: no hay función para eso.
select test.eq(pg_temp.qr_wallet(), '0.00/0.00', 'pendiente: nada acreditado');
select test.expect_error($$select public.hmy_qr_settle('dev_mock', 'x', 'e', 50, 'BOB', now())$$, 'permission denied');
select test.expect_error($$select * from public.qr_recharges$$, 'permission denied');
select test.expect_error($$update public.qr_recharges set status = 'credited'$$, 'permission denied');
select test.expect_error($$insert into public.qr_recharge_events (provider, event_id) values ('dev_mock', 'x')$$, 'permission denied');
select test.logout();

-- Otro profesional no ve ni simula la recarga ajena.
select test.login('00000000-0000-0000-0000-000009aa0003');
select test.eq(public.qr_recharge_status(pg_temp.qr('ok')), null::jsonb, 'otro no ve la recarga');
select test.expect_error($$select public.dev_simulate_qr_payment(pg_temp.qr('ok'))$$, 'HMY_FORBIDDEN');
select test.eq(public.my_qr_recharges(), '[]'::jsonb, 'su lista está vacía');
select test.logout();

-- Pago correcto: se acredita una vez, con historial y aviso.
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('ok')), 'credited', 'pago simulado: acreditada');
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('ok')), 'duplicate_event', 'el mismo aviso otra vez: nada');
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('ok'), p_event_id => 'mock:otro'), 'already_credited',
               'otro aviso del mismo pago: ya acreditada');
select test.eq((public.qr_recharge_status(pg_temp.qr('ok')) ->> 'status'), 'credited', 'estado Acreditada');
select test.eq((public.qr_recharge_status(pg_temp.qr('ok')) ->> 'qr_payload'), null, 'acreditada ya no muestra el QR');
select test.logout();
select test.eq(pg_temp.qr_wallet(), '50.00/0.00', 'Bs 50 una sola vez');
select test.eq((select count(*)::int || '/' || min(note) from public.wallet_ledger where idempotency_key = 'qr:' || pg_temp.qr('ok')),
               '1/Recarga simulada (no es dinero real) ' || (select reference from public.qr_recharges where id = pg_temp.qr('ok')),
               'una entrada, marcada como simulada');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009aa0002'
                and kind = 'wallet_credited'), 1, 'un aviso de recarga acreditada');
select test.eq(public.hmy_push_text('wallet_credited'), 'Tu saldo ya está disponible.', 'push sin el monto');
select test.eq((select count(*)::int from public.qr_recharge_events where recharge_id = pg_temp.qr('ok')), 2,
               'los dos avisos con resultado quedan para conciliar (el repetido no se guarda dos veces)');

-- Con el saldo recargado ya puede acordar un precio (reserva la comisión).
select test.login('00000000-0000-0000-0000-000009aa0004');
insert into tqr select 'job', public.create_booking('00000000-0000-0000-0000-000009aa0002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Destapar el lavaplatos', 'Calle Tupiza 5');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.agree(pg_temp.qr('job'), 120);
select test.logout();
select test.eq(pg_temp.qr_wallet(), '38.00/12.00', 'después de recargar: reserva Bs 12 del precio Bs 120');

-- Monto distinto: no se acredita, queda en verificación.
select test.login('00000000-0000-0000-0000-000009aa0002');
insert into tqr select 'monto', public.create_qr_recharge(100) ->> 'id';
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('monto'), 90), 'verifying_wrong_amount', 'pagó Bs 90 de Bs 100');
-- Moneda distinta.
insert into tqr select 'moneda', public.create_qr_recharge(20) ->> 'id';
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('moneda'), 20, 'USD'), 'verifying_wrong_currency', 'pagó en dólares');
select test.eq((public.qr_recharge_status(pg_temp.qr('moneda')) ->> 'status'), 'verifying', 'Pago en verificación');
select test.logout();
select test.eq(pg_temp.qr_wallet(), '38.00/12.00', 'nada acreditado sin revisar');

-- Vencida: sin pago se ve vencida; un pago tarde va a verificación.
select test.login('00000000-0000-0000-0000-000009aa0002');
insert into tqr select 'vieja', public.create_qr_recharge(30) ->> 'id';
select test.logout();
update public.qr_recharges set created_at = now() - interval '1 hour', expires_at = now() - interval '40 minutes'
where id = pg_temp.qr('vieja');
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.eq((public.qr_recharge_status(pg_temp.qr('vieja')) ->> 'status'), 'expired', 'pasada la hora: Vencida');
select test.eq((public.qr_recharge_status(pg_temp.qr('vieja')) ->> 'qr_payload'), null, 'vencida no muestra el QR');
-- Tres pendientes como máximo (las vencidas no cuentan).
insert into tqr select 'p1', public.create_qr_recharge(10) ->> 'id';
insert into tqr select 'p2', public.create_qr_recharge(10) ->> 'id';
insert into tqr select 'p3', public.create_qr_recharge(10) ->> 'id';
select test.expect_error($$select public.create_qr_recharge(10)$$, 'HMY_TOO_MANY_QR');
select test.eq(public.dev_simulate_qr_payment(pg_temp.qr('vieja')), 'verifying_paid_after_expiry', 'pago después de vencer');
select test.logout();
select test.eq((select status from public.qr_recharges where id = pg_temp.qr('vieja')), 'verifying', 'la vencida pagada se revisa');
select test.eq(public.expire_qr_recharges(), 0, 'nada más que vencer');

-- Aviso de una referencia que no existe: se guarda para conciliar.
select test.eq(public.hmy_qr_settle('dev_mock', 'MOCK-no-existe', 'evt-x', 10, 'BOB', now()), 'unknown_reference',
               'referencia desconocida');
select test.eq(public.hmy_qr_settle('dev_mock', 'MOCK-no-existe', 'evt-x', 10, 'BOB', now()), 'duplicate_event',
               'reintento del mismo aviso (red cortada)');

-- Propietario: revisa con código nuevo y motivo; nadie más.
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.expect_error($$select public.owner_qr_recharges()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_review_qr_recharge(pg_temp.qr('monto'), true, 'x', 'otp')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_reverse_qr_recharge(pg_temp.qr('ok'), 'x', 'otp')$$, 'HMY_FORBIDDEN');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa0001');
select test.eq((public.owner_qr_recharges() -> 'summary' -> 'verifying' ->> 'count')::int, 3, 'conciliación: 3 en verificación');
select test.eq((public.owner_qr_recharges() ->> 'unmatched_events')::int, 1, 'conciliación: 1 aviso sin recarga');
select test.eq((select count(*)::int from jsonb_array_elements(public.owner_qr_recharges('verifying') -> 'items')), 3,
               'lista de pendientes de revisar');
select test.expect_error($$select public.owner_review_qr_recharge(pg_temp.qr('monto'), true, '', 'otp')$$, 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.owner_review_qr_recharge(pg_temp.qr('monto'), true, 'Banco confirma Bs 90', null)$$,
                         'HMY_CONFIRMATION_REQUIRED');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.eq((public.owner_review_qr_recharge(pg_temp.qr('monto'), true, 'Banco confirma Bs 90', 'otp') ->> 'credited_amount')::numeric,
               90.00::numeric, 'aprobar acredita lo que se pagó: Bs 90');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.expect_error($$select public.owner_review_qr_recharge(pg_temp.qr('monto'), true, 'otra vez', 'otp')$$,
                         'HMY_ALREADY_REVIEWED');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.expect_error($$select public.owner_review_qr_recharge(pg_temp.qr('moneda'), true, 'Pagó en dólares', 'otp')$$,
                         'HMY_WRONG_CURRENCY');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.eq((public.owner_review_qr_recharge(pg_temp.qr('moneda'), false, 'Pagó en dólares: se devuelve por el banco', 'otp')
                ->> 'status'), 'rejected', 'rechazar no acredita');
select test.logout();
select test.eq(pg_temp.qr_wallet(), '128.00/12.00', 'solo se sumaron los Bs 90 aprobados');
select test.eq((select count(*)::int from public.admin_audit_log where action in ('wallet.qr_approve', 'wallet.qr_reject')
                and target_id in (pg_temp.qr('monto')::text, pg_temp.qr('moneda')::text)), 2, 'cada revisión queda auditada');

-- Revertir: sin saldo suficiente no se hace (nunca negativo); con saldo, sí, una vez.
select test.login('00000000-0000-0000-0000-000009aa0001');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.expect_error($$select public.owner_reverse_qr_recharge(pg_temp.qr('moneda'), 'x', 'otp')$$, 'HMY_INVALID_STATUS');
select test.logout();
-- Bs 60 disponibles: alcanza para revertir la de Bs 50, no la de Bs 90.
update public.wallets set available = 60 where professional_id = '00000000-0000-0000-0000-000009aa0002';
select test.login('00000000-0000-0000-0000-000009aa0001');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.expect_error($$select public.owner_reverse_qr_recharge(pg_temp.qr('monto'), 'El banco anuló el pago', 'otp')$$,
                         'HMY_INSUFFICIENT_BALANCE');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.eq((public.owner_reverse_qr_recharge(pg_temp.qr('ok'), 'El banco anuló el pago', 'otp') ->> 'status'), 'reversed',
               'revertida');
select test.otp('00000000-0000-0000-0000-000009aa0001');
select test.expect_error($$select public.owner_reverse_qr_recharge(pg_temp.qr('ok'), 'otra vez', 'otp')$$, 'HMY_INVALID_STATUS');
select test.logout();
select test.eq(pg_temp.qr_wallet(), '10.00/12.00', 'se descontaron los Bs 50 una vez; la reserva no se toca');
select test.eq((select count(*)::int from public.wallet_ledger where idempotency_key = 'qr-reverse:' || pg_temp.qr('ok')), 1,
               'la reversión queda en el historial');

select test.eq((select count(*)::int from public.wallets where available < 0 or reserved < 0), 0, 'ningún saldo negativo');

-- Cuentas oficiales para transferir: solo las activas y verificadas.
insert into public.receiving_accounts (label, account_type, bank_name, holder_name, account_number, verification, created_by)
values ('Cuenta prueba A', 'caja_ahorro', 'Banco Prueba', 'Empresa Prueba', '1000001', 'verificada', '00000000-0000-0000-0000-000009aa0001'),
       ('Cuenta prueba B', 'caja_ahorro', 'Banco Prueba', 'Empresa Prueba', '1000002', 'sin_verificar', '00000000-0000-0000-0000-000009aa0001');
select test.login('00000000-0000-0000-0000-000009aa0002');
select test.eq((select count(*)::int from jsonb_array_elements(public.recharge_bank_accounts()) a
                where a ->> 'label' like 'Cuenta prueba %'), 1, 'el profesional ve solo la cuenta verificada');
select test.logout();

select test.login(null);
select test.expect_error($$select public.create_qr_recharge(50)$$, 'permission denied');
select test.expect_error($$select public.my_qr_recharges()$$, 'permission denied');
select test.logout();

delete from public.app_settings where key = 'qr_recharge_provider';
insert into public.app_settings select * from za_setting;
update public.commission_rules r set is_active = z.is_active from za_rules z where z.id = r.id;

\o
\echo '0065 recargas por QR: pruebas pasadas'
