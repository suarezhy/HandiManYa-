-- 0062: la comisión general (10 %) sale del precio acordado; se reserva al
-- aceptar y al aprobar un monto aparte, sin saldo negativo ni cobros dobles.
-- Cuentas propias (…9a9b…), en Tupiza.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table z6_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a9b001', 'z6-c@test.bo', '{"full_name": "Cliente Z6"}'),
  ('00000000-0000-0000-0000-000009a9b002', 'z6-p@test.bo', '{"full_name": "Plomero Z6"}'),
  ('00000000-0000-0000-0000-000009a9b004', 'z6-x@test.bo', '{"full_name": "Otro Z6"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a9b002', 'Plomero Z6', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009a9b002') on conflict do nothing;

create temp table t63 (k text primary key, v text);
grant all on t63 to authenticated;
select test.login('00000000-0000-0000-0000-000009a9b001');
insert into t63 select 'a', public.create_booking('00000000-0000-0000-0000-000009a9b002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Cambiar el lavamanos', 'Calle Tupiza 1');
select test.logout();

-- Sin saldo: ve cuánto falta y no puede proponer.
select test.login('00000000-0000-0000-0000-000009a9b002');
select test.eq((public.commission_for_amount((select v::uuid from t63 where k = 'a'), 200) ->> 'commission')::numeric,
               20.00::numeric, 'Bs 200: comisión Bs 20 (10 %)');
select test.eq((public.commission_for_amount((select v::uuid from t63 where k = 'a'), 200) ->> 'net')::numeric,
               180.00::numeric, 'le quedan Bs 180');
select test.eq((public.commission_for_amount((select v::uuid from t63 where k = 'a'), 200) ->> 'missing')::numeric,
               20.00::numeric, 'le faltan Bs 20 de saldo');
select test.expect_error($$select public.propose_price((select v::uuid from t63 where k = 'a'), 200)$$, 'HMY_INSUFFICIENT_BALANCE');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b001');
select test.expect_error($$select public.commission_for_amount((select v::uuid from t63 where k = 'a'), 200)$$, 'HMY_FORBIDDEN');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9b002', 30, 'Saldo de prueba', 'seed-z6');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9b002');
insert into t63 select 'a1', public.propose_price((select v::uuid from t63 where k = 'a'), 200);
-- Proponer no reserva nada: la comisión sale solo del precio aceptado.
select test.eq((select reserved from public.wallets), 0.00::numeric, 'una propuesta no reserva saldo');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b001');
select public.accept_price_offer((select v::bigint from t63 where k = 'a1'));
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b002');
select test.eq((select available || '/' || reserved from public.wallets), '10.00/20.00', 'al acordar se reservan Bs 20');

-- Monto aparte: se reserva su comisión al aprobarlo, una sola vez.
select public.update_job_progress((select v::uuid from t63 where k = 'a'), 'on_the_way');
select test.arrive((select v::uuid from t63 where k = 'a'), '00000000-0000-0000-0000-000009a9b002',
                   '00000000-0000-0000-0000-000009a9b001');
select public.update_job_progress((select v::uuid from t63 where k = 'a'), 'in_progress');
insert into t63 select 'x1', public.propose_price((select v::uuid from t63 where k = 'a'), 50, 'extra');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b001');
select public.accept_price_offer((select v::bigint from t63 where k = 'x1'));
select test.expect_error($$select public.accept_price_offer((select v::bigint from t63 where k = 'x1'))$$, 'HMY_OFFER_CHANGED');
insert into t63 select 'x2', public.propose_price((select v::uuid from t63 where k = 'a'), 100, 'extra');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b002');
select test.eq((select available || '/' || reserved from public.wallets), '5.00/25.00', 'el extra de Bs 50 reserva Bs 5');
-- Extra de Bs 100 (Bs 10 de comisión, tiene Bs 5): los dos lo aprueban, pero
-- espera la recarga. El trabajo y el precio acordado siguen igual.
select test.eq(public.accept_price_offer((select v::bigint from t63 where k = 'x2'))::text, 'in_progress',
               'aprobar un extra sin saldo no cambia el trabajo');
select test.logout();
select test.eq((select status from public.price_offers where id = (select v::bigint from t63 where k = 'x2')), 'awaiting_funds',
               'el extra queda esperando recarga');
select test.eq((select agreed_amount || '/' || extras_amount from public.bookings where id = (select v::uuid from t63 where k = 'a')),
               '200.00/50.00', 'el extra en espera todavía no se suma');
select test.eq((select available || '/' || reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a9b002'), '5.00/25.00', 'sin saldo negativo ni reserva');

-- La recarga activa el extra en espera; no se descuenta nada más.
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9b002', 20, 'Saldo de prueba', 'seed-z6-b');
select test.logout();
select test.eq((select status from public.price_offers where id = (select v::bigint from t63 where k = 'x2')), 'accepted',
               'con saldo, el extra cuenta');
select test.eq((select extras_amount from public.bookings where id = (select v::uuid from t63 where k = 'a')), 150.00::numeric,
               'ahora se suma: Bs 150 aparte');
select test.eq((select available || '/' || reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a9b002'), '15.00/35.00', 'se reservan Bs 10 más');

-- Otro extra sin saldo que el cliente anula.
select test.login('00000000-0000-0000-0000-000009a9b001');
insert into t63 select 'x3', public.propose_price((select v::uuid from t63 where k = 'a'), 200, 'extra');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b002');
select public.accept_price_offer((select v::bigint from t63 where k = 'x3'));
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b004');
select test.expect_error($$select public.cancel_price_offer((select v::bigint from t63 where k = 'x3'))$$, 'HMY_FORBIDDEN');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b001');
select public.cancel_price_offer((select v::bigint from t63 where k = 'x3'));
select test.logout();
select test.eq((select status from public.price_offers where id = (select v::bigint from t63 where k = 'x3')), 'withdrawn',
               'el cliente anula el extra en espera');

select test.login('00000000-0000-0000-0000-000009a9b002');
select public.update_job_progress((select v::uuid from t63 where k = 'a'), 'work_finished');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b001');
select public.confirm_completion((select v::uuid from t63 where k = 'a'));
select test.logout();
select test.eq((select final_amount || '/' || commission_captured || '/' || commission_shortfall from public.bookings
                where id = (select v::uuid from t63 where k = 'a')), '350.00/35.00/0.00',
               'final Bs 350: se cobra el 10 %, sin deuda');
select test.eq((select available || '/' || reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a9b002'), '15.00/0.00',
               'la reserva pasa a comisión cobrada');
select test.eq((select count(*)::int from public.wallet_ledger
                where booking_id = (select v::uuid from t63 where k = 'a') and entry_type = 'commission_reserve'), 3,
               'tres reservas en el historial: el precio y los dos extras');

-- Cancelar devuelve la reserva.
select test.login('00000000-0000-0000-0000-000009a9b001');
insert into t63 select 'b', public.create_booking('00000000-0000-0000-0000-000009a9b002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Revisar el tanque', 'Calle Tupiza 1',
  p_budget => 40);
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9b002');
select test.agree((select v::uuid from t63 where k = 'b'));
select test.eq((select available || '/' || reserved from public.wallets), '11.00/4.00', 'Bs 40: se reservan Bs 4');
select public.cancel_booking((select v::uuid from t63 where k = 'b'), 'No llego a tiempo');
select test.eq((select available || '/' || reserved from public.wallets), '15.00/0.00', 'al cancelar vuelve todo');
select test.logout();

update public.commission_rules r set is_active = z.is_active from z6_rules z where z.id = r.id;

\o
\echo '0062 comisión del precio acordado: pruebas pasadas'
