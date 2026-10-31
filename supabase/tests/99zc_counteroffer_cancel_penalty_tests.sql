-- 0067: "No puedo" con motivo claro y volver a tomar el pedido, contraoferta
-- del NUEVO TOTAL, penalización de Bs 3 solo al profesional que cancela después
-- de aceptar, historial de la billetera con el saldo total.
-- Cuentas propias (…9aa4…), en Villazón.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table zc_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009aa4001', 'zc-01@test.bo', '{"full_name": "Dueño ZC"}'),
  ('00000000-0000-0000-0000-000009aa4002', 'zc-02@test.bo', '{"full_name": "Plomero ZC"}'),
  ('00000000-0000-0000-0000-000009aa4003', 'zc-03@test.bo', '{"full_name": "Cliente ZC"}'),
  ('00000000-0000-0000-0000-000009aa4004', 'zc-04@test.bo', '{"full_name": "Otro ZC"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009aa4001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009aa4002', 'Plomero ZC', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'villazon-pt'), 'approved', true);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009aa4002') on conflict do nothing;
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'topup', 50, 0, 'zc:seed', null, null, 'Saldo de prueba');

create temp table tzc (k text primary key, v text);
grant all on tzc to authenticated;
create function pg_temp.zc(k text) returns uuid language sql as $$ select v::uuid from tzc where tzc.k = $1 $$;
create function pg_temp.zcn(k text) returns bigint language sql as $$ select v::bigint from tzc where tzc.k = $1 $$;
grant execute on function pg_temp.zc(text) to authenticated;
grant execute on function pg_temp.zcn(text) to authenticated;
create function pg_temp.zc_balance() returns numeric language sql security definer as $$
  select available from public.wallets where professional_id = '00000000-0000-0000-0000-000009aa4002'
$$;

-- Un pedido directo de Bs p_amount acordado (confirmado).
create function pg_temp.zc_job(p_key text, p_amount numeric) returns void
language plpgsql as $$
begin
  perform test.login('00000000-0000-0000-0000-000009aa4003');
  insert into tzc values (p_key, public.create_booking('00000000-0000-0000-0000-000009aa4002',
    (select id from public.service_categories where slug = 'plomeria'), 'now', 'Trabajo ' || p_key, 'Calle Villazón 3'));
  perform test.login('00000000-0000-0000-0000-000009aa4002');
  perform test.agree(pg_temp.zc(p_key), p_amount);
  perform test.logout();
end $$;

-- ---------------------------------------------------------------------------
-- 1. ¡Ya! (como 69E3FD38): "No puedo" suelta el pedido; después el error dice
-- por qué, y mientras siga abierto el profesional lo puede volver a tomar.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009aa4003');
insert into tzc select 'y', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'villazon-pt'), 'Fuga de agua en el baño', 'Calle Villazón 3');
insert into tzc select 'yp', public.propose_price(pg_temp.zc('y'), 100);
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.eq(public.booking_detail(pg_temp.zc('y')) ->> 'my_invite', 'pending', 'el aviso del profesional está abierto');
select public.decline_ya_offer(pg_temp.zc('y'));
select public.decline_ya_offer(pg_temp.zc('y')); -- doble toque
select test.eq(public.booking_detail(pg_temp.zc('y')) ->> 'my_invite', 'declined', 'la pantalla sabe que dijo "No puedo"');
select test.expect_error($$select public.propose_price(pg_temp.zc('y'), 130)$$, 'HMY_OFFER_DECLINED');
select test.expect_error($$select public.accept_price_offer(pg_temp.zcn('yp'))$$, 'HMY_OFFER_DECLINED');
select public.reopen_ya_offer(pg_temp.zc('y'));
select test.expect_error($$select public.reopen_ya_offer(pg_temp.zc('y'))$$, 'HMY_NOT_FOUND');
insert into tzc select 'y130', public.propose_price(pg_temp.zc('y'), 130);
select test.eq(public.accept_price_offer(pg_temp.zcn('yp'))::text, 'confirmed', 'vuelve a tomarlo y acepta Bs 100');
select test.logout();
select test.eq((select agreed_amount from public.bookings where id = pg_temp.zc('y')), 100.00::numeric, 'Bs 100 acordados');
select test.eq(pg_temp.zc_balance(), 50.00::numeric, 'aceptar no cobra');
-- Otra cuenta sigue sin permiso.
select test.login('00000000-0000-0000-0000-000009aa4004');
select test.expect_error($$select public.propose_price(pg_temp.zc('y'), 90)$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.reopen_ya_offer(pg_temp.zc('y'))$$, 'HMY_NOT_FOUND');
select test.logout();

