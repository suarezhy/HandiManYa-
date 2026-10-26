-- Profesional o cliente suspendido (0047): sus pedidos que no empezaron se
-- cancelan, y un profesional no aprobado no acepta, no sale ni ve direcciones.
-- Cuentas propias (…9a7000…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a70001', 'susp-c@test.bo', '{"full_name": "Cliente Susp"}'),
  ('00000000-0000-0000-0000-000009a70002', 'susp-p@test.bo', '{"full_name": "Profesional Susp"}'),
  ('00000000-0000-0000-0000-000009a70003', 'susp-q@test.bo', '{"full_name": "Otro Profesional"}'),
  ('00000000-0000-0000-0000-000009a70004', 'susp-a@test.bo', '{"full_name": "Admin Susp"}'),
  ('00000000-0000-0000-0000-000009a70005', 'susp-r@test.bo', '{"full_name": "Profesional Reverifica"}'),
  ('00000000-0000-0000-0000-000009a70006', 'susp-x@test.bo', '{"full_name": "Cliente Problema"}'),
  ('00000000-0000-0000-0000-000009a70007', 'susp-y@test.bo', '{"full_name": "Cliente Foco"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a70004', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status) values
  ('00000000-0000-0000-0000-000009a70002', 'Profesional Susp', 1, 1, 'approved'),
  ('00000000-0000-0000-0000-000009a70003', 'Otro Profesional', 1, 1, 'approved'),
  ('00000000-0000-0000-0000-000009a70005', 'Profesional Reverifica', 1, 1, 'approved');

-- Pedidos del profesional P (…002) en cada estado, uno de otro profesional y
-- un ¡Ya! con oferta pendiente para P.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             response_deadline) values
  ('00000000-0000-0000-0000-000009a7b001', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Revisar el enchufe', 'requested', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-000009a7b002', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Cambiar la ducha', 'quote_sent', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-000009a7b003', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Pintar una pared', 'confirmed', null),
  ('00000000-0000-0000-0000-000009a7b004', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Arreglar la puerta', 'on_the_way', null),
  ('00000000-0000-0000-0000-000009a7b005', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Destapar el lavamanos', 'in_progress', null),
  ('00000000-0000-0000-0000-000009a7b006', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70003',
   1, 1, 'now', 'Cambiar la chapa', 'requested', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-000009a7b007', '00000000-0000-0000-0000-000009a70001', null,
   1, 1, 'now', 'Revisar el calefón', 'awaiting_response', now() + interval '10 minutes');
insert into public.booking_offers (booking_id, professional_id) values
  ('00000000-0000-0000-0000-000009a7b007', '00000000-0000-0000-0000-000009a70002'),
  ('00000000-0000-0000-0000-000009a7b007', '00000000-0000-0000-0000-000009a70003');
insert into public.booking_addresses (booking_id, address_line, latitude, longitude) values
  ('00000000-0000-0000-0000-000009a7b003', 'Calle Prueba 1', -16.5, -68.1),
  ('00000000-0000-0000-0000-000009a7b005', 'Calle Prueba 2', -16.5, -68.1);

-- Antes de suspender, el profesional ve la dirección de su pedido confirmado.
select test.login('00000000-0000-0000-0000-000009a70002');
select test.eq(public.can_see_booking_address('00000000-0000-0000-0000-000009a7b003'), true,
               'activo: ve la dirección del pedido confirmado');
select test.logout();

-- 1. El equipo suspende a P.
select test.login('00000000-0000-0000-0000-000009a70004');
select public.admin_set_suspension('00000000-0000-0000-0000-000009a70002', true, 'Reporte de seguridad');
select test.logout();

select test.eq((select string_agg(status::text, ',' order by id) from public.bookings
                where id::text like '00000000-0000-0000-0000-000009a7b00%'),
               'cancelled,cancelled,cancelled,cancelled,in_progress,requested,awaiting_response',
               'suspendido: lo que no empezó se cancela; el trabajo empezado, el de otro y el ¡Ya! siguen');
select test.eq((select string_agg(status, ',' order by professional_id) from public.booking_offers
                where booking_id = '00000000-0000-0000-0000-000009a7b007'),
               'expired,pending', 'suspendido: su oferta ¡Ya! se cierra; la del otro profesional sigue');
select test.eq((select count(*)::int from public.notifications
                where user_id = '00000000-0000-0000-0000-000009a70001' and kind = 'booking_status'
                  and body like 'El profesional ya no está disponible%'), 4,
               'cliente: un aviso por cada pedido cancelado, para pedir a otro');
select test.eq((select count(*)::int from public.notifications
                where user_id = '00000000-0000-0000-0000-000009a70001' and body like '%seguridad%'), 0,
               'cliente: el aviso no dice el motivo de la suspensión');
select test.eq((select count(*)::int from public.bookings
                where id::text like '00000000-0000-0000-0000-000009a7b00%' and status = 'cancelled' and cancelled_by is not null), 0,
               'suspendido: la cancelación la hace el sistema, no el cliente');

-- 2. Un pedido que se le cuele (por ejemplo, creado justo antes) no avanza.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             response_deadline) values
  ('00000000-0000-0000-0000-000009a7b008', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Instalar una lámpara', 'requested', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-000009a7b009', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
   1, 1, 'now', 'Revisar el techo', 'confirmed', null);
insert into public.booking_addresses (booking_id, address_line, latitude, longitude)
values ('00000000-0000-0000-0000-000009a7b009', 'Calle Prueba 3', -16.5, -68.1);
select test.login('00000000-0000-0000-0000-000009a70002');
select test.expect_error($$select public.accept_booking('00000000-0000-0000-0000-000009a7b008')$$, 'HMY_PROFESSIONAL_NOT_APPROVED');
select test.expect_error($$select public.send_quote('00000000-0000-0000-0000-000009a7b008', 150)$$, 'HMY_PROFESSIONAL_NOT_APPROVED');
select test.expect_error($$select public.update_job_progress('00000000-0000-0000-0000-000009a7b009', 'on_the_way')$$,
                         'HMY_PROFESSIONAL_NOT_APPROVED');
select test.eq(public.can_see_booking_address('00000000-0000-0000-0000-000009a7b009'), false,
               'suspendido: no ve la dirección de un pedido que no empezó');
select test.eq((select count(*)::int from public.booking_addresses where booking_id = '00000000-0000-0000-0000-000009a7b009'), 0,
               'suspendido: la tabla de direcciones tampoco se la muestra');
-- El trabajo que ya empezó se puede terminar (si no, quedaría trabado).
select test.eq(public.can_see_booking_address('00000000-0000-0000-0000-000009a7b005'), true,
               'suspendido: ya en el lugar, el trabajo empezado conserva la dirección');
select test.eq(public.update_job_progress('00000000-0000-0000-0000-000009a7b005', 'work_finished')::text, 'work_finished',
               'suspendido: puede terminar el trabajo que ya empezó');
select test.logout();

-- El cliente tampoco puede confirmar con él una cotización.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             quote_amount, response_deadline)
values ('00000000-0000-0000-0000-000009a7b013', '00000000-0000-0000-0000-000009a70001', '00000000-0000-0000-0000-000009a70002',
        1, 1, 'now', 'Cambiar el grifo', 'quote_sent', 100, now() + interval '1 hour');
select test.login('00000000-0000-0000-0000-000009a70001');
select test.expect_error($$select public.respond_quote('00000000-0000-0000-0000-000009a7b013', true)$$,
                         'HMY_PROFESSIONAL_NOT_APPROVED');
select test.eq(public.respond_quote('00000000-0000-0000-0000-000009a7b013', false)::text, 'cancelled',
               'cliente: sí puede rechazar la cotización');
select test.logout();

-- 3. Levantar la suspensión no revive pedidos cancelados.
select test.login('00000000-0000-0000-0000-000009a70004');
select public.admin_set_suspension('00000000-0000-0000-0000-000009a70002', false);
select test.logout();
select test.eq((select status::text from public.bookings where id = '00000000-0000-0000-0000-000009a7b001'), 'cancelled',
               'reactivado: lo cancelado sigue cancelado');
select test.login('00000000-0000-0000-0000-000009a70002');
select test.eq(public.can_see_booking_address('00000000-0000-0000-0000-000009a7b009'), true,
               'reactivado: vuelve a ver la dirección de su pedido confirmado');
select test.logout();

-- 4. Pedir que se verifique de nuevo también corta sus pedidos sin empezar.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status)
values ('00000000-0000-0000-0000-000009a7b010', '00000000-0000-0000-0000-000009a70007', '00000000-0000-0000-0000-000009a70005',
        1, 1, 'now', 'Cambiar un foco', 'confirmed');
