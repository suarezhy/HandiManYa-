-- Pruebas de ubicación (GPS), distancia, privacidad y fotos. Corre después de 20_ya_dispatch_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000e1', 'lim1@test.bo', '{"full_name":"Ana Rojas","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000e2', 'lim2@test.bo', '{"full_name":"Eva Paz","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000e3', 'lim3@test.bo', '{"full_name":"Iris Soto","city_id":"1"}');

-- Tres profesionales de limpieza (categoría 3) aprobados y disponibles en Santa Cruz.
do $$
declare v uuid;
begin
  foreach v in array array['00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-0000000000e3']::uuid[] loop
    perform test.login(v);
    perform public.start_professional_application();
    update public.professional_profiles set primary_category_id = 3 where user_id = v;
    insert into public.professional_documents (professional_id, doc_type, storage_path) values (v, 'ci_anverso', v || '/ci.jpg');
    perform public.submit_professional_application();
    perform test.logout();
    perform test.login('00000000-0000-0000-0000-00000000000a');
    perform public.review_professional_application(v, 'approved');
    perform public.admin_wallet_adjustment(v, 50, 'Saldo de prueba', 'seed-' || v);
    perform test.logout();
    perform test.login(v);
    perform public.set_availability(true);
    perform test.logout();
  end loop;
end $$;

-- e1 vive cerca de Equipetrol (radio 5 km); e2 a ~13 km (radio 5 km); e3 no puso ubicación.
select test.login('00000000-0000-0000-0000-0000000000e1');
select public.set_service_location(-17.7690, -63.1960, 5);
select test.expect_error($$select public.set_service_location(40.0, -3.7, 5)$$, 'HMY_INVALID_LOCATION');
select test.expect_error($$select public.set_service_location(-17.7, -63.1, 80)$$, 'HMY_INVALID_RADIUS');
select test.eq((select count(*)::int from public.professional_locations), 1, 'ubicación: el profesional ve su propia base');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000e2');
select public.set_service_location(-17.8500, -63.1000, 5);
select test.eq((select count(*)::int from public.professional_locations), 1, 'ubicación: nadie ve la base de otro profesional');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq((select count(*)::int from public.professional_locations), 0, 'ubicación: el cliente no ve bases de profesionales');

-- Pedido con GPS cerca de Equipetrol.
select test.eq(public.count_ya_available(3, 1::smallint, null, -17.7760, -63.1950), 2, 'distancia: cuenta solo a quien está en su radio (y a quien no puso ubicación)');
select test.expect_error($$select public.create_ya_request(3, 1::smallint, 'Limpieza profunda', 'Calle 1', null, null, 'cash', 48.85, 2.35)$$, 'HMY_INVALID_LOCATION');
create temp table t_loc (k text primary key, v uuid);
grant all on t_loc to authenticated;
insert into t_loc select 'b1', public.create_ya_request(3, 1::smallint, 'Limpieza profunda del departamento', 'Calle Los Pinos 123, Equipetrol', 'Edificio azul, piso 4', null, 'cash', -17.776123, -63.195456);
select test.eq((public.booking_detail((select v from t_loc)) ->> 'offers_sent')::int, 2, 'distancia: la oferta llega a e1 y e3, no a e2 (fuera de radio)');
select test.eq((select approx_latitude from public.bookings where id = (select v from t_loc)), -17.78::numeric, 'privacidad: el punto público está redondeado (~1 km)');

-- Fotos del problema
select test.expect_error(format($$insert into public.booking_photos (booking_id, kind, storage_path, uploaded_by) values (%L, 'problem', 'otra/a.jpg', auth.uid())$$, (select v from t_loc)), 'HMY_INVALID_PATH');
insert into public.booking_photos (booking_id, kind, storage_path, uploaded_by)
select v, 'problem', v || '/p' || g || '.jpg', auth.uid() from t_loc, generate_series(1, 5) g;
select test.expect_error(format($$insert into public.booking_photos (booking_id, kind, storage_path, uploaded_by) values (%L, 'problem', %L, auth.uid())$$, (select v from t_loc), (select v from t_loc) || '/p6.jpg'), 'HMY_TOO_MANY_PHOTOS');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000e1');
do $$ begin
  perform test.eq((select count(*)::int from public.booking_photos where booking_id = (select v from t_loc)), 5, 'fotos: el profesional con la oferta ve las fotos del problema');
  perform test.eq((select count(*)::int from public.booking_addresses), 0, 'privacidad: con GPS tampoco ve la dirección antes de aceptar');
  perform test.eq((public.booking_detail((select v from t_loc)) -> 'address') is null or (public.booking_detail((select v from t_loc)) -> 'address') = 'null'::jsonb, true, 'privacidad: el detalle no trae coordenadas exactas');
  perform test.eq((select distance_km from public.my_bookings('professional') where id = (select v from t_loc)) between 0 and 2, true, 'distancia: el profesional ve a cuántos km está (aprox.)');
end $$;
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000e2');
select test.eq((select count(*)::int from public.booking_photos where booking_id = (select v from t_loc)), 0, 'fotos: un profesional sin oferta no las ve');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000e1');
select public.claim_ya_request((select v from t_loc));
select test.eq((public.booking_detail((select v from t_loc)) -> 'address' ->> 'latitude')::numeric, -17.776123::numeric, 'privacidad: quien aceptó recibe el punto exacto');

-- Comprobante de recarga en la carpeta propia
select test.expect_error(format('select public.request_topup(50, %s, %L, %L)', (select min(id) from public.topup_methods), 'ABC', '00000000-0000-0000-0000-0000000000e2/r.jpg'), 'HMY_INVALID_PATH');
select test.eq((select public.request_topup(50, (select min(id) from public.topup_methods), 'ABC', '00000000-0000-0000-0000-0000000000e1/r.jpg')) > 0, true, 'recarga: acepta comprobante en su propia carpeta');
select test.logout();

\o
\echo 'PRUEBAS DE UBICACIÓN Y FOTOS PASARON'
