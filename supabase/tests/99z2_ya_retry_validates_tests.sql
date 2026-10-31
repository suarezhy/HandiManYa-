-- 0059: repetir un pedido ¡Ya! con datos que no valen da el error, no el pedido
-- que ya espera. Cuentas propias (…9a94…), en Azurduy.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a94001', 'ya59-c@test.bo', '{"full_name": "Cliente 59"}');

create temp table t59 (k text primary key, v uuid);
grant all on t59 to authenticated;
-- Un pedido de mecánica ya esperando respuesta.
insert into t59 values ('a', '00000000-0000-0000-0000-000009a94b01');
insert into public.bookings (id, customer_id, category_id, city_id, mode, description, status, response_deadline) values
  ('00000000-0000-0000-0000-000009a94b01', '00000000-0000-0000-0000-000009a94001',
   (select id from public.service_categories where slug = 'mecanica'), (select id from public.cities where slug = 'azurduy-ch'),
   'now', 'El auto no arranca', 'awaiting_response', now() + interval '5 minutes');
select test.login('00000000-0000-0000-0000-000009a94001');
select test.expect_error($$select public.create_ya_request((select id from public.service_categories where slug = 'mecanica'),
  (select id from public.cities where slug = 'azurduy-ch'), 'El auto no arranca', 'Calle 1', p_destination => 'Taller Central')$$,
  'HMY_INVALID_PROBLEM');
select test.eq(public.create_ya_request((select id from public.service_categories where slug = 'mecanica'),
  (select id from public.cities where slug = 'azurduy-ch'), 'El auto no arranca', 'Calle 1'), (select v from t59 where k = 'a'),
  'el mismo pedido válido sigue devolviendo el que espera');
select test.logout();

\o
\echo '0059 pedido ¡Ya! repetido se revisa: pruebas pasadas'
