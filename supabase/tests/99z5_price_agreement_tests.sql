-- 0062: precio acordado entre los dos antes de aceptar, con contraofertas,
-- precio fijo, cobros aparte aprobados por los dos y visita de inspección.
-- Cuentas propias (…9a9a…), en Uyuni.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a9a001', 'z5-c@test.bo', '{"full_name": "Cliente Z5"}'),
  ('00000000-0000-0000-0000-000009a9a002', 'z5-p1@test.bo', '{"full_name": "Plomero Uno"}'),
  ('00000000-0000-0000-0000-000009a9a003', 'z5-p2@test.bo', '{"full_name": "Plomero Dos"}'),
  ('00000000-0000-0000-0000-000009a9a004', 'z5-x@test.bo', '{"full_name": "Otro Z5"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
select u, n, (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'uyuni-pt'),
       'approved', true
from (values ('00000000-0000-0000-0000-000009a9a002'::uuid, 'Plomero Uno'),
             ('00000000-0000-0000-0000-000009a9a003'::uuid, 'Plomero Dos')) v(u, n);
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9a002', 50, 'Saldo de prueba', 'seed-z5-1');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9a003', 50, 'Saldo de prueba', 'seed-z5-2');
select test.logout();

create temp table t62 (k text primary key, v text);
grant all on t62 to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Pedido directo: el cliente pone su precio, contraofertas hasta acordar.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'd', public.create_booking('00000000-0000-0000-0000-000009a9a002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Gotea el caño de la cocina', 'Calle Potosí 5',
  p_budget => 100);
select test.eq((select count(*)::int from jsonb_array_elements(public.booking_detail((select v::uuid from t62 where k = 'd'))
                #> '{price,offers}')), 1, 'el precio del cliente queda guardado');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9a002');
select test.expect_error($$select public.accept_booking((select v::uuid from t62 where k = 'd'))$$, 'HMY_PRICE_REQUIRED');
insert into t62 select 'd1', public.propose_price((select v::uuid from t62 where k = 'd'), 180, 'service', 'Con repuesto');
select test.eq((select status::text from public.bookings where id = (select v::uuid from t62 where k = 'd')), 'quote_sent',
               'la propuesta del profesional deja "Cotización enviada"');
select test.eq(public.propose_price((select v::uuid from t62 where k = 'd'), 180, 'service', 'Con repuesto'),
               (select v::bigint from t62 where k = 'd1'), 'doble toque: la misma propuesta no se repite');
-- El profesional no acepta su propia propuesta.
select test.expect_error($$select public.accept_price_offer((select v::bigint from t62 where k = 'd1'))$$, 'HMY_FORBIDDEN');
select test.logout();

select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009a9a001'
                and kind = 'price_offer'), 1, 'el cliente recibe aviso de la propuesta');

select test.login('00000000-0000-0000-0000-000009a9a004');
select test.expect_error($$select public.accept_price_offer((select v::bigint from t62 where k = 'd1'))$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 10)$$, 'HMY_FORBIDDEN|HMY_NOT_FOUND');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'd2', public.propose_price((select v::uuid from t62 where k = 'd'), 150);
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 0)$$, 'HMY_INVALID_AMOUNT');
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 50, 'extra')$$,
                         'HMY_INVALID_PRICE_KIND');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9a002');
-- La propuesta vieja del profesional quedó reemplazada.
select test.expect_error($$select public.accept_price_offer((select v::bigint from t62 where k = 'd1'))$$, 'HMY_FORBIDDEN|HMY_OFFER_CHANGED');
select test.eq(public.accept_price_offer((select v::bigint from t62 where k = 'd2'))::text, 'confirmed',
               'el profesional acepta la contraoferta del cliente');
