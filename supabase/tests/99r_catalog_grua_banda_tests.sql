-- Catálogo: Grúa (en Mecánica) y Banda (Eventos), 0049. Cuentas propias (…9a9000…).
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_g (k text primary key, v text);
grant all on t_g to authenticated, anon;
insert into t_g select 'grua', id::text from public.service_categories where slug = 'grua';
insert into t_g select 'mec', id::text from public.service_categories where slug = 'mecanica';
insert into t_g select 'remolque', id::text from public.service_problems
  where name = 'Remolque de vehículo' and category_id = (select v::int from t_g where k = 'grua');
insert into t_g select 'link', id::text from public.service_problems
  where name = 'Grúa' and category_id = (select v::int from t_g where k = 'mec');

-- Catálogo.
select test.eq((select (name, required_doc, allows_ya, is_active)::text from public.service_categories where slug = 'grua'),
               '(Grúa,documentos_grua,t,t)', 'grúa: categoría propia, se puede pedir ya o programar');
select test.eq((select array_agg(name order by sort_order, id) from public.service_problems
                where category_id = (select v::int from t_g where k = 'grua'))::text,
               '{"Remolque de vehículo","Auxilio en carretera","Traslado al taller","Otro servicio"}',
               'grúa: remolque, auxilio en carretera y traslado al taller');
select test.eq((select opens_category_id from public.service_problems where id = (select v::int from t_g where k = 'link')),
               (select v::int from t_g where k = 'grua'), 'grúa: aparece en Mecánica y lleva a Grúa');
select test.eq((select count(*)::int from public.service_problems where category_id = (select v::int from t_g where k = 'mec')
                and name in ('El auto no arranca', 'Batería descargada', 'Cambio de aceite', 'Problema con los frenos',
                             'Problema con el motor', 'Cambio de llanta', 'Diagnóstico mecánico', 'Otro problema')), 8,
               'mecánica: conserva todas sus opciones');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'eventos' and p.name = 'Banda' and p.is_active), 1, 'eventos: ofrece Banda');

-- Solo profesionales aprobados para grúa: licencia/RUAT/SOAT y antecedentes, aceptados.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a90001', 'grua-c1@test.bo', '{"full_name": "Cliente Grua"}'),
  ('00000000-0000-0000-0000-000009a90002', 'grua-p@test.bo', '{"full_name": "Pro Grua"}'),
  ('00000000-0000-0000-0000-000009a90003', 'grua-m@test.bo', '{"full_name": "Pro Mecanico"}'),
  ('00000000-0000-0000-0000-000009a90004', 'grua-c2@test.bo', '{"full_name": "Cliente Programa"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available) values
  ('00000000-0000-0000-0000-000009a90002', 'Pro Grua', (select v::int from t_g where k = 'grua'), 1, 'approved', true),
  ('00000000-0000-0000-0000-000009a90003', 'Pro Mecanico', (select v::int from t_g where k = 'mec'), 1, 'approved', true);
insert into public.professional_documents (professional_id, doc_type, storage_path, status) values
  ('00000000-0000-0000-0000-000009a90003', 'antecedentes', '00000000-0000-0000-0000-000009a90003/a.jpg', 'accepted'),
  ('00000000-0000-0000-0000-000009a90002', 'documentos_grua', '00000000-0000-0000-0000-000009a90002/g.jpg', 'accepted');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-000009a90003', (select v::int from t_g where k = 'grua')), false,
               'grúa: un mecánico con antecedentes no queda habilitado para grúa');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-000009a90002', (select v::int from t_g where k = 'grua')), false,
               'grúa: sin antecedentes aceptados no recibe pedidos');
insert into public.professional_documents (professional_id, doc_type, storage_path, status) values
  ('00000000-0000-0000-0000-000009a90002', 'antecedentes', '00000000-0000-0000-0000-000009a90002/a.jpg', 'pending');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-000009a90002', (select v::int from t_g where k = 'grua')), false,
               'grúa: antecedentes sin revisar no alcanzan');
update public.professional_documents set status = 'accepted'
 where professional_id = '00000000-0000-0000-0000-000009a90002' and doc_type = 'antecedentes';
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-000009a90002', (select v::int from t_g where k = 'grua')), true,
               'grúa: con ambos documentos aceptados queda habilitado');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-000009a90003', (select v::int from t_g where k = 'mec')), true,
               'mecánica: la regla de siempre no cambia');

