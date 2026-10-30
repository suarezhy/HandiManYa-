-- Solicitud programada sin profesional (0055): queda "Pendiente de profesional",
-- llega a los profesionales de la zona (también a los que se suman después) y el
-- primero que acepta se queda con ella. Cuentas propias (…9a9500…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a95001', 'prog-c@test.bo', '{"full_name": "Cliente Programa"}'),
  ('00000000-0000-0000-0000-000009a95002', 'prog-p@test.bo', '{"full_name": "Limpieza Uno"}'),
  ('00000000-0000-0000-0000-000009a95003', 'prog-q@test.bo', '{"full_name": "Limpieza Dos"}'),
  ('00000000-0000-0000-0000-000009a95004', 'prog-r@test.bo', '{"full_name": "Electricista Otro"}'),
  ('00000000-0000-0000-0000-000009a95005', 'prog-s@test.bo', '{"full_name": "Limpieza Tarde"}'),
  ('00000000-0000-0000-0000-000009a95006', 'prog-a@test.bo', '{"full_name": "Admin Programa"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a95006', 'admin');
-- P y Q hacen limpieza (3) en Cochabamba (2), sin estar disponibles ahora; R hace electricidad.
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available) values
  ('00000000-0000-0000-0000-000009a95002', 'Limpieza Uno', 3, 2, 'approved', false),
  ('00000000-0000-0000-0000-000009a95003', 'Limpieza Dos', 3, 2, 'approved', false),
  ('00000000-0000-0000-0000-000009a95004', 'Electricista Otro', 2, 2, 'approved', false);
select public.wallet_post(u, 'topup', 100, 0, 'test99x:' || u, null, null, 'Recarga')
from unnest(array['00000000-0000-0000-0000-000009a95002', '00000000-0000-0000-0000-000009a95003']::uuid[]) u;

create temp table t_prog (k text primary key, v uuid);
grant all on t_prog to authenticated;

-- ---------------------------------------------------------------------------
-- Fechas inválidas y quién puede pedir.
-- ---------------------------------------------------------------------------
select test.login(null);
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'Calle Prueba 1',
  now() + interval '2 days')$$, 'permission denied');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a95001');
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'Calle Prueba 1',
  now() - interval '1 hour')$$, 'HMY_INVALID_SCHEDULE');
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'Calle Prueba 1',
  now() + interval '10 minutes')$$, 'HMY_INVALID_SCHEDULE');
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'Calle Prueba 1',
  now() + interval '90 days')$$, 'HMY_INVALID_SCHEDULE');
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'Calle Prueba 1',
  now() + interval '2 days', 5)$$, 'HMY_INVALID_SCHEDULE');
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza', 'x',
  now() + interval '2 days')$$, 'HMY_ADDRESS_REQUIRED');

-- ---------------------------------------------------------------------------
-- Se guarda como pendiente, sin profesional, y llega a P y Q (no a R).
-- ---------------------------------------------------------------------------
insert into t_prog select 's1', public.create_scheduled_request(3, 2::smallint, 'Limpieza profunda del depto',
  'Calle Prueba 123, piso 2', date_trunc('hour', now()) + interval '2 days 10 hours', 180, 'Timbre 2B', null, 'cash');
select test.eq((select (status, mode, professional_id is null)::text from public.bookings where id = (select v from t_prog where k = 's1')),
               '(awaiting_response,scheduled,t)', 'pendiente de profesional: sin profesional asignado');
select test.eq((select scheduled_end - scheduled_start from public.bookings where id = (select v from t_prog where k = 's1')),
               interval '3 hours', 'guarda la duración');
select test.eq((select response_deadline = scheduled_start - interval '30 minutes' from public.bookings
                where id = (select v from t_prog where k = 's1')), true, 'se puede aceptar hasta 30 minutos antes');
select test.eq((select count(*)::int from public.my_bookings('customer') where id = (select v from t_prog where k = 's1')), 1,
               'el cliente la ve en sus solicitudes');
-- Doble toque: la misma solicitud otra vez no se crea.
select test.expect_error($$select public.create_scheduled_request(3, 2::smallint, 'Limpieza profunda del depto',
  'Calle Prueba 123, piso 2', date_trunc('hour', now()) + interval '2 days 11 hours', 120)$$, 'HMY_DUPLICATE_REQUEST');
select test.logout();

