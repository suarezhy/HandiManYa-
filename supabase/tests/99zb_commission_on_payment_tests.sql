-- 0066: reglas finales de comisión. Nada se reserva; el 10 % se cobra una sola
-- vez cuando el cliente toca "Ya pagué" después de terminado el trabajo. El
-- saldo tiene que cubrir todas las comisiones por cobrar para acordar. Una
-- falta queda anotada; "No recibí el pago" abre una revisión del propietario.
-- Cuentas propias (…9aa2…), en Tupiza. Usa test.otp de 99d.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table zb_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009aa2001', 'zb-01@test.bo', '{"full_name": "Dueño ZB"}'),
  ('00000000-0000-0000-0000-000009aa2002', 'zb-02@test.bo', '{"full_name": "Gerente ZB"}'),
  ('00000000-0000-0000-0000-000009aa2003', 'zb-03@test.bo', '{"full_name": "Plomero ZB"}'),
  ('00000000-0000-0000-0000-000009aa2004', 'zb-04@test.bo', '{"full_name": "Cliente ZB"}'),
  ('00000000-0000-0000-0000-000009aa2005', 'zb-05@test.bo', '{"full_name": "Otro ZB"}');
update auth.users set phone_confirmed_at = now() where id = '00000000-0000-0000-0000-000009aa2002';
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009aa2001', 'admin');
select test.grant('00000000-0000-0000-0000-000009aa2001', '00000000-0000-0000-0000-000009aa2002', 'manager');
select test.logout();
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009aa2003', 'Plomero ZB', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009aa2003') on conflict do nothing;
select public.wallet_post('00000000-0000-0000-0000-000009aa2003', 'topup', 100, 0, 'zb:seed', null, null, 'Saldo de prueba');

create temp table tzb (k text primary key, v text);
grant all on tzb to authenticated;
create function pg_temp.zb(k text) returns uuid language sql as $$ select v::uuid from tzb where tzb.k = $1 $$;
grant execute on function pg_temp.zb(text) to authenticated;
create function pg_temp.zb_wallet() returns text language sql as $$
  select available || '/' || reserved from public.wallets where professional_id = '00000000-0000-0000-0000-000009aa2003'
$$;

-- Un pedido directo con precio acordado, llevado hasta "Terminé el trabajo".
create function pg_temp.zb_job(p_key text, p_amount numeric, p_finish boolean default true) returns void
language plpgsql as $$
declare v_id uuid;
begin
  perform test.login('00000000-0000-0000-0000-000009aa2004');
  v_id := public.create_booking('00000000-0000-0000-0000-000009aa2003',
    (select id from public.service_categories where slug = 'plomeria'), 'now', 'Trabajo ' || p_key, 'Calle Tupiza 9');
  insert into tzb values (p_key, v_id);
  perform test.logout();
  perform test.login('00000000-0000-0000-0000-000009aa2003');
  perform test.agree(v_id, p_amount);
  if p_finish then
    perform public.update_job_progress(v_id, 'on_the_way');
    perform test.arrive(v_id, '00000000-0000-0000-0000-000009aa2003', '00000000-0000-0000-0000-000009aa2004');
    perform public.update_job_progress(v_id, 'in_progress');
    perform public.update_job_progress(v_id, 'work_finished');
  end if;
  perform test.logout();
end $$;

-- 1. Antes de terminar no hay "Ya pagué"; acordar ni empezar cobran.
select pg_temp.zb_job('a', 200, false);
select test.eq(pg_temp.zb_wallet(), '100.00/0.00', 'acordar Bs 200 no reserva ni descuenta');
select test.login('00000000-0000-0000-0000-000009aa2004');
select test.expect_error($$select public.acknowledge_payment(pg_temp.zb('a'), 'cash')$$, 'HMY_INVALID_TRANSITION');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2003');
select public.update_job_progress(pg_temp.zb('a'), 'on_the_way');
select test.arrive(pg_temp.zb('a'), '00000000-0000-0000-0000-000009aa2003', '00000000-0000-0000-0000-000009aa2004');
select public.update_job_progress(pg_temp.zb('a'), 'in_progress');
select test.eq(pg_temp.zb_wallet(), '100.00/0.00', 'empezar el trabajo no cobra');
select public.update_job_progress(pg_temp.zb('a'), 'work_finished');
-- 2. "Recibí el pago" del profesional no cobra, ni repetido.
select public.acknowledge_payment(pg_temp.zb('a'), 'cash');
select public.acknowledge_payment(pg_temp.zb('a'), 'cash');
select test.eq(pg_temp.zb_wallet(), '100.00/0.00', '"Recibí el pago" no cobra');
select test.expect_error($$select public._commission_charge(pg_temp.zb('a'))$$, 'permission denied');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2005');
select test.expect_error($$select public.acknowledge_payment(pg_temp.zb('a'), 'cash')$$, 'HMY_FORBIDDEN');
select test.logout();

