-- Pedidos vencidos (0046): nadie acepta ni cotiza tarde, y la app vence los
-- pedidos de quien la abre. Cuentas propias (…9a6000…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a60001', 'vence-c@test.bo', '{"full_name": "Cliente Vence"}'),
  ('00000000-0000-0000-0000-000009a60002', 'vence-p@test.bo', '{"full_name": "Profesional Vence"}'),
  ('00000000-0000-0000-0000-000009a60003', 'vence-x@test.bo', '{"full_name": "Otro Cliente Vence"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status)
values ('00000000-0000-0000-0000-000009a60002', 'Profesional Vence', 1, 1, 'approved');

insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             response_deadline, finished_at) values
  -- Pedido directo al profesional, vencido hace 10 minutos.
  ('00000000-0000-0000-0000-000009a6b001', '00000000-0000-0000-0000-000009a60001', '00000000-0000-0000-0000-000009a60002',
   1, 1, 'now', 'Revisar el enchufe', 'requested', now() - interval '10 minutes', null),
  -- Pedido ¡Ya! sin profesional, vencido, con una oferta pendiente.
  ('00000000-0000-0000-0000-000009a6b002', '00000000-0000-0000-0000-000009a60001', null,
   1, 1, 'now', 'Destapar el lavamanos', 'awaiting_response', now() - interval '1 minute', null),
  -- De otro cliente, también vencido: el primer cliente no lo toca.
  ('00000000-0000-0000-0000-000009a6b003', '00000000-0000-0000-0000-000009a60003', '00000000-0000-0000-0000-000009a60002',
   1, 1, 'now', 'Cambiar la chapa', 'requested', now() - interval '5 minutes', null),
  -- Todavía a tiempo.
  ('00000000-0000-0000-0000-000009a6b004', '00000000-0000-0000-0000-000009a60001', '00000000-0000-0000-0000-000009a60002',
   1, 1, 'now', 'Pintar una pared', 'requested', now() + interval '30 minutes', null),
  -- Trabajo terminado hace 73 horas, sin confirmar.
  ('00000000-0000-0000-0000-000009a6b005', '00000000-0000-0000-0000-000009a60003', '00000000-0000-0000-0000-000009a60002',
   1, 1, 'now', 'Arreglar la puerta', 'work_finished', null, now() - interval '73 hours');
-- Programado: todavía en plazo de respuesta, pero la hora de la cita ya pasó.
-- (Se inserta en dos pasos: la base no deja crear una cita en el pasado.)
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             scheduled_start, scheduled_end, response_deadline)
values ('00000000-0000-0000-0000-000009a6b006', '00000000-0000-0000-0000-000009a60003', '00000000-0000-0000-0000-000009a60002',
        1, 1, 'scheduled', 'Instalar una lámpara', 'requested', now() + interval '1 hour', now() + interval '3 hours',
        now() + interval '6 hours');
update public.bookings set scheduled_start = now() - interval '5 minutes', scheduled_end = now() + interval '2 hours'
where id = '00000000-0000-0000-0000-000009a6b006';
insert into public.booking_offers (booking_id, professional_id)
values ('00000000-0000-0000-0000-000009a6b002', '00000000-0000-0000-0000-000009a60002');

-- 1. Nadie acepta ni cotiza tarde.
select test.login('00000000-0000-0000-0000-000009a60002');
select test.expect_error($$select test.agree('00000000-0000-0000-0000-000009a6b001')$$, 'HMY_REQUEST_EXPIRED');
select test.expect_error($$select public.send_quote('00000000-0000-0000-0000-000009a6b001', 150)$$, 'HMY_REQUEST_EXPIRED');
select test.expect_error($$select test.agree('00000000-0000-0000-0000-000009a6b002')$$, 'HMY_REQUEST_EXPIRED');
select test.expect_error($$select test.agree('00000000-0000-0000-0000-000009a6b006')$$, 'HMY_REQUEST_EXPIRED');
select test.logout();
select test.eq((select professional_id from public.bookings where id = '00000000-0000-0000-0000-000009a6b002'), null::uuid,
               'vencido: el ¡Ya! no queda asignado a nadie');
select test.eq((select status from public.booking_offers where booking_id = '00000000-0000-0000-0000-000009a6b002'), 'pending',
               'vencido: la oferta no cambia por el intento');

