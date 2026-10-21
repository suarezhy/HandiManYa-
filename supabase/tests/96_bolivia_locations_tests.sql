-- Pruebas de cobertura nacional: municipios de los 9 departamentos y
-- emparejamiento fuera de las tres ciudades grandes. Corre después de 95.
\set ON_ERROR_STOP 1
\o /dev/null

-- Catálogo completo y activo.
select test.eq((select count(*)::int from public.cities where is_active), 339, 'Bolivia: 339 municipios activos');
select test.eq((select count(distinct department_id)::int from public.cities where is_active), 9, 'Bolivia: los 9 departamentos');
select test.eq((select count(*)::int from public.cities where province is null or latitude is null or longitude is null), 0,
               'Bolivia: todos con provincia y coordenada de referencia');
select test.eq((select string_agg(n::text, ',' order by d) from (
                  select department_id d, count(*) n from public.cities group by 1) x),
               '29,87,47,35,40,11,56,19,15', 'Bolivia: municipios por departamento (INE)');
select test.eq((select count(*)::int from public.cities
                where slug in ('santa-cruz', 'cochabamba', 'la-paz') and id in (1, 2, 3)), 3,
               'Bolivia: las ciudades que ya existían conservan su id');
select test.eq((select count(*)::int from public.cities c join public.departments d on d.id = c.department_id
                where (c.slug, d.name) in (('uyuni-pt', 'Potosí'), ('riberalta-be', 'Beni'), ('copacabana-lp', 'La Paz'),
                                           ('cobija', 'Pando'), ('camiri-sc', 'Santa Cruz'), ('yacuiba-tj', 'Tarija'),
                                           ('sucre', 'Chuquisaca'), ('oruro', 'Oruro'), ('trinidad', 'Beni'))), 9,
               'Bolivia: pueblos y capitales en su departamento');
select test.eq((select count(*)::int from public.cities where public.hmy_valid_point(latitude, longitude)), 339,
               'Bolivia: todas las coordenadas están dentro de Bolivia');

-- Una clienta de Uyuni se registra con su municipio.
insert into auth.users (id, email, raw_user_meta_data)
select '00000000-0000-0000-0000-0000000096c1', 'uyuni-c@test.bo',
       jsonb_build_object('full_name', 'Rosa Mamani', 'city_id', (select id from public.cities where slug = 'uyuni-pt')::text);
select test.eq((select c.slug from public.profiles p join public.cities c on c.id = p.city_id
                where p.id = '00000000-0000-0000-0000-0000000096c1'), 'uyuni-pt', 'registro: municipio fuera de las tres ciudades');

-- Profesionales de limpieza (categoría 3): uno en Uyuni sin GPS y uno en Warnes con base y radio.
insert into auth.users (id, email, raw_user_meta_data)
select v.id::uuid, v.email, jsonb_build_object('full_name', v.name, 'city_id', (select id from public.cities where slug = v.slug)::text)
from (values ('00000000-0000-0000-0000-0000000096a1', 'uyuni-p@test.bo', 'Juan Quispe', 'uyuni-pt'),
             ('00000000-0000-0000-0000-0000000096a2', 'warnes-p@test.bo', 'Luis Vaca', 'warnes-sc')) v(id, email, name, slug);
do $$
declare v uuid;
begin
  foreach v in array array['00000000-0000-0000-0000-0000000096a1','00000000-0000-0000-0000-0000000096a2']::uuid[] loop
    perform test.login(v);
    perform public.start_professional_application();
    update public.professional_profiles set primary_category_id = 3 where user_id = v;
    insert into public.professional_documents (professional_id, doc_type, storage_path) values (v, 'ci_anverso', v || '/ci.jpg');
    perform public.submit_professional_application();
    perform test.logout();
    perform test.login('00000000-0000-0000-0000-00000000000a');
    perform test.accept_id(v);
    perform public.review_professional_application(v, 'approved');
    perform public.admin_wallet_adjustment(v, 50, 'Saldo de prueba', 'seed-' || v);
    perform test.logout();
    perform test.login(v);
    perform public.set_availability(true);
    perform test.logout();
  end loop;