-- 3. "Ya pagué" cobra una vez, aunque se repita.
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.acknowledge_payment(pg_temp.zb('a'), 'qr');
select public.acknowledge_payment(pg_temp.zb('a'), 'qr');
select test.eq((public.booking_detail(pg_temp.zb('a')) #>> '{payment,commission_charged}') is null, true,
               'el cliente no ve la comisión del profesional');
select test.eq(public.confirm_completion(pg_temp.zb('a'))::text, 'completed', 'confirmar después de pagar');
select public.acknowledge_payment(pg_temp.zb('a'), 'cash');
select test.logout();
select test.eq(pg_temp.zb_wallet(), '80.00/0.00', '"Ya pagué" cobra Bs 20 una sola vez (y confirmar no cobra)');
select test.eq((select count(*)::int from public.wallet_ledger where booking_id = pg_temp.zb('a')), 1, 'un movimiento');
select test.eq((select payment_method::text from public.bookings where id = pg_temp.zb('a')), 'qr', 'queda cómo pagó el cliente');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'commission.charge'
                and target_id = pg_temp.zb('a')::text), 1, 'el cobro queda auditado');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009aa2003'
                and kind = 'commission_charged'), 1, 'el profesional recibe un aviso');
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.eq((public.booking_detail(pg_temp.zb('a')) #>> '{payment,commission_charged}')::numeric, 20.00::numeric,
               'el profesional ve la comisión cobrada');
select test.eq((public.my_wallet_summary() ->> 'total')::numeric || '/' || (public.my_wallet_summary() ->> 'commissions_collected'),
               '80.00/20.00', 'billetera: total Bs 80, comisiones cobradas Bs 20');
-- Ya pagó y él confirmó haberlo recibido: no puede pedir revisión.
select test.expect_error($$select public.report_payment_not_received(pg_temp.zb('a'), 'No me pagó nada')$$, 'HMY_INVALID_TRANSITION');
select test.logout();

-- 4. Varios trabajos a la vez: el saldo tiene que cubrir todas las comisiones
-- por cobrar. Bs 80: Bs 300 (30) + Bs 400 (40) caben, otro de Bs 200 (20) no.
select pg_temp.zb_job('b', 300);
select pg_temp.zb_job('c', 400, false);
select test.eq(public.hmy_commission_open('00000000-0000-0000-0000-000009aa2003'), 70.00::numeric, 'Bs 70 por cobrar');
select test.eq(pg_temp.zb_wallet(), '80.00/0.00', 'nada reservado');
select test.login('00000000-0000-0000-0000-000009aa2004');
insert into tzb select 'd', public.create_booking('00000000-0000-0000-0000-000009aa2003',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Trabajo d', 'Calle Tupiza 9',
  p_scheduled_start => date_trunc('hour', now()) + interval '3 days');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.expect_error($$select public.propose_price(pg_temp.zb('d'), 200)$$, 'HMY_INSUFFICIENT_BALANCE');
select test.eq((public.commission_for_amount(pg_temp.zb('d'), 200) ->> 'missing')::numeric, 10.00::numeric, 'le faltan Bs 10');
select test.logout();
-- El cliente pone su precio y el profesional lo acepta: la base también lo frena.
select test.login('00000000-0000-0000-0000-000009aa2004');
insert into tzb select 'd1', public.propose_price(pg_temp.zb('d'), 200);
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.expect_error($$select public.accept_price_offer((select v::bigint from tzb where k = 'd1'))$$, 'HMY_INSUFFICIENT_BALANCE');
select test.logout();
select test.eq((select status::text from public.bookings where id = pg_temp.zb('d')), 'requested', 'sigue sin acordar');

-- Un monto aparte que no cabe espera la recarga.
select test.login('00000000-0000-0000-0000-000009aa2003');
select public.update_job_progress(pg_temp.zb('c'), 'on_the_way');
select test.arrive(pg_temp.zb('c'), '00000000-0000-0000-0000-000009aa2003', '00000000-0000-0000-0000-000009aa2004');
select public.update_job_progress(pg_temp.zb('c'), 'in_progress');
insert into tzb select 'x', public.propose_price(pg_temp.zb('c'), 200, 'extra');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.accept_price_offer((select v::bigint from tzb where k = 'x'));
select test.logout();
select test.eq((select status from public.price_offers where id = (select v::bigint from tzb where k = 'x')), 'awaiting_funds',
               'Bs 70 + 20 no caben en Bs 80: el extra espera');

-- 5. Un trabajo completado sin "Ya pagué" cuenta 72 horas; después va a la
-- revisión del propietario y deja de contar.
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.confirm_completion(pg_temp.zb('b'));
select test.logout();
select test.eq(pg_temp.zb_wallet(), '80.00/0.00', 'confirmar no cobra');
select test.eq(public.hmy_commission_open('00000000-0000-0000-0000-000009aa2003'), 70.00::numeric, 'sigue por cobrar');
update public.bookings set completed_at = now() - interval '73 hours' where id = pg_temp.zb('b');
select test.eq(public.hmy_commission_open('00000000-0000-0000-0000-000009aa2003'), 40.00::numeric,
               'después de 72 h ya no cuenta');
select test.login('00000000-0000-0000-0000-000009aa2001');
select test.eq((public.owner_payment_reviews() -> 'unpaid' -> 0 ->> 'booking_code'),
               (select code from public.bookings where id = pg_temp.zb('b')), 'el propietario lo ve sin "Ya pagué"');
select test.eq((public.owner_payment_reviews() -> 'unpaid' -> 0 ->> 'commission')::numeric, 30.00::numeric,
               'con la comisión que habría');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2002');
select test.expect_error($$select public.owner_payment_reviews()$$, 'HMY_FORBIDDEN');
select test.logout();
-- Si el cliente marca "Ya pagué" más tarde, igual se cobra una vez.
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.acknowledge_payment(pg_temp.zb('b'), 'cash');
select test.logout();
select test.eq(pg_temp.zb_wallet(), '50.00/0.00', '"Ya pagué" tardío cobra Bs 30');

-- 6. "No recibí el pago": revisión del propietario, con devolución.
select test.login('00000000-0000-0000-0000-000009aa2004');
select test.expect_error($$select public.report_payment_not_received(pg_temp.zb('b'), 'No me pagó')$$, 'HMY_FORBIDDEN');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.expect_error($$select public.report_payment_not_received(pg_temp.zb('b'), 'no')$$, 'HMY_REASON_REQUIRED');
select test.eq((public.report_payment_not_received(pg_temp.zb('b'), 'El cliente se fue sin pagar') ->> 'status'), 'open',
               'el profesional pide revisión');
select test.expect_error($$select public.report_payment_not_received(pg_temp.zb('b'), 'Otra vez lo mismo')$$,
                         'HMY_ALREADY_REPORTED');
select test.eq((public.booking_detail(pg_temp.zb('b')) #>> '{payment,review_status}'), 'open', 'el detalle lo muestra');
select test.logout();
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009aa2004'
                and kind = 'payment_review'), 1, 'el cliente recibe un aviso');
insert into tzb select 'rv', id from public.payment_reviews where booking_id = pg_temp.zb('b');
select test.login('00000000-0000-0000-0000-000009aa2001');
select test.eq((public.owner_payment_reviews() -> 'summary' ->> 'open')::int, 1, 'una revisión abierta');
select test.eq((public.owner_payment_reviews() -> 'items' -> 0 ->> 'commission_amount')::numeric, 30.00::numeric,
               'con la comisión cobrada');
select test.expect_error($$select public.owner_resolve_payment_review(
  (select v::bigint from tzb where k = 'rv'), true, '', 'otp')$$, 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.owner_resolve_payment_review(
  (select v::bigint from tzb where k = 'rv'), true, 'El cliente no pagó', null)$$,
  'HMY_CONFIRMATION_REQUIRED');
select test.otp('00000000-0000-0000-0000-000009aa2001');
select test.eq((public.owner_resolve_payment_review((select v::bigint from tzb where k = 'rv'),
                true, 'El cliente reconoció que no pagó', 'otp') ->> 'refunded')::numeric, 30.00::numeric,
               'se devuelven Bs 30');
select test.otp('00000000-0000-0000-0000-000009aa2001');
select test.expect_error($$select public.owner_resolve_payment_review(
  (select v::bigint from tzb where k = 'rv'), true, 'otra vez', 'otp')$$, 'HMY_ALREADY_REVIEWED');
select test.logout();
select test.eq(pg_temp.zb_wallet(), '80.00/0.00', 'la comisión volvió una vez');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'payment.review_refund'), 1, 'auditado');
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.eq((public.my_wallet_summary() ->> 'commissions_collected')::numeric, 20.00::numeric,
               'comisiones cobradas sin la devuelta');