-- Pedido ¡Ya!: el destino es obligatorio y privado; solo llega al de grúa.
select test.login('00000000-0000-0000-0000-000009a90001');
select test.expect_error(format('select public.create_ya_request(%s, 1::smallint, %L, %L, p_problem_ids => array[%s])',
  (select v from t_g where k = 'grua'), 'Vehículo: Auto.', 'Av. Banzer km 9', (select v from t_g where k = 'remolque')),
  'HMY_DESTINATION_REQUIRED');
select test.expect_error(format('select public.create_ya_request(%s, 1::smallint, %L, %L, p_problem_ids => array[%s])',
  (select v from t_g where k = 'mec'), 'Se paró', 'Calle 5', (select v from t_g where k = 'link')), 'HMY_INVALID_PROBLEM');
select test.expect_error(format('select public.create_ya_request(%s, 1::smallint, %L, %L, p_destination => %L)',
  (select v from t_g where k = 'mec'), 'Se paró', 'Calle 5', 'Taller Central'), 'HMY_INVALID_PROBLEM');
insert into t_g select 'ya', public.create_ya_request((select v::int from t_g where k = 'grua'), 1::smallint,
  'Vehículo: Camioneta. No enciende', 'Av. Banzer km 9', null, null, 'cash', null, null,
  array[(select v::int from t_g where k = 'remolque')], null, 'Taller Central, 3er anillo')::text;
select test.eq((public.booking_detail((select v::uuid from t_g where k = 'ya')) -> 'address' ->> 'destination'),
               'Taller Central, 3er anillo', 'grúa: el cliente ve el destino');
select test.eq((select problem_labels from public.bookings where id = (select v::uuid from t_g where k = 'ya'))::text,
               '{"Remolque de vehículo"}', 'grúa: se guarda lo que eligió');
select test.logout();
select test.eq((select array_agg(professional_id::text) from public.booking_offers
                where booking_id = (select v::uuid from t_g where k = 'ya'))::text,
               '{00000000-0000-0000-0000-000009a90002}', 'grúa: el pedido solo llega al profesional habilitado');
-- Antes de aceptar, el profesional no ve ni la dirección ni el destino.
select test.login('00000000-0000-0000-0000-000009a90002');
select test.eq((public.booking_detail((select v::uuid from t_g where k = 'ya')) -> 'address') is null
               or jsonb_typeof(public.booking_detail((select v::uuid from t_g where k = 'ya')) -> 'address') = 'null', true,
               'grúa: el destino es privado hasta aceptar');
select test.eq(public.booking_detail((select v::uuid from t_g where k = 'ya'))::text not like '%Taller Central%', true,
               'grúa: el destino no aparece en ninguna parte antes de aceptar');
select test.logout();

-- Programado con un profesional: igual.
select test.login('00000000-0000-0000-0000-000009a90004');
select test.expect_error(format('select public.create_booking(%L, %s, %L, %L, %L, p_destination => %L)',
  '00000000-0000-0000-0000-000009a90003', (select v from t_g where k = 'grua'), 'scheduled', 'Remolque', 'Calle 5', 'Taller'),
  'HMY_PRO_NOT_CLEARED');
insert into t_g select 'prog', public.create_booking('00000000-0000-0000-0000-000009a90002',
  (select v::int from t_g where k = 'grua'), 'scheduled', 'Vehículo: Auto.', 'Calle Junín 12', null, null,
  date_trunc('hour', now()) + interval '2 days', 60, 'cash', null, null, null, null, 'Taller Moreno')::text;
select test.eq((select destination from public.booking_addresses where booking_id = (select v::uuid from t_g where k = 'prog')),
               'Taller Moreno', 'grúa: también se puede programar');
select test.logout();

select test.eq(has_function_privilege('authenticated', 'public.hmy_check_booking_extras(int, int[], text)', 'execute'), false,
               'grúa: la validación solo la usa el servidor');
select test.eq(has_function_privilege('authenticated', 'public._create_booking_problems(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int, public.payment_method, numeric, numeric, int[], text)', 'execute'), false,
               'pedidos: la función interna anterior no se llama desde la app');
\o
\echo 'PRUEBAS DE GRÚA Y BANDA PASARON'
