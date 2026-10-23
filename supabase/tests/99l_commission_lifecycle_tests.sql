-- Ciclo de la comisión (0043): reservar completa al aceptar, cobrar al
-- completar, liberar al cancelar, y la falta queda anotada y se cobra de la
-- próxima recarga. Cuentas propias (…9a3000…); ningún dato real cambia.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a30001', '59170098301', now(), '{"full_name": "Dueño Comisión"}'),
  ('00000000-0000-0000-0000-000009a30002', '59170098302', now(), '{"full_name": "Gerente Comisión"}'),
  ('00000000-0000-0000-0000-000009a30004', '59170098304', now(), '{"full_name": "Electricista Comisión"}'),
  ('00000000-0000-0000-0000-000009a30005', '59170098305', now(), '{"full_name": "Otro Profesional"}'),
  ('00000000-0000-0000-0000-000009a30006', '59170098306', now(), '{"full_name": "Cliente Comisión"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a30001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status) values
  ('00000000-0000-0000-0000-000009a30004', 'Electricista Comisión', 3, 2, 'approved'),
  ('00000000-0000-0000-0000-000009a30005', 'Otro Profesional', 3, 2, 'approved');
select test.grant('00000000-0000-0000-0000-000009a30001', '00000000-0000-0000-0000-000009a30002', 'manager');
select test.logout();

-- Regla de prueba: 10 % del precio, reserva mínima 5, saldo mínimo 5.
insert into public.commission_rules (id, name, category_id, city_id, rate_percent, reserve_amount, min_balance)
values (99000901, 'Prueba 99l', 3, 2, 10, 5, 5);
select public.wallet_post('00000000-0000-0000-0000-000009a30004', 'topup', 30, 0, 'test99l:t1', null, null, 'Recarga');

insert into public.bookings (id, code, customer_id, professional_id, category_id, city_id, mode, description,
                             status, quote_amount)
values ('00000000-0000-0000-0000-000009a3b001', 'COM99L01', '00000000-0000-0000-0000-000009a30006',
        '00000000-0000-0000-0000-000009a30004', 3, 2, 'now', 'Cambiar el tablero eléctrico', 'requested', 200),
       ('00000000-0000-0000-0000-000009a3b002', 'COM99L02', '00000000-0000-0000-0000-000009a30006',
        '00000000-0000-0000-0000-000009a30004', 3, 2, 'now', 'Revisar un enchufe quemado', 'requested', null),
       ('00000000-0000-0000-0000-000009a3b003', 'COM99L03', '00000000-0000-0000-0000-000009a30006',
        '00000000-0000-0000-0000-000009a30004', 3, 2, 'now', 'Instalar luces del patio', 'requested', 100);

-- ---------------------------------------------------------------------------
-- Antes de aceptar: solo el profesional del pedido ve la comisión.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a30004');
select test.eq((public.commission_preview('00000000-0000-0000-0000-000009a3b001') ->> 'expected')::numeric, 20.00::numeric,
               'antes de aceptar: 10 % de Bs 200 = Bs 20');
select test.eq((public.commission_preview('00000000-0000-0000-0000-000009a3b001') ->> 'reserve')::numeric, 20.00::numeric,
               'antes de aceptar: se reservará la comisión completa');
select test.eq((public.commission_preview('00000000-0000-0000-0000-000009a3b002') ->> 'reserve')::numeric, 5.00::numeric,
               'sin precio todavía: se reserva la reserva mínima de la regla');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a30005');
select test.expect_error($$select public.commission_preview('00000000-0000-0000-0000-000009a3b001')$$, 'HMY_FORBIDDEN');
select test.logout();
select test.login(null);
select test.expect_error($$select public.commission_preview('00000000-0000-0000-0000-000009a3b001')$$, 'permission denied');
select test.logout();

-- ---------------------------------------------------------------------------
-- Aceptar reserva la comisión completa; cancelar la devuelve entera.
-- ---------------------------------------------------------------------------
select public._commission_reserve(b) from public.bookings b where id = '00000000-0000-0000-0000-000009a3b001';
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               10.00::numeric, 'aceptar: Bs 30 − 20 reservados');
select test.eq((select reserved from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               20.00::numeric, 'aceptar: Bs 20 reservados');
select test.eq((select commission_captured from public.bookings where id = '00000000-0000-0000-0000-000009a3b001') is null,
               true, 'aceptar no cobra');

select public._commission_reserve(b) from public.bookings b where id = '00000000-0000-0000-0000-000009a3b002';
select public._commission_release('00000000-0000-0000-0000-000009a3b002');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               10.00::numeric, 'cancelar devuelve la reserva entera');
select test.eq((select count(*)::int from public.wallet_ledger where booking_id = '00000000-0000-0000-0000-000009a3b002'
                and entry_type in ('commission_capture')), 0, 'cancelar no cobra');