select test.eq((public.booking_detail(pg_temp.zb('b')) #>> '{payment,commission_charged}')::numeric, 0::numeric,
               'el detalle dice que no queda comisión');
select test.logout();

-- 7. Disputa después de "Ya pagué" que el propietario cancela: se devuelve.
select pg_temp.zb_job('e', 100);
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.acknowledge_payment(pg_temp.zb('e'), 'cash');
select test.eq(public.open_dispute(pg_temp.zb('e'), 'Quedó goteando')::text, 'disputed', 'el cliente abre una disputa');
select test.logout();
select test.eq(pg_temp.zb_wallet(), '70.00/0.00', 'se cobró Bs 10 en "Ya pagué"');
select test.login('00000000-0000-0000-0000-000009aa2001');
select public.resolve_dispute(pg_temp.zb('e'), 'cancelled', 'Trabajo mal hecho: se devuelve');
select test.logout();
select test.eq(pg_temp.zb_wallet(), '80.00/0.00', 'la cancelación devuelve la comisión');
select test.eq((select count(*)::int from public.wallet_ledger where booking_id = pg_temp.zb('e')), 2, 'cobro y devolución');

-- 8. Falta de saldo al cobrar (recarga revertida): cobra lo que hay, nunca
-- negativo, "Ya pagué" del cliente no falla y el profesional queda frenado.
select pg_temp.zb_job('f', 300);
select public.wallet_post('00000000-0000-0000-0000-000009aa2003', 'adjustment', -60, 0, 'zb:reverse', null, null,
                          'Reversión de una recarga');
select test.login('00000000-0000-0000-0000-000009aa2004');
select public.acknowledge_payment(pg_temp.zb('f'), 'cash');
select test.logout();
select test.eq((select commission_captured || '/' || commission_shortfall from public.bookings where id = pg_temp.zb('f')),
               '20.00/10.00', 'de Bs 30 cobra Bs 20 y anota Bs 10');
select test.eq(pg_temp.zb_wallet(), '0.00/0.00', 'el saldo queda en cero');
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.expect_error($$select public.propose_price(pg_temp.zb('d'), 10)$$, 'HMY_COMMISSION_DEBT');
select test.logout();
select test.login('00000000-0000-0000-0000-000009aa2001');
select test.eq((public.owner_commission_debts() ->> 'sum_bs')::numeric >= 10, true, 'el propietario ve la falta');
select test.logout();

-- 9. Solo el servidor cobra o devuelve; ninguna billetera negativa ni reservada.
select test.login('00000000-0000-0000-0000-000009aa2003');
select test.expect_error($$select public._commission_refund(pg_temp.zb('f'), 'x')$$, 'permission denied');
select test.expect_error($$select * from public.payment_reviews$$, 'permission denied');
select test.logout();
select test.eq(has_function_privilege('anon', 'public.report_payment_not_received(uuid, text)', 'EXECUTE'), false,
               'anon no pide revisiones');
select test.eq((select count(*)::int from public.wallets where available < 0 or reserved < 0), 0, 'ningún saldo negativo');
select test.eq((select count(*)::int from public.bookings where commission_reserved > 0), 0, 'ninguna reserva');

update public.commission_rules r set is_active = z.is_active from zb_rules z where z.id = r.id;

\o
\echo '0066 comisión en "Ya pagué": pruebas pasadas'
