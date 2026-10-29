-- "Lo necesito ahora" más seguro (0057). Cuentas propias (…9a97…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a97001', 'ya-c@test.bo', '{"full_name": "Cliente Ya"}'),
  ('00000000-0000-0000-0000-000009a97002', 'ya-p1@test.bo', '{"full_name": "Plomero Uno"}'),
  ('00000000-0000-0000-0000-000009a97003', 'ya-p2@test.bo', '{"full_name": "Plomero Dos"}'),
  ('00000000-0000-0000-0000-000009a97004', 'ya-p3@test.bo', '{"full_name": "Plomero Ocupado"}'),
  ('00000000-0000-0000-0000-000009a97005', 'ya-c2@test.bo', '{"full_name": "Otro Cliente"}');
-- Cuatro plomeros aprobados y disponibles en una ciudad propia (sin otros
-- profesionales de las demás pruebas): Tarija.
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
select u, 'Plomero', (select id from public.service_categories where slug = 'plomeria'),
       (select id from public.cities where slug = 'tarija'), 'approved', true
from unnest(array['00000000-0000-0000-0000-000009a97002', '00000000-0000-0000-0000-000009a97003',
                  '00000000-0000-0000-0000-000009a97004']::uuid[]) u;
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment(u, 50, 'Saldo de prueba', 'seed-ya57-' || u)
from unnest(array['00000000-0000-0000-0000-000009a97002', '00000000-0000-0000-0000-000009a97003',
                  '00000000-0000-0000-0000-000009a97004']::uuid[]) u;
select test.logout();

-- El plomero 3 va en camino a otro trabajo (programado): está ocupado.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             scheduled_start, scheduled_end) values
  ('00000000-0000-0000-0000-000009a97b00', '00000000-0000-0000-0000-000009a97005', '00000000-0000-0000-0000-000009a97004',
   (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'tarija'),
   'scheduled', 'Otro trabajo', 'on_the_way', now() - interval '10 minutes', now() + interval '2 hours');

create temp table t57 (k text primary key, v uuid);
grant all on t57 to authenticated;

-- ---------------------------------------------------------------------------
-- 1. El pedido llega a los disponibles, no al ocupado.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a97001');
select test.eq(public.count_ya_available((select id from public.service_categories where slug = 'plomeria'),
                                         (select id from public.cities where slug = 'tarija')), 2,
               'ocupado: no cuenta como disponible');
insert into t57 select 'a', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'tarija'), 'Gotea el caño', 'Calle Sucre 10');
select test.logout();
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v from t57 where k = 'a')), 2,
               'aviso a los dos plomeros libres');
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v from t57 where k = 'a')
                and professional_id = '00000000-0000-0000-0000-000009a97004'), 0, 'el ocupado no recibe el pedido');

-- ---------------------------------------------------------------------------
-- 2. Repetir el pedido (doble toque, reintento) no crea otro ni vuelve a avisar.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a97001');
select test.eq(public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'tarija'), 'Gotea el caño', 'Calle Sucre 10'), (select v from t57 where k = 'a'),
  'el mismo pedido otra vez devuelve el que ya espera');
select test.logout();
select test.eq((select count(*)::int from public.bookings where customer_id = '00000000-0000-0000-0000-000009a97001'), 1,
               'no se creó un segundo pedido');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009a97002'
                and kind = 'ya_offer'), 1, 'cada plomero recibe un solo aviso');

-- ---------------------------------------------------------------------------
-- 3. Suspendido después del aviso: no puede aceptar.
-- ---------------------------------------------------------------------------
update public.profiles set suspended_at = now() where id = '00000000-0000-0000-0000-000009a97003';
select test.login('00000000-0000-0000-0000-000009a97003');
select test.expect_error($$select public.claim_ya_request((select v from t57 where k = 'a'))$$, 'HMY_ACCOUNT_SUSPENDED');
select test.logout();

-- ---------------------------------------------------------------------------
-- 4. El primero acepta; después queda ocupado para otros pedidos ¡Ya!.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a97002');
select test.eq(public.claim_ya_request((select v from t57 where k = 'a'))::text, 'confirmed', 'el plomero 1 acepta');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a97003');
select test.expect_error($$select public.claim_ya_request((select v from t57 where k = 'a'))$$, 'HMY_ACCOUNT_SUSPENDED');
select test.logout();
update public.profiles set suspended_at = null where id = '00000000-0000-0000-0000-000009a97003';
select test.login('00000000-0000-0000-0000-000009a97003');
select test.expect_error($$select public.claim_ya_request((select v from t57 where k = 'a'))$$, 'HMY_ALREADY_TAKEN');
select test.logout();
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009a97001'
                and kind = 'booking_status' and data ->> 'status' = 'confirmed'), 1, 'el cliente recibe un aviso al aceptar');

-- Un pedido nuevo del mismo servicio ya es otro pedido (el anterior fue aceptado).
select test.login('00000000-0000-0000-0000-000009a97001');
insert into t57 select 'b', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'tarija'), 'Ahora el baño', 'Calle Sucre 10');
select test.logout();
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v from t57 where k = 'b')
                and professional_id = '00000000-0000-0000-0000-000009a97002'), 0,
               'quien ya tiene un pedido ¡Ya! aceptado no recibe otro');
-- Aunque tuviera la oferta (por ejemplo, de antes), no puede tomar dos a la vez.
insert into public.booking_offers (booking_id, professional_id)
values ((select v from t57 where k = 'b'), '00000000-0000-0000-0000-000009a97002');
select test.login('00000000-0000-0000-0000-000009a97002');
select test.expect_error($$select public.claim_ya_request((select v from t57 where k = 'b'))$$, 'HMY_PRO_BUSY');
select test.logout();

-- ---------------------------------------------------------------------------
-- 5. Cancelado por el cliente: no se acepta y el mensaje lo dice.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a97001');
select public.cancel_booking((select v from t57 where k = 'b'), null);
select test.logout();
select test.login('00000000-0000-0000-0000-000009a97003');
select test.expect_error($$select public.claim_ya_request((select v from t57 where k = 'b'))$$, 'HMY_REQUEST_CANCELLED');
select test.logout();
select test.eq((select status::text from public.bookings where id = (select v from t57 where k = 'b')), 'cancelled',
               'sigue cancelado');

-- Después de cancelar, pedir otra vez crea un pedido nuevo.
select test.login('00000000-0000-0000-0000-000009a97001');
insert into t57 select 'c', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'tarija'), 'Ahora el baño', 'Calle Sucre 10');
select test.logout();
select test.eq((select v from t57 where k = 'c') <> (select v from t57 where k = 'b'), true,
               'después de cancelar sale un pedido nuevo');

-- Permisos: las funciones internas no se llaman desde la app.
select test.eq(has_function_privilege('authenticated', 'public.hmy_pro_busy_now(uuid)', 'execute'), false,
               'hmy_pro_busy_now es interna');
select test.eq(has_function_privilege('authenticated', 'public._claim_ya_request_scheduled(uuid)', 'execute'), false,
               '_claim_ya_request_scheduled es interna');
select test.eq(has_function_privilege('authenticated',
  'public._create_ya_request_extras(int, smallint, text, text, text, int, public.payment_method, numeric, numeric, int[], text, text)',
  'execute'), false, '_create_ya_request_extras es interna');
select test.eq(has_function_privilege('anon', 'public.claim_ya_request(uuid)', 'execute'), false,
               'anónimos no aceptan pedidos');

\o
\echo '0057 "Lo necesito ahora" más seguro: pruebas pasadas'
