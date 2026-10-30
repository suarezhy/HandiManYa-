-- Ciclo de la comisión: desde 0066 acordar solo revisa el saldo, "Ya pagué"
-- cobra una vez, una falta queda anotada y bloquea trabajos nuevos, y una
-- devolución la borra. Cuentas propias (…9a3000…); ningún dato real cambia.
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
-- Desde 0066 acordar no reserva: anota la regla y revisa que el saldo cubra
-- todo lo que queda por cobrar, sin mover dinero.
-- ---------------------------------------------------------------------------
update public.bookings set agreed_amount = 200, status = 'confirmed' where id = '00000000-0000-0000-0000-000009a3b001';
select public._commission_reserve(b) from public.bookings b where id = '00000000-0000-0000-0000-000009a3b001';
select test.eq((select available || '/' || reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a30004'), '30.00/0.00', 'acordar: el saldo no se mueve');
select test.eq((select commission_rule_id from public.bookings where id = '00000000-0000-0000-0000-000009a3b001'),
               99000901, 'acordar: queda anotada la regla');
select test.eq(public.hmy_commission_open('00000000-0000-0000-0000-000009a30004'), 20.00::numeric,
               'por cobrar: Bs 20 (10 % de Bs 200)');
select test.eq((select commission_captured from public.bookings where id = '00000000-0000-0000-0000-000009a3b001') is null,
               true, 'acordar no cobra');

-- Bs 150 más: Bs 20 + 15 por cobrar no caben en Bs 30.
update public.bookings set agreed_amount = 150, status = 'confirmed' where id = '00000000-0000-0000-0000-000009a3b002';
select test.expect_error($$select public._commission_reserve(b) from public.bookings b
                           where id = '00000000-0000-0000-0000-000009a3b002'$$, 'HMY_INSUFFICIENT_BALANCE');
update public.bookings set status = 'cancelled' where id = '00000000-0000-0000-0000-000009a3b002';
select public._commission_release('00000000-0000-0000-0000-000009a3b002');
select test.eq((select count(*)::int from public.wallet_ledger where booking_id = '00000000-0000-0000-0000-000009a3b002'), 0,
               'cancelar: ningún movimiento');

-- ---------------------------------------------------------------------------
-- Completar no cobra. "Ya pagué" cobra una vez; si falta saldo cobra lo que
-- hay, nunca deja negativo y anota la diferencia. Precio Bs 200 → Bs 20, y
-- un ajuste en contra deja Bs 15 (como una recarga revertida).
-- ---------------------------------------------------------------------------
update public.bookings set status = 'completed', finished_at = now(), completed_at = now()
where id = '00000000-0000-0000-0000-000009a3b001';
select public._commission_capture('00000000-0000-0000-0000-000009a3b001');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               30.00::numeric, 'completar no cobra');
select public.wallet_post('00000000-0000-0000-0000-000009a30004', 'adjustment', -15, 0, 'test99l:a1', null, null, 'Reversión');
select public._commission_charge('00000000-0000-0000-0000-000009a3b001');
select public._commission_charge('00000000-0000-0000-0000-000009a3b001');
select test.eq((select commission_captured || '/' || commission_shortfall from public.bookings
                where id = '00000000-0000-0000-0000-000009a3b001'), '15.00/5.00', 'cobra Bs 15 y anota Bs 5');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               0.00::numeric, 'el saldo queda en cero, no negativo');
select test.eq((select count(*)::int from public.wallet_ledger
                where booking_id = '00000000-0000-0000-0000-000009a3b001' and entry_type = 'commission_capture'),
               1, 'un solo cobro en el libro');

-- Con lo anotado no acuerda trabajos nuevos, y la recarga no lo paga sola.
update public.bookings set agreed_amount = 100, status = 'confirmed' where id = '00000000-0000-0000-0000-000009a3b003';
select public.wallet_post('00000000-0000-0000-0000-000009a30004', 'topup', 50, 0, 'test99l:t2', null, null, 'Recarga');
select test.expect_error($$select public._commission_reserve(b) from public.bookings b
                           where id = '00000000-0000-0000-0000-000009a3b003'$$, 'HMY_COMMISSION_DEBT');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               50.00::numeric, 'la recarga entra entera: no se descuenta nada');

-- Devolver la comisión (revisión de pago o disputa cancelada) borra lo anotado.
select public._commission_refund('00000000-0000-0000-0000-000009a3b001', 'prueba');
select public._commission_refund('00000000-0000-0000-0000-000009a3b001', 'prueba');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009a30004'),
               65.00::numeric, 'vuelven los Bs 15, una vez');
select public._commission_reserve(b) from public.bookings b where id = '00000000-0000-0000-0000-000009a3b003';
select test.eq(public.hmy_commission_open('00000000-0000-0000-0000-000009a30004'), 10.00::numeric,
               'sin lo anotado vuelve a acordar (Bs 10 por cobrar)');

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