select test.eq((public.booking_detail((select v::uuid from t62 where k = 'd')) #>> '{price,agreed_amount}')::numeric, 150::numeric,
               'el profesional ve Bs 150 acordados');
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 300)$$, 'HMY_INVALID_PRICE_KIND');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9a001');
select test.eq((public.booking_detail((select v::uuid from t62 where k = 'd')) #>> '{price,total}')::numeric, 150::numeric,
               'el cliente ve el mismo total');
select test.eq((select string_agg(o ->> 'status', ',' order by (o ->> 'id')::bigint)
                from jsonb_array_elements(public.booking_detail((select v::uuid from t62 where k = 'd')) #> '{price,offers}') o),
               'superseded,superseded,accepted', 'historial completo: 100, 180 y 150 aceptado');
select test.expect_error($$select * from public.price_offers$$, 'permission denied');
select test.logout();

-- Nadie cambia el precio acordado, ni la base sin pasar por las funciones.
select test.expect_error($$update public.bookings set agreed_amount = 999 where id = (select v::uuid from t62 where k = 'd')$$,
                         'HMY_PRICE_LOCKED');
select test.eq((select quote_amount from public.bookings where id = (select v::uuid from t62 where k = 'd')), 150.00::numeric,
               'la comisión usa el precio acordado');

-- ---------------------------------------------------------------------------
-- 2. Contraoferta del total aprobada por los dos (0067: el "monto aparte" ya
-- no se propone); "Terminé" no escribe el monto.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a002');
select public.update_job_progress((select v::uuid from t62 where k = 'd'), 'on_the_way');
select test.arrive((select v::uuid from t62 where k = 'd'), '00000000-0000-0000-0000-000009a9a002',
                   '00000000-0000-0000-0000-000009a9a001');
select public.update_job_progress((select v::uuid from t62 where k = 'd'), 'in_progress');
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 40, 'extra')$$,
                         'HMY_INVALID_PRICE_KIND');
insert into t62 select 'x1', public.propose_price((select v::uuid from t62 where k = 'd'), 190, 'total', 'Otra llave de paso');
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'd'), 300, 'repair')$$,
                         'HMY_INVALID_PRICE_KIND');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a001');
select public.accept_price_offer((select v::bigint from t62 where k = 'x1'));
select test.expect_error($$select public.accept_price_offer((select v::bigint from t62 where k = 'x1'))$$, 'HMY_OFFER_CHANGED');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a002');
insert into t62 select 'x2', public.propose_price((select v::uuid from t62 where k = 'd'), 400, 'total');
-- Una versión vieja de la app manda un monto: no cuenta.
select public.update_job_progress((select v::uuid from t62 where k = 'd'), 'work_finished', 999);
select test.logout();
select test.eq((select final_amount from public.bookings where id = (select v::uuid from t62 where k = 'd')), 190.00::numeric,
               'monto final = la contraoferta aceptada (no lo que escribió el profesional)');
select test.eq((select status from public.price_offers where id = (select v::bigint from t62 where k = 'x2')), 'expired',
               'la contraoferta sin aprobar vence al terminar');
select test.login('00000000-0000-0000-0000-000009a9a001');
select public.confirm_completion((select v::uuid from t62 where k = 'd'));
select test.logout();
select test.eq((select final_amount from public.bookings where id = (select v::uuid from t62 where k = 'd')), 190.00::numeric,
               'al completar sigue el mismo monto');