-- ---------------------------------------------------------------------------
-- Completar con un precio final mayor: se cobra lo posible y falta el resto.
-- Precio final 400 → comisión 40; hay 20 reservados + 10 disponibles = 30.
-- ---------------------------------------------------------------------------
update public.bookings set final_amount = 400, status = 'completed', completed_at = now()
where id = '00000000-0000-0000-0000-000009a3b001';
select public._commission_capture('00000000-0000-0000-0000-000009a3b001');
select test.eq((select commission_captured from public.bookings where id = '00000000-0000-0000-0000-000009a3b001'),
               30.00::numeric, 'completar: se cobra lo que hay (Bs 30)');
select test.eq((select commission_shortfall from public.bookings where id = '00000000-0000-0000-0000-000009a3b001'),
               10.00::numeric, 'completar: la falta (Bs 10) queda anotada, no se pierde');
select test.eq((select available + reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a30004'), 0.00::numeric,
               'el saldo nunca queda en negativo');

-- Con comisión pendiente no acepta trabajos nuevos.
select public.wallet_post('00000000-0000-0000-0000-000009a30004', 'adjustment', 0.01, 0, 'test99l:a0', null, null, 'Centavo');
select test.expect_error($$select public._commission_reserve(b) from public.bookings b
                           where id = '00000000-0000-0000-0000-000009a3b003'$$, 'HMY_COMMISSION_DEBT');

-- La próxima recarga paga primero lo pendiente, con su propio movimiento.
select public.wallet_post('00000000-0000-0000-0000-000009a30004', 'topup', 50, 0, 'test99l:t2', null, null, 'Recarga');
select test.eq((select commission_shortfall from public.bookings where id = '00000000-0000-0000-0000-000009a3b001'),
               0.00::numeric, 'la recarga paga la comisión pendiente');
select test.eq((select commission_captured from public.bookings where id = '00000000-0000-0000-0000-000009a3b001'),
               40.00::numeric, 'cobrado en total: Bs 40 (10 % de 400)');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               40.01::numeric, 'quedan Bs 40,01: el ajuste de 0,01 y luego 9,99 de la recarga pagaron lo pendiente');
select test.eq((select count(*)::int from public.wallet_ledger
                where booking_id = '00000000-0000-0000-0000-000009a3b001' and entry_type = 'commission_capture'),
               3, 'cobro al completar + dos cobros de lo pendiente (ajuste y recarga), cada uno en el libro');
select test.eq((select sum(-(available_delta + reserved_delta)) from public.wallet_ledger
                where booking_id = '00000000-0000-0000-0000-000009a3b001' and entry_type = 'commission_capture'),
               40.00::numeric, 'el libro suma exactamente la comisión');
-- Ya sin deuda, acepta de nuevo.
select public._commission_reserve(b) from public.bookings b where id = '00000000-0000-0000-0000-000009a3b003';
select test.eq((select commission_reserved from public.bookings where id = '00000000-0000-0000-0000-000009a3b003'),
               10.00::numeric, 'sin deuda vuelve a aceptar (reserva Bs 10)');

-- Precio final menor: se devuelve la diferencia de la reserva.
update public.bookings set final_amount = 60, status = 'completed', completed_at = now()
where id = '00000000-0000-0000-0000-000009a3b003';
select public._commission_capture('00000000-0000-0000-0000-000009a3b003');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               34.01::numeric, 'precio final 60: se cobran Bs 6 y vuelven Bs 4 de la reserva');

-- ---------------------------------------------------------------------------
-- Ya no se cobra al aceptar.
-- ---------------------------------------------------------------------------
select test.eq((select count(*)::int from public.commission_rules where capture_at = 'accepted'), 0,
               'ninguna regla cobra al aceptar');
select test.expect_error($$update public.commission_rules set capture_at = 'accepted' where id = 99000901$$,
                         'commission_rules_capture_at_completion');

-- ---------------------------------------------------------------------------
-- Propietario: pendientes y la comisión del mes con la definición de Finanzas.
-- ---------------------------------------------------------------------------
update public.bookings set commission_shortfall = 7 where id = '00000000-0000-0000-0000-000009a3b002';
select test.login('00000000-0000-0000-0000-000009a30002');
select test.expect_error('select public.owner_commission_debts()', 'HMY_FORBIDDEN');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a30001');
select test.eq((public.owner_commission_debts() -> 'items' -> 0 ->> 'booking_code'), 'COM99L02', 'pendientes: el pedido');
select test.eq((public.owner_dashboard() ->> 'commission_owed')::numeric,
               (public.owner_commission_debts() ->> 'sum_bs')::numeric, 'panel: pendiente = lista');
select test.eq((public.owner_dashboard() ->> 'commission_month')::numeric,
               (public.owner_finance_summary() ->> 'commission_earned_bs')::numeric,
               'panel y Finanzas: la misma comisión del mes');
select test.eq((public.owner_dashboard() ? 'bookings_today'), true, 'el resto del panel sigue igual');
select test.logout();
select test.eq(has_function_privilege('authenticated', 'public._owner_dashboard_0037()', 'EXECUTE'), false,
               'la versión anterior del panel es interna');
select test.eq(has_function_privilege('authenticated', 'public._commission_collect_debts(uuid)', 'EXECUTE'), false,
               'cobrar pendientes es interno');

\o
\echo 'PRUEBAS DEL CICLO DE COMISIÓN PASARON'