-- ---------------------------------------------------------------------------
-- 2. Contraoferta (como F3358CEF): Bs 130 es el NUEVO TOTAL, no 100 + 130.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.expect_error($$select public.propose_price(pg_temp.zc('y'), 30, 'extra')$$, 'HMY_INVALID_PRICE_KIND');
select test.expect_error($$select public.propose_price(pg_temp.zc('y'), 100, 'total')$$, 'HMY_SAME_PRICE');
insert into tzc select 't1', public.propose_price(pg_temp.zc('y'), 130, 'total');
select test.eq(public.propose_price(pg_temp.zc('y'), 130, 'total'), pg_temp.zcn('t1'), 'doble toque: una sola propuesta');
select test.expect_error($$select public.accept_price_offer(pg_temp.zcn('t1'))$$, 'HMY_FORBIDDEN');
select test.logout();
select test.eq((select agreed_amount + extras_amount from public.bookings where id = pg_temp.zc('y')), 100.00::numeric,
               'mientras espera, el precio acordado no cambia');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009aa4003'
                and title = 'Contraoferta: nuevo precio total'), 1, 'el cliente recibe aviso de la contraoferta');
-- El cliente contraoferta Bs 120: reemplaza la de Bs 130.
select test.login('00000000-0000-0000-0000-000009aa4003');
insert into tzc select 't2', public.propose_price(pg_temp.zc('y'), 120, 'total');
select test.logout();
select test.eq((select status from public.price_offers where id = pg_temp.zcn('t1')), 'superseded', 'la de Bs 130 queda reemplazada');
select test.login('00000000-0000-0000-0000-000009aa4003');
select test.expect_error($$select public.accept_price_offer(pg_temp.zcn('t1'))$$, 'HMY_OFFER_CHANGED');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.accept_price_offer(pg_temp.zcn('t2'));
select test.expect_error($$select public.accept_price_offer(pg_temp.zcn('t2'))$$, 'HMY_OFFER_CHANGED');
select test.eq((public.booking_detail(pg_temp.zc('y')) #>> '{price,total}')::numeric, 120.00::numeric,
               'el profesional ve el total nuevo: Bs 120');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
select test.eq((public.booking_detail(pg_temp.zc('y')) #>> '{price,total}')::numeric, 120.00::numeric,
               'el cliente ve el mismo total');
-- Bajar el total también: Bs 110.
insert into tzc select 't3', public.propose_price(pg_temp.zc('y'), 110, 'total');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.accept_price_offer(pg_temp.zcn('t3'));
select test.logout();
select test.eq((select agreed_amount || '/' || extras_amount from public.bookings where id = pg_temp.zc('y')), '100.00/10.00',
               'el precio inicial queda; el total es la contraoferta (Bs 110)');
select test.eq(pg_temp.zc_balance(), 50.00::numeric, 'una contraoferta aceptada no cobra');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'price.change_accepted'
                and target_id = pg_temp.zc('y')::text), 2, 'cada cambio aceptado queda auditado');
select test.eq((select string_agg(kind || ':' || amount || ':' || status, ',' order by id) from public.price_offers
                where booking_id = pg_temp.zc('y') and kind = 'total'),
               'total:130.00:superseded,total:120.00:accepted,total:110.00:accepted', 'historial de propuestas');