select test.eq((select array_agg(professional_id order by professional_id)::text from public.booking_offers
                where booking_id = (select v from t_prog where k = 's1') and professional_id::text like '00000000-0000-0000-0000-000009a95%'),
               '{00000000-0000-0000-0000-000009a95002,00000000-0000-0000-0000-000009a95003}',
               'llega a los dos de limpieza de la ciudad, aunque no estén disponibles ahora');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-000009a95002'
                and kind = 'booking_new' and data ->> 'booking_id' = (select v from t_prog where k = 's1')::text), 1,
               'P recibe el aviso de la solicitud programada');

-- ---------------------------------------------------------------------------
-- Un profesional que se suma después también la recibe.
-- ---------------------------------------------------------------------------
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available) values
  ('00000000-0000-0000-0000-000009a95005', 'Limpieza Tarde', 3, 2, 'submitted', false);
select test.eq((select count(*)::int from public.booking_offers where professional_id = '00000000-0000-0000-0000-000009a95005'), 0,
               'sin aprobar no recibe nada');
select test.login('00000000-0000-0000-0000-000009a95006');
select test.accept_id('00000000-0000-0000-0000-000009a95005');
select public.review_professional_application('00000000-0000-0000-0000-000009a95005', 'approved');
select test.logout();
select test.eq((select count(*)::int from public.booking_offers where professional_id = '00000000-0000-0000-0000-000009a95005'
                and booking_id = (select v from t_prog where k = 's1')), 1, 'al aprobarlo recibe la solicitud pendiente');
-- R agrega limpieza a sus servicios: también la recibe.
insert into public.professional_services (professional_id, category_id) values ('00000000-0000-0000-0000-000009a95004', 3);
select test.eq((select count(*)::int from public.booking_offers where professional_id = '00000000-0000-0000-0000-000009a95004'
                and booking_id = (select v from t_prog where k = 's1')), 1, 'al sumar el servicio recibe la solicitud pendiente');

-- ---------------------------------------------------------------------------
-- Antes de aceptar no ve la dirección; el primero que acepta se queda con ella.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a95002');
select test.eq((select count(*)::int from public.my_bookings('professional')
                where id = (select v from t_prog where k = 's1') and is_offer), 1, 'P la ve como oferta');
select test.eq(public.can_see_booking_address((select v from t_prog where k = 's1')), false, 'P no ve la dirección antes de aceptar');
select test.eq(test.agree((select v from t_prog where k = 's1'))::text, 'confirmed', 'P acepta y queda confirmada');
select test.eq(public.can_see_booking_address((select v from t_prog where k = 's1')), true, 'P ve la dirección después de aceptar');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a95003');
select test.expect_error($$select test.agree((select v from t_prog where k = 's1'))$$, 'HMY_ALREADY_TAKEN');
select test.eq(public.can_see_booking_address((select v from t_prog where k = 's1')), false, 'Q nunca ve la dirección');
select test.logout();

-- ---------------------------------------------------------------------------
-- P ya tiene ese horario: no puede aceptar otra que se cruza.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a95001');
insert into t_prog select 's2', public.create_scheduled_request(3, 2::smallint, 'Limpieza de ventanas',
  'Av. Prueba 456', date_trunc('hour', now()) + interval '2 days 11 hours', 60, null, null, 'qr');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a95002');
select test.expect_error($$select test.agree((select v from t_prog where k = 's2'))$$, 'HMY_SLOT_TAKEN');
select test.logout();

-- ---------------------------------------------------------------------------
-- El cliente cancela la pendiente; las ofertas se cierran.
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-000009a95001');
select public.cancel_booking((select v from t_prog where k = 's2'), 'Ya no la necesito');
select test.eq((select status::text from public.bookings where id = (select v from t_prog where k = 's2')), 'cancelled',
               'el cliente cancela la solicitud pendiente');
select test.logout();
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v from t_prog where k = 's2')
                and status = 'pending'), 0, 'al cancelar no queda ninguna oferta abierta');

-- Funciones internas: nadie de la app las llama.
select test.eq(has_function_privilege('authenticated', 'public._hmy_offer_scheduled(uuid)', 'execute'), false,
               'interna: avisar a profesionales');
select test.eq(has_function_privilege('authenticated', 'public._claim_ya_request_base(uuid)', 'execute'), false,
               'interna: aceptar sin revisar el horario');
select test.eq(has_function_privilege('authenticated',
  'public.hmy_scheduled_eligible_professionals(int, smallint, int, uuid, numeric, numeric)', 'execute'), false,
  'interna: lista de profesionales');

\o
\echo 'PRUEBAS DE SOLICITUDES PROGRAMADAS PASARON'