end $$;
select test.login('00000000-0000-0000-0000-0000000096a2');
select public.set_service_location(-17.5100, -63.1650, 35);
select test.logout();

-- Sin GPS: el municipio decide.
select test.eq(exists (select 1 from public.ya_eligible_professionals(3, (select id from public.cities where slug = 'uyuni-pt'), null,
                                                                       '00000000-0000-0000-0000-0000000096c1') x
                       where x = '00000000-0000-0000-0000-0000000096a1'), true, '¡Ya! sin GPS: el profesional de Uyuni recibe el pedido de Uyuni');
select test.eq(exists (select 1 from public.ya_eligible_professionals(3, (select id from public.cities where slug = 'tupiza-pt'), null,
                                                                       '00000000-0000-0000-0000-0000000096c1') x
                       where x = '00000000-0000-0000-0000-0000000096a1'), false, '¡Ya! sin GPS: no le llega un pedido de Tupiza');

-- Con GPS: la distancia decide, aunque esté registrado en otro municipio.
select test.eq(exists (select 1 from public.ya_eligible_professionals(3, 1::smallint, null, '00000000-0000-0000-0000-0000000096c1',
                                                                       -17.70, -63.16) x
                       where x = '00000000-0000-0000-0000-0000000096a2'), true, '¡Ya! con GPS: el de Warnes atiende el norte de Santa Cruz (en su radio)');
select test.eq(exists (select 1 from public.ya_eligible_professionals(3, 1::smallint, null, '00000000-0000-0000-0000-0000000096c1',
                                                                       -17.95, -63.20) x
                       where x = '00000000-0000-0000-0000-0000000096a2'), false, '¡Ya! con GPS: fuera de su radio no le llega');
select test.eq(exists (select 1 from public.ya_eligible_professionals(3, (select id from public.cities where slug = 'uyuni-pt'), null,
                                                                       '00000000-0000-0000-0000-0000000096c1', -20.46, -66.82) x
                       where x = '00000000-0000-0000-0000-0000000096a1'), true, '¡Ya! con GPS: quien no puso base sigue recibiendo los de su municipio');

-- Pedido real desde Uyuni con GPS.
select test.login('00000000-0000-0000-0000-0000000096c1');
select test.eq(public.count_ya_available(3, (select id from public.cities where slug = 'uyuni-pt'), null, -20.46, -66.82) >= 1, true,
               '¡Ya!: hay profesionales disponibles en Uyuni');
create temp table t_bo (k text primary key, v uuid);
grant all on t_bo to authenticated;
insert into t_bo select 'b', public.create_ya_request(3, (select id from public.cities where slug = 'uyuni-pt'), 'Limpieza de la casa',
                                                    'Av. Ferroviaria 10, Uyuni', null, null, 'cash', -20.4600, -66.8200);
select test.eq((select c.slug from public.bookings b join public.cities c on c.id = b.city_id where b.id = (select v from t_bo)), 'uyuni-pt',
               '¡Ya!: el pedido queda en Uyuni');

-- Búsqueda por municipio: los registrados ahí y quien lo cubre con su radio.
select test.eq(exists (select 1 from public.search_professionals(p_city_id => (select id from public.cities where slug = 'uyuni-pt')) s
                       where s.id = '00000000-0000-0000-0000-0000000096a1'), true, 'búsqueda: Uyuni muestra a su profesional');
select test.eq(exists (select 1 from public.search_professionals(p_city_id => 1::smallint) s
                       where s.id = '00000000-0000-0000-0000-0000000096a2'), true, 'búsqueda: Santa Cruz muestra al de Warnes que la cubre');
select test.eq(exists (select 1 from public.search_professionals(p_city_id => (select id from public.cities where slug = 'cobija')) s
                       where s.id = '00000000-0000-0000-0000-0000000096a2'), false, 'búsqueda: Cobija no muestra al de Warnes');
select test.logout();

\o
\echo 'PRUEBAS DE COBERTURA NACIONAL PASARON'