-- Nadie baja el total sin una contraoferta aceptada.
select test.expect_error($$update public.bookings set extras_amount = 0 where id = pg_temp.zc('y')$$, 'HMY_PRICE_LOCKED');
-- La comisión usa el total final: 10 % de Bs 110 al tocar "Ya pagué".
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.update_job_progress(pg_temp.zc('y'), 'on_the_way');
select test.arrive(pg_temp.zc('y'), '00000000-0000-0000-0000-000009aa4002', '00000000-0000-0000-0000-000009aa4003');
select public.update_job_progress(pg_temp.zc('y'), 'in_progress');
select public.update_job_progress(pg_temp.zc('y'), 'work_finished');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
select public.confirm_completion(pg_temp.zc('y'));
select test.eq(pg_temp.zc_balance(), 50.00::numeric, 'confirmar no cobra');
select public.acknowledge_payment(pg_temp.zc('y'), 'cash');
select public.acknowledge_payment(pg_temp.zc('y'), 'cash');
select test.logout();
select test.eq(pg_temp.zc_balance(), 39.00::numeric, '"Ya pagué" cobra Bs 11 (10 % de Bs 110) una vez');
select test.eq((select final_amount from public.bookings where id = pg_temp.zc('y')), 110.00::numeric, 'final Bs 110');
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.eq((public.booking_detail(pg_temp.zc('y')) #>> '{payment,commission_rate}')::numeric, 10.00::numeric,
               'el detalle financiero muestra el 10 %');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
select test.eq((public.booking_detail(pg_temp.zc('y')) #>> '{payment,commission_rate}') is null, true,
               'el cliente no ve la comisión');
select test.logout();

-- Subir el total: el saldo tiene que cubrir la comisión del total nuevo.
select pg_temp.zc_job('h', 100);
select test.login('00000000-0000-0000-0000-000009aa4002');
-- Bs 39 de saldo, Bs 10 por cobrar: hasta Bs 390 de total cabe, Bs 400 no.
select test.expect_error($$select public.propose_price(pg_temp.zc('h'), 400, 'total')$$, 'HMY_INSUFFICIENT_BALANCE');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
insert into tzc select 'h1', public.propose_price(pg_temp.zc('h'), 400, 'total');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.expect_error($$select public.accept_price_offer(pg_temp.zcn('h1'))$$, 'HMY_INSUFFICIENT_BALANCE');
insert into tzc select 'h2', public.propose_price(pg_temp.zc('h'), 390, 'total');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
select public.accept_price_offer(pg_temp.zcn('h2'));
select test.logout();
select test.eq((select agreed_amount + extras_amount from public.bookings where id = pg_temp.zc('h')), 390.00::numeric,
               'el total sube a Bs 390');

-- ---------------------------------------------------------------------------
-- 3. Penalización de Bs 3: solo el profesional que cancela después de aceptar.
-- ---------------------------------------------------------------------------
-- El cliente cancela un trabajo aceptado: sin penalización para nadie.
select test.login('00000000-0000-0000-0000-000009aa4003');
select public.cancel_booking(pg_temp.zc('h'), '');
select test.logout();
select test.eq(pg_temp.zc_balance(), 39.00::numeric, 'el cliente cancela: nadie paga penalización');
select test.eq((select cancel_penalty from public.bookings where id = pg_temp.zc('h')) is null, true, 'sin penalización anotada');
-- El profesional dice "No puedo" antes de aceptar: sin penalización.
select test.login('00000000-0000-0000-0000-000009aa4003');
insert into tzc select 'n', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'villazon-pt'), 'Gotea la ducha', 'Calle Villazón 3');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.decline_ya_offer(pg_temp.zc('n'));
select test.logout();
select test.eq(pg_temp.zc_balance(), 39.00::numeric, '"No puedo" antes de aceptar: sin penalización');
select test.login('00000000-0000-0000-0000-000009aa4003');
select public.cancel_booking(pg_temp.zc('n'), '');
select test.logout();
-- Cancela después de aceptar, sin escribir motivo: Bs 3, una sola vez.
select pg_temp.zc_job('p', 80);
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.eq(public.cancel_booking(pg_temp.zc('p'), '')::text, 'cancelled', 'cancela sin motivo');
select public.cancel_booking(pg_temp.zc('p'), '');
select test.eq((public.booking_detail(pg_temp.zc('p')) #>> '{cancel_penalty,charged}')::numeric, 3.00::numeric,
               'el profesional ve la penalización');
select test.logout();
select test.eq(pg_temp.zc_balance(), 36.00::numeric, 'Bs 3 descontados una vez');
select test.eq((select count(*)::int from public.wallet_ledger where booking_id = pg_temp.zc('p') and entry_type = 'penalty'), 1,
               'un movimiento de penalización');
select test.eq((select note from public.booking_events where booking_id = pg_temp.zc('p') and to_status = 'cancelled'),
               'Cancelada por el profesional', 'sin motivo, el paso dice quién canceló');
-- En camino también cuenta.
select pg_temp.zc_job('q', 80);
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.update_job_progress(pg_temp.zc('q'), 'on_the_way');
select public.cancel_booking(pg_temp.zc('q'), 'Se me pinchó la llanta');
select test.logout();
select test.eq(pg_temp.zc_balance(), 33.00::numeric, 'en camino: Bs 3');
-- Sin saldo suficiente: cobra lo que hay, nunca negativo, y queda anotado.
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'adjustment', -31, 0, 'zc:drain', null, null, 'Prueba');
select pg_temp.zc_job('r', 10);
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.cancel_booking(pg_temp.zc('r'), '');
select test.logout();
select test.eq((select cancel_penalty || '/' || cancel_penalty_shortfall from public.bookings where id = pg_temp.zc('r')),
               '2.00/1.00', 'con Bs 2 cobra Bs 2 y anota Bs 1');
select test.eq(pg_temp.zc_balance(), 0.00::numeric, 'el saldo queda en cero');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'cancel_penalty.charge'
                and target_id in (pg_temp.zc('p')::text, pg_temp.zc('q')::text, pg_temp.zc('r')::text)), 3, 'auditadas');
