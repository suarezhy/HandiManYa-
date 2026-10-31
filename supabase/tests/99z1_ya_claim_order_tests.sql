-- 0058: un pedido ¡Ya! ya tomado dice HMY_ALREADY_TAKEN, también al mismo
-- profesional; un pedido abierto sigue diciendo HMY_PRO_BUSY. Cuentas propias (…9a98…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a98001', 'ya58-c@test.bo', '{"full_name": "Cliente 58"}'),
  ('00000000-0000-0000-0000-000009a98002', 'ya58-p@test.bo', '{"full_name": "Plomero 58"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a98002', 'Plomero', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'cobija'), 'approved', true);
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a98002', 50, 'Saldo de prueba', 'seed-ya58');
select test.logout();

create temp table t58 (k text primary key, v uuid);
grant all on t58 to authenticated;
select test.login('00000000-0000-0000-0000-000009a98001');
insert into t58 select 'a', public.create_ya_request((select id from public.service_categories where slug = 'plomeria'),
  (select id from public.cities where slug = 'cobija'), 'Gotea el caño', 'Calle 1');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a98002');
select test.eq(test.agree((select v from t58 where k = 'a'))::text, 'confirmed', 'el plomero acepta');
select test.expect_error($$select test.agree((select v from t58 where k = 'a'))$$, 'HMY_ALREADY_TAKEN');
select test.logout();

-- Otro pedido abierto (con oferta): sigue ocupado.
insert into public.bookings (id, customer_id, category_id, city_id, mode, description, status) values
  ('00000000-0000-0000-0000-000009a98b01', '00000000-0000-0000-0000-000009a98001',
   (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'cobija'),
   'now', 'Otro trabajo de prueba', 'awaiting_response');
insert into public.booking_offers (booking_id, professional_id)
values ('00000000-0000-0000-0000-000009a98b01', '00000000-0000-0000-0000-000009a98002');
select test.login('00000000-0000-0000-0000-000009a98002');
select test.expect_error($$select test.agree('00000000-0000-0000-0000-000009a98b01')$$, 'HMY_PRO_BUSY');
select test.logout();

\o
\echo '0058 orden de avisos al aceptar ¡Ya!: pruebas pasadas'