-- 2. Sin sesión no se vence nada.
select test.login(null);
select test.expect_error('select public.expire_my_overdue_bookings()', 'permission denied');
select test.logout();

-- 3. El cliente abre la app: se vencen solo sus pedidos atrasados.
select test.login('00000000-0000-0000-0000-000009a60001');
select test.eq(public.expire_my_overdue_bookings(), 2, 'cliente: vence sus dos pedidos atrasados');
select test.eq(public.expire_my_overdue_bookings(), 0, 'cliente: repetir no hace nada');
select test.logout();
select test.eq((select string_agg(status::text, ',' order by id) from public.bookings
                where id::text like '00000000-0000-0000-0000-000009a6b00%' and id::text < '00000000-0000-0000-0000-000009a6b007'),
               'cancelled,cancelled,requested,requested,work_finished,requested',
               'cliente: el pedido a tiempo y los de otro cliente siguen igual');
select test.eq((select count(*)::int from public.bookings
                where id in ('00000000-0000-0000-0000-000009a6b001', '00000000-0000-0000-0000-000009a6b002')
                  and cancelled_by is null and cancelled_at is not null), 2,
               'cliente: lo canceló el sistema, no el cliente');
select test.eq((select cancel_reason from public.bookings where id = '00000000-0000-0000-0000-000009a6b001'),
               'Sin respuesta del profesional a tiempo', 'cliente: el motivo dice que no hubo respuesta');
select test.eq((select count(*)::int from public.booking_events
                where booking_id in ('00000000-0000-0000-0000-000009a6b001', '00000000-0000-0000-0000-000009a6b002')
                  and to_status = 'cancelled' and actor_id is null), 2, 'cliente: el historial dice "sistema"');
select test.eq((select status from public.booking_offers where booking_id = '00000000-0000-0000-0000-000009a6b002'), 'expired',
               'cliente: la oferta del ¡Ya! vencido caduca');
select test.eq((select count(*)::int from public.notifications
                where user_id = '00000000-0000-0000-0000-000009a60001' and kind = 'booking_status'
                  and data ->> 'booking_id' in ('00000000-0000-0000-0000-000009a6b001', '00000000-0000-0000-0000-000009a6b002')),
               2, 'cliente: recibe un aviso por cada pedido vencido');

-- 4. El profesional abre la app: vence lo suyo (el pedido del otro cliente y
-- el trabajo terminado hace 73 horas), no el que sigue a tiempo.
select test.login('00000000-0000-0000-0000-000009a60002');
select test.eq(public.expire_my_overdue_bookings(), 3, 'profesional: vence sus tres pendientes atrasados (uno por la hora de la cita)');
select test.logout();
select test.eq((select string_agg(status::text, ',' order by id) from public.bookings
                where id::text like '00000000-0000-0000-0000-000009a6b00%' and id::text < '00000000-0000-0000-0000-000009a6b007'),
               'cancelled,cancelled,cancelled,requested,completed,cancelled',
               'profesional: el trabajo de hace 73 horas queda confirmado y el pedido a tiempo sigue');

-- 5. La limpieza programada usa el mismo plazo.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             scheduled_start, scheduled_end, response_deadline)
values ('00000000-0000-0000-0000-000009a6b007', '00000000-0000-0000-0000-000009a60003', '00000000-0000-0000-0000-000009a60002',
        1, 1, 'scheduled', 'Revisar el calefón', 'requested', now() + interval '1 hour', now() + interval '3 hours',
        now() + interval '6 hours');
update public.bookings set scheduled_start = now() - interval '1 minute' where id = '00000000-0000-0000-0000-000009a6b007';
select public.run_booking_housekeeping();
select test.eq((select status::text from public.bookings where id = '00000000-0000-0000-0000-000009a6b007'), 'cancelled',
               'limpieza: un programado cuya hora ya pasó se cancela');

-- 6. Solo la app la usa; el guardián no se llama de afuera.
select test.eq(has_function_privilege('authenticated', 'public.hmy_booking_deadline_guard()', 'execute'), false,
               'guardián: nadie lo llama directo');
select test.eq(has_function_privilege('anon', 'public.expire_my_overdue_bookings()', 'execute'), false,
               'vencer: sin sesión, no');
\o
\echo 'PRUEBAS DE PEDIDOS VENCIDOS PASARON'