-- Nadie más cobra ni devuelve penalizaciones.
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.expect_error($$select public._hmy_charge_cancel_penalty(pg_temp.zc('p'))$$, 'permission denied');
select test.expect_error($$select public.owner_waive_cancel_penalty(pg_temp.zc('p'), 'x', 'otp')$$, 'HMY_FORBIDDEN');
select test.logout();
-- El propietario la devuelve (emergencia): nota y confirmación, una vez.
select test.login('00000000-0000-0000-0000-000009aa4001');
select test.expect_error($$select public.owner_waive_cancel_penalty(pg_temp.zc('p'), '', 'otp')$$, 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.owner_waive_cancel_penalty(pg_temp.zc('p'), 'Emergencia', 'otp')$$, 'HMY_CONFIRMATION');
select test.otp('00000000-0000-0000-0000-000009aa4001');
select test.eq(public.owner_waive_cancel_penalty(pg_temp.zc('p'), 'Emergencia médica', 'otp'), 3.00::numeric, 'devuelve Bs 3');
select test.otp('00000000-0000-0000-0000-000009aa4001');
select test.expect_error($$select public.owner_waive_cancel_penalty(pg_temp.zc('p'), 'Otra vez', 'otp')$$, 'HMY_ALREADY_REVIEWED');
select test.eq((select count(*)::int from jsonb_array_elements(public.owner_payment_reviews('all') -> 'penalties') x
                where x ->> 'booking_code' = (select code from public.bookings where id = pg_temp.zc('r'))
                  and (x ->> 'shortfall')::numeric = 1), 1, 'el propietario ve la penalización con lo que faltó');
select test.logout();
select test.eq(pg_temp.zc_balance(), 3.00::numeric, 'la devolución vuelve al saldo');

-- ---------------------------------------------------------------------------
-- 4. Historial: cambio del saldo total, total después y número de solicitud.
-- ---------------------------------------------------------------------------
-- Un cobro viejo con reserva (como F9A50778): reserva y cobro de la reserva.
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'topup', 20, 0, 'zc:topup', null, null, 'Recarga');
select pg_temp.zc_job('old', 120);
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'commission_reserve', -12, 12, 'zc:old-reserve',
                          pg_temp.zc('old'), null, 'Reserva vieja');
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'commission_capture', 0, -12, 'zc:old-capture',
                          pg_temp.zc('old'), null, 'Comisión vieja');
select test.login('00000000-0000-0000-0000-000009aa4002');
select test.eq((select amount || '/' || balance_after || '/' || booking_code from public.my_wallet_history(5) limit 1),
               '-12.00/11.00/' || (select code from public.bookings where id = pg_temp.zc('old')),
               'el cobro viejo muestra -Bs 12, el saldo total después y el número de solicitud');
select test.eq((select count(*)::int from public.my_wallet_history(200) where entry_type = 'commission_reserve'), 0,
               'la reserva vieja no se lista (no cambió el total)');
select test.eq((select amount from public.my_wallet_history(200) where entry_type = 'penalty'
                and booking_id = pg_temp.zc('p')), -3.00::numeric, 'la penalización aparece con -Bs 3');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4004');
select test.eq((select count(*)::int from public.my_wallet_history(200)), 0, 'nadie ve la billetera de otro');
select test.logout();
select test.eq(has_function_privilege('anon', 'public.my_wallet_history(int)', 'EXECUTE'), false, 'anon no lee historiales');
select test.eq((select count(*)::int from public.wallets where available < 0 or reserved < 0), 0, 'ningún saldo negativo');

-- 5. "Negociando precio": hay una propuesta de un profesional esperando.
select test.login('00000000-0000-0000-0000-000009aa4003');
select public.cancel_booking(pg_temp.zc('old'), '');
insert into tzc select 'g', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'villazon-pt'), 'Cambiar un grifo', 'Calle Villazón 3');
select test.logout();
select public.wallet_post('00000000-0000-0000-0000-000009aa4002', 'topup', 50, 0, 'zc:topup2', null, null, 'Recarga');
select test.login('00000000-0000-0000-0000-000009aa4003');
select test.eq((select negotiating from public.my_bookings('customer') where id = pg_temp.zc('g')), false,
               'sin propuestas sigue "Buscando profesional"');
select test.login('00000000-0000-0000-0000-000009aa4002');
select public.propose_price(pg_temp.zc('g'), 90);
select test.eq((select negotiating from public.my_bookings('professional') where id = pg_temp.zc('g')), true,
               'el profesional ve "Negociando precio"');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa4003');
select test.eq((select negotiating from public.my_bookings('customer') where id = pg_temp.zc('g')), true,
               'el cliente ve "Negociando precio"');
select public.cancel_booking(pg_temp.zc('g'), '');
select test.logout();

update public.commission_rules r set is_active = z.is_active from zc_rules z where z.id = r.id;

\o
\echo '0067 contraoferta y penalización: pruebas pasadas'
