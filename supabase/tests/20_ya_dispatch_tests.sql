-- Pruebas del pedido ¡Ya! (tipo Uber). Corre después de 10_schema_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'pro3@test.bo', '{"full_name":"Rosa Choque","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'pro4@test.bo', '{"full_name":"Luis Vargas","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000d3', 'pro5@test.bo', '{"full_name":"Mario Flores","city_id":"2"}');

-- Tres electricistas aprobados: dos en Santa Cruz, uno en Cochabamba.
do $$
declare v uuid;
begin
  foreach v in array array['00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-0000000000d3']::uuid[] loop
    perform test.login(v);
    perform public.start_professional_application();
    update public.professional_profiles set primary_category_id = 2 where user_id = v;
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

-- d2 solo atiende la Zona Norte de Santa Cruz.
insert into public.professional_zones (professional_id, zone_id)
select '00000000-0000-0000-0000-0000000000d2', id from public.service_zones where city_id = 1 and slug = 'norte';

select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq(public.count_ya_available(2, 1::smallint), 2, '¡Ya!: dos electricistas disponibles en Santa Cruz');
select test.eq(public.count_ya_available(2, 1::smallint, (select id from public.service_zones where city_id = 1 and slug = 'sur')), 1, '¡Ya!: filtra por zona');
select test.expect_error($$select public.create_ya_request(7, 1::smallint, 'Podar el jardín', 'Calle 1')$$, 'HMY_NO_PROFESSIONALS_AVAILABLE');
create temp table t_ya (k text primary key, v uuid);
grant all on t_ya to authenticated;
insert into t_ya select 'y1', public.create_ya_request(2, 1::smallint, 'Se quemó un tomacorriente y huele a quemado', 'Av. Alemana 500', 'Portón negro', (select id from public.service_zones where city_id = 1 and slug = 'norte'), 'qr');
select test.eq((select status::text from public.bookings where id = (select v from t_ya)), 'awaiting_response', '¡Ya!: queda esperando respuesta');
select test.eq((select (public.booking_detail((select v from t_ya)) ->> 'offers_sent')::int), 2, '¡Ya!: llega a los dos profesionales elegibles');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000d3');
select test.eq((select count(*)::int from public.bookings where id = (select v from t_ya)), 0, '¡Ya!: otra ciudad no recibe el pedido');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000d1');
do $$ begin
  perform test.eq((select count(*)::int from public.my_bookings('professional') where is_offer), 1, '¡Ya!: el profesional ve la oferta');
  perform test.eq((select count(*)::int from public.booking_addresses), 0, '¡Ya!: sin dirección exacta antes de aceptar');
  perform test.eq((public.booking_detail((select v from t_ya)) -> 'address') = 'null'::jsonb or (public.booking_detail((select v from t_ya)) -> 'address') is null, true, '¡Ya!: el detalle tampoco expone la dirección');
  perform test.eq(public.booking_detail((select v from t_ya)) ->> 'zone', 'Zona Norte', '¡Ya!: muestra solo la zona general');
end $$;
select test.eq(public.claim_ya_request((select v from t_ya))::text, 'confirmed', '¡Ya!: el primero que acepta se queda con el trabajo');
select test.eq((select count(*)::int from public.booking_addresses), 1, '¡Ya!: dirección visible para quien aceptó');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000d2');
select test.expect_error(format('select public.claim_ya_request(%L)', (select v from t_ya)), 'HMY_ALREADY_TAKEN|HMY_FORBIDDEN');
select test.eq((select count(*)::int from public.bookings where id = (select v from t_ya)), 0, '¡Ya!: quien no ganó deja de ver el pedido');
select test.logout();

do $$ begin
  perform test.eq((select status from public.booking_offers where professional_id = '00000000-0000-0000-0000-0000000000d2'), 'lost', '¡Ya!: la otra oferta se cierra');
  perform test.eq((select reserved from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000d1'), 15.00::numeric, '¡Ya!: se reserva la comisión completa al aceptar');
  perform test.eq((select count(*)::int from public.conversations where booking_id = (select v from t_ya)), 1, '¡Ya!: se abre el chat');
end $$;

-- Pedido que nadie acepta: vence y avisa al cliente.
select test.login('00000000-0000-0000-0000-0000000000c2');
insert into t_ya select 'y2', public.create_ya_request(2, 1::smallint, 'No tengo luz en la cocina', 'Calle 3');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000d2');
select public.decline_ya_offer((select v from t_ya where k = 'y2'));
select test.logout();
update public.bookings set response_deadline = now() - interval '1 second' where id = (select v from t_ya where k = 'y2');
select public.run_booking_housekeeping();
select test.eq((select status::text from public.bookings where id = (select v from t_ya where k = 'y2')), 'cancelled', '¡Ya!: vence si nadie acepta');
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v from t_ya where k = 'y2') and status = 'pending'), 0, '¡Ya!: no quedan ofertas abiertas');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-0000000000c2' and kind = 'booking_status'), 1, '¡Ya!: el cliente recibe aviso');

-- Lecturas de la app
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq((public.my_account() ->> 'professional_status'), 'not_started', 'mi cuenta: cliente sin postulación');
select test.eq((select count(*)::int from public.my_bookings('customer')) >= 1, true, 'mis solicitudes como cliente');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000d1');
select test.eq((public.pro_dashboard() ->> 'active')::int, 1, 'panel profesional: un trabajo activo');
select test.eq((public.pro_dashboard() ->> 'wallet_available')::numeric, 35.00::numeric, 'panel profesional: saldo disponible (50 − 15 reservados)');
select test.logout();

\o
\echo 'PRUEBAS ¡YA! PASARON'
