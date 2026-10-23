-- Pruebas de "¿Qué necesitas solucionar?": problemas por categoría, su
-- administración, la selección en cada solicitud y las categorías sensibles.
-- Corre después de 40_admin_safety_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'cli50@test.bo', '{"full_name":"Carmen Mamani","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'cerr50@test.bo', '{"full_name":"Jorge Quispe","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'plom50@test.bo', '{"full_name":"Hugo Céspedes","city_id":"1"}');

-- Un cerrajero (categoría sensible) y un plomero, aprobados y disponibles en Santa Cruz.
do $$
declare
  v uuid;
  v_cat int;
begin
  foreach v in array array['00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000f3']::uuid[] loop
    v_cat := case when v = '00000000-0000-0000-0000-0000000000f2'
                  then (select id from public.service_categories where slug = 'cerrajeria')
                  else (select id from public.service_categories where slug = 'plomeria') end;
    perform test.login(v);
    perform public.start_professional_application();
    update public.professional_profiles set primary_category_id = v_cat where user_id = v;
    insert into public.professional_documents (professional_id, doc_type, storage_path) values (v, 'ci_anverso', v || '/ci.jpg');
    perform public.submit_professional_application();
    perform test.logout();
    perform test.login('00000000-0000-0000-0000-00000000000a');
    perform test.accept_id(v);
    perform public.review_professional_application(v, 'approved');
    perform public.admin_wallet_adjustment(v, 50, 'Saldo de prueba', 'seed50-' || v);
    perform test.logout();
    perform test.login(v);
    perform public.set_availability(true);
    perform test.logout();
  end loop;
end $$;

create temp table t_sp (k text primary key, v text);
grant all on t_sp to authenticated, anon;

-- 1. Cada categoría tiene su lista, con una sola opción "Otro"
do $$
declare r record;
begin
  for r in select c.slug, c.name,
                  count(p.id) filter (where p.is_active) as n,
                  count(p.id) filter (where p.is_active and p.is_other) as n_other
           from public.service_categories c
           left join public.service_problems p on p.category_id = c.id
           where c.is_active group by c.slug, c.name loop
    perform test.eq(r.n >= 2, true, 'problemas: ' || r.name || ' tiene su propia lista');
    perform test.eq(r.n_other, 1::bigint, 'problemas: ' || r.name || ' tiene una opción "Otro"');
  end loop;
  perform test.eq((select count(*)::int from public.service_categories where is_active) >= 18, true, 'problemas: al menos las 18 categorías iniciales');
end $$;
select test.eq((select array_agg(name order by sort_order) from public.service_problems
                where category_id = (select id from public.service_categories where slug = 'plomeria')),
               array['Fuga de agua','Destapar cañería','Reparar inodoro','Reparar o instalar grifo','Problema con la ducha',
                     'Sin agua','Instalar tuberías','Otro problema'], 'problemas: lista de Plomería en orden');
select test.eq((select array_agg(name order by sort_order) from public.service_problems
                where category_id = (select id from public.service_categories where slug = 'asesoria-legal')),
               array['Consulta legal','Contratos','Trámites','Derecho familiar','Asuntos laborales','Asuntos comerciales',
                     'Documentos legales','Otra consulta'], 'problemas: lista de Asesoría legal en orden');

-- 2. Cualquiera puede leer la lista; solo el admin la cambia
select test.login(null);
select test.eq((select count(*)::int from public.service_problems) > 100, true, 'problemas: se leen sin iniciar sesión');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000f1');
select test.expect_error($$insert into public.service_problems (category_id, name) values (1, 'Falso')$$, 'row-level security');
with u as (update public.service_problems set name = 'X' where category_id = 1 returning 1)
select test.eq((select count(*)::int from u), 0, 'problemas: un cliente no los cambia');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
insert into public.service_problems (category_id, name, icon, sort_order) values (1, 'Calefón a gas', 'build', 75);
insert into t_sp select 'nuevo', id::text from public.service_problems where name = 'Calefón a gas';
update public.service_problems set name = 'Revisar calefón' where id = (select v::int from t_sp where k = 'nuevo');
update public.service_problems set sort_order = 5 where id = (select v::int from t_sp where k = 'nuevo');
select test.eq((select name from public.service_problems where category_id = 1 order by sort_order limit 1), 'Revisar calefón', 'admin: reordena problemas');
update public.service_problems set is_active = false where id = (select v::int from t_sp where k = 'nuevo');
select test.eq((select count(*)::int from public.admin_audit_log where action like 'service_problems.%'), 4, 'auditoría: registra cada cambio de problemas');
insert into public.service_categories (slug, name, icon, sort_order) values ('fumigacion', 'Fumigación', 'build', 50);
select test.eq((select array_agg(p.name) from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'fumigacion' and p.is_other), array['Otro servicio'], 'admin: una categoría nueva nace con "Otro servicio"');
update public.service_categories set is_active = false where slug = 'fumigacion';
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000f1');
select test.eq((select count(*)::int from public.service_problems where id = (select v::int from t_sp where k = 'nuevo')), 0, 'problemas: el cliente no ve los desactivados');
select test.logout();

-- 3. Solicitud ¡Ya! con varios problemas
select test.login('00000000-0000-0000-0000-0000000000f1');
insert into t_sp select 'p_fuga', id::text from public.service_problems where category_id = 1 and name = 'Fuga de agua';
insert into t_sp select 'p_agua', id::text from public.service_problems where category_id = 1 and name = 'Sin agua';
insert into t_sp select 'p_otro', id::text from public.service_problems where category_id = 1 and is_other;
insert into t_sp select 'p_luz', id::text from public.service_problems where category_id = 2 and name = 'No tengo luz';
select test.expect_error(format('select public.create_ya_request(1, 1::smallint, %L, %L, p_problem_ids => array[%s, %s])',
  'Agua por todas partes', 'Calle 5', (select v from t_sp where k = 'p_fuga'), (select v from t_sp where k = 'p_luz')), 'HMY_INVALID_PROBLEM');
select test.expect_error(format('select public.create_ya_request(1, 1::smallint, %L, %L, p_problem_ids => array[%s])',
  '', 'Calle 5', (select v from t_sp where k = 'p_otro')), 'HMY_OTHER_REQUIRED');
select test.expect_error(format('select public.create_ya_request(1, 1::smallint, %L, %L, p_problem_ids => array[%s], p_other_text => %L)',
  '', 'Calle 5', (select v from t_sp where k = 'p_fuga'), 'texto suelto'), 'HMY_INVALID_PROBLEM');
select test.expect_error(format('select public.create_ya_request(1, 1::smallint, %L, %L, p_problem_ids => %L::int[])',
  '', 'Calle 5', (select array_agg(id) from (select id from public.service_problems order by id limit 9) x)), 'HMY_TOO_MANY_PROBLEMS');
insert into t_sp select 'ya', public.create_ya_request(1, 1::smallint, '', 'Calle Junín 12', null, null, 'cash', null, null,
  array[(select v::int from t_sp where k = 'p_agua'), (select v::int from t_sp where k = 'p_fuga'), (select v::int from t_sp where k = 'p_otro')],
  'el tanque hace ruido')::text;
select test.eq((select problem_labels from public.bookings where id = (select v::uuid from t_sp where k = 'ya')),
  array['Fuga de agua', 'Sin agua', 'Otro problema: el tanque hace ruido'], 'solicitud: guarda los problemas elegidos');
select test.eq((select description from public.bookings where id = (select v::uuid from t_sp where k = 'ya')),
  'Fuga de agua. Sin agua. Otro problema: el tanque hace ruido', 'solicitud: sin descripción usa los problemas');
select test.eq((select category_id from public.bookings where id = (select v::uuid from t_sp where k = 'ya')), 1, 'solicitud: guarda la categoría');
select test.expect_error(format('update public.bookings set problem_labels = %L where id = %L', '{Nada}', (select v from t_sp where k = 'ya')), 'permission denied');
select test.logout();

-- 4. El profesional ve los problemas antes de aceptar, pero no la dirección
select test.login('00000000-0000-0000-0000-0000000000f3');
do $$
declare d jsonb := public.booking_detail((select v::uuid from t_sp where k = 'ya'));
begin
  perform test.eq(d -> 'problems', '["Fuga de agua", "Sin agua", "Otro problema: el tanque hace ruido"]'::jsonb, 'profesional: ve los problemas en la oferta');
  perform test.eq(d ->> 'is_offer', 'true', 'profesional: todavía es una oferta');
  perform test.eq(d -> 'address' is null or d -> 'address' = 'null'::jsonb, true, 'privacidad: sin dirección antes de aceptar');
  perform test.eq((select problems from public.my_bookings('professional') where id = (select v::uuid from t_sp where k = 'ya')),
    array['Fuga de agua', 'Sin agua', 'Otro problema: el tanque hace ruido'], 'profesional: la lista de ofertas trae los problemas');
end $$;
select test.logout();

-- 5. Solicitud programada con un profesional elegido
select test.login('00000000-0000-0000-0000-0000000000f1');
insert into t_sp select 'prog', public.create_booking('00000000-0000-0000-0000-0000000000f3', 1, 'scheduled',
  'Mejor en la mañana', 'Calle Junín 12', null, null, date_trunc('hour', now()) + interval '3 days', 60, 'cash', null, null,
  array[(select v::int from t_sp where k = 'p_fuga')])::text;
select test.eq((select problem_labels from public.bookings where id = (select v::uuid from t_sp where k = 'prog')),
  array['Fuga de agua'], 'programada: guarda el problema');
select test.eq((select description from public.bookings where id = (select v::uuid from t_sp where k = 'prog')),
  'Mejor en la mañana', 'programada: guarda la descripción del cliente');
insert into t_sp select 'viejo', public.create_booking('00000000-0000-0000-0000-0000000000f3', 1, 'now',
  'Pedido sin elegir problema', 'Calle Junín 12')::text;
select test.eq((select problem_labels is null from public.bookings where id = (select v::uuid from t_sp where k = 'viejo')),
  true, 'compatibilidad: se puede pedir sin elegir problema');
select test.logout();

-- 6. Categorías sensibles
select test.login('00000000-0000-0000-0000-0000000000f1');
select test.expect_error(format('select public.create_ya_request(%s, 1::smallint, %L, %L)',
  (select id from public.service_categories where slug = 'ninera'), 'Cuidar a mi hija', 'Calle 5'), 'HMY_YA_NOT_ALLOWED');
select test.expect_error(format('select public.create_ya_request(%s, 1::smallint, %L, %L)',
  (select id from public.service_categories where slug = 'asesoria-legal'), 'Revisar un contrato', 'Calle 5'), 'HMY_YA_NOT_ALLOWED');
select test.eq(public.count_ya_available((select id from public.service_categories where slug = 'cerrajeria'), 1::smallint), 0,
  'cerrajería: sin antecedentes aceptados no recibe pedidos ¡Ya!');
select test.eq((select count(*)::int from public.search_professionals(1::smallint, (select id from public.service_categories where slug = 'cerrajeria'))
                where id = '00000000-0000-0000-0000-0000000000f2'), 0, 'cerrajería: sin antecedentes no aparece en la búsqueda');
select test.expect_error(format('select public.create_booking(%L, %s, %L, %L, %L)', '00000000-0000-0000-0000-0000000000f2',
  (select id from public.service_categories where slug = 'cerrajeria'), 'now', 'Me quedé fuera', 'Calle 5'), 'HMY_PRO_NOT_CLEARED');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000f2');
insert into public.professional_documents (professional_id, doc_type, storage_path)
values (auth.uid(), 'antecedentes', auth.uid() || '/felcc.jpg');
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_review_document((select id from public.professional_documents
  where professional_id = '00000000-0000-0000-0000-0000000000f2' and doc_type = 'antecedentes'), 'accepted');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000f1');
select test.eq(public.count_ya_available((select id from public.service_categories where slug = 'cerrajeria'), 1::smallint), 1,
  'cerrajería: con antecedentes aceptados recibe pedidos');
select test.eq((select count(*)::int from public.search_professionals(1::smallint, (select id from public.service_categories where slug = 'cerrajeria'))
                where id = '00000000-0000-0000-0000-0000000000f2'), 1, 'cerrajería: con antecedentes aparece en la búsqueda');
insert into t_sp select 'cerr', public.create_ya_request((select id from public.service_categories where slug = 'cerrajeria'), 1::smallint,
  '', 'Calle 5', null, null, 'cash', null, null,
  array[(select id from public.service_problems where name = 'Me quedé fuera de casa')])::text;
select test.eq((public.booking_detail((select v::uuid from t_sp where k = 'cerr')) ->> 'safety_note') like '%carnet%', true,
  'cerrajería: la solicitud muestra la regla de seguridad');
select test.logout();

\o
\echo 'PRUEBAS DE PROBLEMAS POR CATEGORÍA PASARON'