select test.login('00000000-0000-0000-0000-000009a70004');
select public.review_professional_application('00000000-0000-0000-0000-000009a70005', 'reverification_required', 'Carnet vencido');
select test.logout();
select test.eq((select status::text from public.bookings where id = '00000000-0000-0000-0000-000009a7b010'), 'cancelled',
               'reverificar: el pedido confirmado se cancela');

-- 5. Un cliente suspendido: sus pedidos sin empezar se cancelan y el
-- profesional recibe el aviso.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             response_deadline) values
  ('00000000-0000-0000-0000-000009a7b011', '00000000-0000-0000-0000-000009a70006', '00000000-0000-0000-0000-000009a70003',
   1, 1, 'now', 'Revisar la cocina', 'confirmed', null),
  ('00000000-0000-0000-0000-000009a7b012', '00000000-0000-0000-0000-000009a70006', null,
   1, 1, 'now', 'Revisar el baño', 'awaiting_response', now() + interval '10 minutes');
select test.login('00000000-0000-0000-0000-000009a70004');
select public.admin_set_suspension('00000000-0000-0000-0000-000009a70006', true, 'Acoso');
select test.logout();
select test.eq((select string_agg(status::text, ',' order by id) from public.bookings
                where id in ('00000000-0000-0000-0000-000009a7b011', '00000000-0000-0000-0000-000009a7b012')),
               'cancelled,cancelled', 'cliente suspendido: sus pedidos sin empezar se cancelan');
select test.eq((select count(*)::int from public.notifications
                where user_id = '00000000-0000-0000-0000-000009a70003'
                  and body = 'La cuenta del cliente no está activa. Cancelamos esta solicitud.'), 1,
               'cliente suspendido: el profesional recibe el aviso, sin el motivo');
select test.eq((select status::text from public.bookings where id = '00000000-0000-0000-0000-000009a7b006'), 'requested',
               'cliente suspendido: los pedidos de otros clientes no cambian');

-- 6. Solo el servidor las usa.
select test.eq(has_function_privilege('authenticated', 'public.hmy_cancel_unstarted_bookings(uuid, text)', 'execute'), false,
               'cancelar pedidos: nadie la llama directo');
select test.eq(has_function_privilege('authenticated', 'public.hmy_professional_active(uuid)', 'execute'), false,
               'profesional activo: nadie la llama directo');
select test.eq(has_function_privilege('authenticated', 'public.hmy_booking_pro_active_guard()', 'execute'), false,
               'guardián: nadie lo llama directo');
\o
\echo 'PRUEBAS DE PROFESIONAL SUSPENDIDO PASARON'