-- ---------------------------------------------------------------------------
-- 3. ¡Ya! sin precio: dos profesionales proponen, el cliente elige uno.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'y', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'uyuni-pt'), 'Se tapó el desagüe', 'Calle Potosí 5');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a002');
select test.expect_error($$select public.claim_ya_request((select v::uuid from t62 where k = 'y'))$$, 'HMY_PRICE_REQUIRED');
insert into t62 select 'y1', public.propose_price((select v::uuid from t62 where k = 'y'), 200);
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
insert into t62 select 'y2', public.propose_price((select v::uuid from t62 where k = 'y'), 160);
select test.eq((select count(*)::int from jsonb_array_elements(public.booking_detail((select v::uuid from t62 where k = 'y'))
                #> '{price,offers}')), 1, 'un profesional no ve la propuesta del otro');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9a001');
select test.eq((select count(*)::int from jsonb_array_elements(public.booking_detail((select v::uuid from t62 where k = 'y'))
                #> '{price,offers}')), 2, 'el cliente ve las dos propuestas');
select test.eq((public.booking_detail((select v::uuid from t62 where k = 'y')) #>> '{price,offers,1,professional,display_name}'),
               'Plomero Dos', 'con el nombre del profesional');
-- Contraoferta a uno solo.
insert into t62 select 'y3', public.propose_price((select v::uuid from t62 where k = 'y'), 150, 'service', null,
                                                  '00000000-0000-0000-0000-000009a9a003');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
select public.reject_price_offer((select v::bigint from t62 where k = 'y3'));
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a001');
select test.expect_error($$select public.accept_price_offer((select v::bigint from t62 where k = 'y2'))$$, 'HMY_OFFER_CHANGED');
select test.eq(public.accept_price_offer((select v::bigint from t62 where k = 'y1'))::text, 'confirmed',
               'el cliente acepta la propuesta de Plomero Uno');
select test.eq((select professional_id from public.bookings where id = (select v::uuid from t62 where k = 'y')),
               '00000000-0000-0000-0000-000009a9a002'::uuid, 'el trabajo es de quien propuso ese precio');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
-- 0067: el que perdió el pedido lee por qué.
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'y'), 120)$$, 'HMY_ALREADY_TAKEN');
select test.logout();

-- ---------------------------------------------------------------------------
-- 4. Programada con precio del cliente: el primero que lo acepta se queda.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 's', public.create_scheduled_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'uyuni-pt'), 'Cambiar el grifo', 'Calle Potosí 5', now() + interval '2 days',
  p_budget => 120);
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
select test.eq(test.agree((select v::uuid from t62 where k = 's'))::text, 'confirmed', 'Plomero Dos acepta el precio del cliente');
select test.eq((select agreed_amount from public.bookings where id = (select v::uuid from t62 where k = 's')), 120.00::numeric,
               'programada: Bs 120 acordados');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a002');
select test.expect_error($$select test.agree((select v::uuid from t62 where k = 's'))$$, 'HMY_ALREADY_TAKEN');
select test.logout();

-- ---------------------------------------------------------------------------
-- 5. Visita de inspección y reparación aparte.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'i', public.create_booking('00000000-0000-0000-0000-000009a9a003',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Humedad en la pared', 'Calle Potosí 5',
  p_scheduled_start => now() + interval '3 days');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
insert into t62 select 'i1', public.propose_price((select v::uuid from t62 where k = 'i'), 50, 'inspection', 'Visita para revisar');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a001');
select public.accept_price_offer((select v::bigint from t62 where k = 'i1'));
select test.eq((select agreed_kind from public.bookings where id = (select v::uuid from t62 where k = 'i')), 'inspection',
               'se acordó solo la visita');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
insert into t62 select 'i2', public.propose_price((select v::uuid from t62 where k = 'i'), 400, 'repair', 'Cambiar la tubería');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'i3', public.propose_price((select v::uuid from t62 where k = 'i'), 320, 'repair');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9a003');
select public.accept_price_offer((select v::bigint from t62 where k = 'i3'));
select test.expect_error($$select public.propose_price((select v::uuid from t62 where k = 'i'), 100, 'repair')$$,
                         'HMY_INVALID_PRICE_KIND');
select test.logout();
select test.eq((select agreed_amount + extras_amount from public.bookings where id = (select v::uuid from t62 where k = 'i')),
               370.00::numeric, 'visita Bs 50 + reparación aceptada Bs 320');

-- ---------------------------------------------------------------------------
-- 6. Cancelar vence las propuestas abiertas.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a9a001');
insert into t62 select 'c', public.create_booking('00000000-0000-0000-0000-000009a9a002',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Revisar el calefón', 'Calle Potosí 5',
  p_scheduled_start => now() + interval '4 days', p_budget => 80);
select public.cancel_booking((select v::uuid from t62 where k = 'c'), 'Ya no lo necesito');
select test.logout();
select test.eq((select string_agg(status, ',') from public.price_offers where booking_id = (select v::uuid from t62 where k = 'c')),
               'expired', 'al cancelar, la propuesta abierta vence');
select test.login('00000000-0000-0000-0000-000009a9a002');
select test.expect_error($$select test.agree((select v::uuid from t62 where k = 'c'))$$, 'HMY_REQUEST_CANCELLED');
select test.logout();

-- Las funciones internas no se llaman desde la app.
select test.eq((select bool_or(has_function_privilege(r, p.oid, 'EXECUTE'))
                from pg_proc p, unnest(array['anon', 'authenticated']) r
                where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('hmy_price_lock', 'hmy_price_offers_close', 'hmy_price_offers_close_for_pro',
                                    'hmy_price_role', '_hmy_assign_pro', '_create_ya_request_unpriced',
                                    '_create_scheduled_request_unpriced', '_create_booking_unpriced',
                                    '_booking_detail_unpriced')), false,
               'las funciones internas del precio no se llaman desde la app');
select test.eq(has_function_privilege('anon', 'public.accept_price_offer(bigint)', 'execute'), false,
               'anónimos no aceptan precios');

\o
\echo '0062 precio acordado: pruebas pasadas'
