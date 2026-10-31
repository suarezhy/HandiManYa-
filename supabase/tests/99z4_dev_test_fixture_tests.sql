-- 0061: perfil profesional de prueba. Solo la base (postgres) pone la marca;
-- un perfil marcado no se muestra como "Verificado" y aprobarlo sigue
-- exigiendo el carnet aceptado. Cuentas propias (…9a90e…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a90e01', 'z4-c@test.bo', '{"full_name": "Cliente Z4"}'),
  ('00000000-0000-0000-0000-000009a90e02', 'z4-p@test.bo', '{"full_name": "Profesional Z4"}'),
  ('00000000-0000-0000-0000-000009a90e03', 'z4-d@test.bo', '{"full_name": "Borrador Z4"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a90e02', 'Prueba Z4', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'oruro'), 'approved', true),
       ('00000000-0000-0000-0000-000009a90e03', 'Borrador Z4', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'oruro'), 'draft', false);

set session_replication_role = replica;
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status) values
  ('00000000-0000-0000-0000-000009a90b01', '00000000-0000-0000-0000-000009a90e01', '00000000-0000-0000-0000-000009a90e02',
   (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'oruro'),
   'now', 'Trabajo con el profesional de prueba', 'on_the_way');
insert into public.trip_shares (booking_id, customer_id, token_hash, expires_at) values
  ('00000000-0000-0000-0000-000009a90b01', '00000000-0000-0000-0000-000009a90e01',
   encode(extensions.digest('z4-enlace-de-prueba-0000000000', 'sha256'), 'hex'), now() + interval '1 hour');
set session_replication_role = origin;
-- Con una verificación de identidad real (0063 exige una para "verificado").
insert into public.identity_checks (professional_id, sandbox, status)
values ('00000000-0000-0000-0000-000009a90e02', false, 'approved');

-- Sin la marca: igual que antes.
select test.login('00000000-0000-0000-0000-000009a90e01');
select test.eq((select is_verified from public.get_professional_public('00000000-0000-0000-0000-000009a90e02')), true,
               'sin marca: el perfil se ve verificado');
select test.eq((public.booking_detail('00000000-0000-0000-0000-000009a90b01') #>> '{professional,is_verified}'), 'true',
               'sin marca: el pedido muestra verificado');
select test.logout();
select test.eq((public.trip_share_view('z4-enlace-de-prueba-0000000000') ->> 'professional_verified'), 'true',
               'sin marca: el enlace del viaje muestra verificado');

-- Nadie con sesión de la app puede marcarse ni marcar a otro: la columna no
-- se puede escribir, y aunque se diera el permiso, la base la rechaza.
select test.login('00000000-0000-0000-0000-000009a90e02');
select test.expect_error($$update public.professional_profiles set test_fixture = true
                           where user_id = '00000000-0000-0000-0000-000009a90e02'$$, 'HMY_FORBIDDEN|permission denied');
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error($$update public.professional_profiles set test_fixture = true
                           where user_id = '00000000-0000-0000-0000-000009a90e02'$$, 'HMY_FORBIDDEN|permission denied');
select test.logout();

set role authenticated;
select test.expect_error($$insert into public.professional_profiles (user_id, test_fixture)
                           values ('00000000-0000-0000-0000-000009a90e01', true)$$, 'HMY_FORBIDDEN|permission denied');
reset role;
-- La guarda misma, con permiso de escribir la columna.
grant update (test_fixture) on public.professional_profiles to authenticated;
select test.login('00000000-0000-0000-0000-000009a90e02');
select test.expect_error($$update public.professional_profiles set test_fixture = true
                           where user_id = '00000000-0000-0000-0000-000009a90e02'$$, '^HMY_FORBIDDEN$');
select test.logout();
revoke update (test_fixture) on public.professional_profiles from authenticated;

-- La base sí (como el flujo de dev).
update public.professional_profiles set test_fixture = true
where user_id in ('00000000-0000-0000-0000-000009a90e02', '00000000-0000-0000-0000-000009a90e03');

select test.login('00000000-0000-0000-0000-000009a90e01');
select test.eq((select is_verified from public.get_professional_public('00000000-0000-0000-0000-000009a90e02')), false,
               'con marca: el perfil no se ve verificado');
select test.eq((select display_name from public.get_professional_public('00000000-0000-0000-0000-000009a90e02')),
               'Prueba Z4', 'con marca: el resto del perfil no cambia');
select test.eq((select bool_or(is_verified) from public.search_professionals(
                  (select id from public.cities where slug = 'oruro'), null, null, 'Prueba Z4')), false,
               'con marca: la búsqueda no lo muestra verificado');
select test.eq((public.booking_detail('00000000-0000-0000-0000-000009a90b01') #>> '{professional,is_verified}'), 'false',
               'con marca: el pedido no lo muestra verificado');
select test.eq((public.booking_detail('00000000-0000-0000-0000-000009a90b01') #>> '{professional,display_name}'), 'Prueba Z4',
               'con marca: el resto del pedido no cambia');
select test.logout();
select test.eq((public.trip_share_view('z4-enlace-de-prueba-0000000000') ->> 'professional_verified'), 'false',
               'con marca: el enlace del viaje no lo muestra verificado');

-- La marca no salta la regla del carnet.
select test.expect_error($$update public.professional_profiles set status = 'approved'
                           where user_id = '00000000-0000-0000-0000-000009a90e03'$$, 'HMY_ID_DOCUMENTS_REQUIRED');

-- Las capas internas no se llaman desde la app.
select test.eq((select bool_or(has_function_privilege(r, p.oid, 'EXECUTE'))
                from pg_proc p, unnest(array['anon', 'authenticated']) r
                where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('_search_professionals_base', '_get_professional_public_base',
                                    '_booking_detail_destination', '_trip_share_view_base', 'hmy_is_test_fixture',
                                    'hmy_test_fixture_guard')), false,
               'las funciones internas no se llaman desde la app');

\o
\echo '0061 profesional de prueba: pruebas pasadas'
