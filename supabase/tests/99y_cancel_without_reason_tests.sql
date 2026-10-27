-- Cancelar sin explicar el motivo (0056). Cuentas propias (…9a9600…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a96001', 'canc-c@test.bo', '{"full_name": "Cliente Cancela"}'),
  ('00000000-0000-0000-0000-000009a96002', 'canc-p@test.bo', '{"full_name": "Profesional Cancela"}'),
  ('00000000-0000-0000-0000-000009a96003', 'canc-x@test.bo', '{"full_name": "Otra Persona"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status) values
  ('00000000-0000-0000-0000-000009a96002', 'Profesional Cancela', 1, 1, 'approved');

-- Un pedido en cada estado: directo sin aceptar, ¡Ya! pendiente, programado
-- pendiente, aceptado, en camino y uno para que cancele el profesional.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             response_deadline, scheduled_start, scheduled_end) values
  ('00000000-0000-0000-0000-000009a96b01', '00000000-0000-0000-0000-000009a96001', '00000000-0000-0000-0000-000009a96002',
   1, 1, 'now', 'Revisar el enchufe', 'requested', now() + interval '1 hour', null, null),
  ('00000000-0000-0000-0000-000009a96b02', '00000000-0000-0000-0000-000009a96001', null,
   1, 1, 'now', 'Revisar el calefón', 'awaiting_response', now() + interval '10 minutes', null, null),
  ('00000000-0000-0000-0000-000009a96b03', '00000000-0000-0000-0000-000009a96001', null,
   1, 1, 'scheduled', 'Instalar una lámpara', 'awaiting_response', now() + interval '2 days',
   now() + interval '2 days 30 minutes', now() + interval '2 days 150 minutes'),
  ('00000000-0000-0000-0000-000009a96b04', '00000000-0000-0000-0000-000009a96001', '00000000-0000-0000-0000-000009a96002',
   1, 1, 'now', 'Pintar una pared', 'confirmed', null, null, null),
  ('00000000-0000-0000-0000-000009a96b05', '00000000-0000-0000-0000-000009a96001', '00000000-0000-0000-0000-000009a96002',
   1, 1, 'now', 'Arreglar la puerta', 'on_the_way', null, null, null),
  ('00000000-0000-0000-0000-000009a96b06', '00000000-0000-0000-0000-000009a96001', '00000000-0000-0000-0000-000009a96002',
   1, 1, 'now', 'Cambiar la ducha', 'confirmed', null, null, null);
insert into public.booking_offers (booking_id, professional_id) values
  ('00000000-0000-0000-0000-000009a96b02', '00000000-0000-0000-0000-000009a96002'),
  ('00000000-0000-0000-0000-000009a96b03', '00000000-0000-0000-0000-000009a96002');

-- ---------------------------------------------------------------------------
-- El cliente cancela sin escribir nada, en cada estado que lo permite.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a96001');
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b01', null)::text, 'cancelled',
               'sin aceptar: se cancela sin motivo');
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b02', '')::text, 'cancelled',
               '¡Ya! pendiente: se cancela sin motivo');
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b03', '   ')::text, 'cancelled',
               'programado pendiente: se cancela sin motivo');
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b04', null)::text, 'cancelled',
               'aceptado: se cancela sin motivo');
select test.eq((select cancel_reason from public.bookings where id = '00000000-0000-0000-0000-000009a96b04'),
               'Cancelada por el cliente', 'queda anotado quién canceló');
select test.eq((select count(*)::int from public.booking_events where booking_id = '00000000-0000-0000-0000-000009a96b04'
                and to_status = 'cancelled'), 1, 'un registro de la cancelación');

-- Doble toque: no se repite ni crea otro registro.
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b04', null)::text, 'cancelled',
               'cancelar otra vez no da error');
select test.eq((select count(*)::int from public.booking_events where booking_id = '00000000-0000-0000-0000-000009a96b04'
                and to_status = 'cancelled'), 1, 'cancelar otra vez no crea otro registro');

-- En camino: la política no cambia, el cliente no cancela desde la app.
select test.expect_error($$select public.cancel_booking('00000000-0000-0000-0000-000009a96b05', null)$$,
                         'HMY_INVALID_TRANSITION');
select test.eq((select status::text from public.bookings where id = '00000000-0000-0000-0000-000009a96b05'), 'on_the_way',
               'en camino: sigue igual');
select test.eq((select count(*)::int from public.my_bookings('customer')
                where id in ('00000000-0000-0000-0000-000009a96b01', '00000000-0000-0000-0000-000009a96b03',
                             '00000000-0000-0000-0000-000009a96b04') and status = 'cancelled'), 3,
               'las canceladas siguen en el historial del cliente');
select test.logout();

select test.eq((select count(*)::int from public.booking_offers where booking_id in
                  ('00000000-0000-0000-0000-000009a96b02', '00000000-0000-0000-0000-000009a96b03') and status = 'pending'), 0,
               'al cancelar las pendientes no queda ninguna oferta abierta');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009a96002'
                and kind = 'booking_status' and body = 'Cancelada por el cliente'
                and data ->> 'booking_id' = '00000000-0000-0000-0000-000009a96b04'), 1,
               'el profesional recibe el aviso de la cancelación');

-- Nadie más cancela pedidos ajenos.
select test.login('00000000-0000-0000-0000-000009a96003');
select test.expect_error($$select public.cancel_booking('00000000-0000-0000-0000-000009a96b06', null)$$, 'HMY_FORBIDDEN');
select test.logout();

-- El profesional sigue dando un motivo.
select test.login('00000000-0000-0000-0000-000009a96002');
select test.expect_error($$select public.cancel_booking('00000000-0000-0000-0000-000009a96b06', '')$$, 'HMY_REASON_REQUIRED');
select test.eq(public.cancel_booking('00000000-0000-0000-0000-000009a96b06', 'Se me pinchó la llanta')::text, 'cancelled',
               'el profesional cancela con motivo');
select test.logout();

\o
\echo 'PRUEBAS DE CANCELAR SIN MOTIVO PASARON'
