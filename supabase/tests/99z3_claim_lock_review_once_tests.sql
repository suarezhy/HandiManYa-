-- 0060: calificar dos veces da HMY_ALREADY_RATED; aceptar una programada que se
-- cruza con otra da HMY_SLOT_TAKEN. Cuentas propias (…9a92e…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a92e01', 'z3-c@test.bo', '{"full_name": "Cliente Z3"}'),
  ('00000000-0000-0000-0000-000009a92e02', 'z3-p@test.bo', '{"full_name": "Profesional Z3"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a92e02', 'Z3', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'oruro'), 'approved', true);

select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a92e02', 50, 'Saldo de prueba', 'seed-z3');
select test.logout();

set session_replication_role = replica;
-- Un trabajo terminado y confirmado, para calificar.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status) values
  ('00000000-0000-0000-0000-000009a92b01', '00000000-0000-0000-0000-000009a92e01', '00000000-0000-0000-0000-000009a92e02',
   (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'oruro'),
   'now', 'Trabajo para calificar', 'completed');
-- Dos programadas a la misma hora, con oferta al profesional.
insert into public.bookings (id, customer_id, category_id, city_id, mode, description, status, response_deadline,
                             scheduled_start, scheduled_end)
select ('00000000-0000-0000-0000-000009a92b0' || k)::uuid, '00000000-0000-0000-0000-000009a92e01',
       (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'oruro'),
       'scheduled', 'Programada a la misma hora ' || k, 'awaiting_response', now() + interval '1 day',
       date_trunc('hour', now()) + interval '2 days', date_trunc('hour', now()) + interval '2 days 2 hours'
from generate_series(2, 3) k;
insert into public.booking_offers (booking_id, professional_id)
select ('00000000-0000-0000-0000-000009a92b0' || k)::uuid, '00000000-0000-0000-0000-000009a92e02' from generate_series(2, 3) k;
set session_replication_role = origin;

select test.login('00000000-0000-0000-0000-000009a92e01');
select public.submit_review('00000000-0000-0000-0000-000009a92b01', 5, 'Muy bien');
select test.expect_error($$select public.submit_review('00000000-0000-0000-0000-000009a92b01', 4, 'Otra vez')$$,
                         'HMY_ALREADY_RATED');
select test.logout();
select test.eq((select count(*)::int from public.reviews where booking_id = '00000000-0000-0000-0000-000009a92b01'), 1,
               'una sola reseña por servicio');

select test.login('00000000-0000-0000-0000-000009a92e02');
select test.eq(test.agree('00000000-0000-0000-0000-000009a92b02')::text, 'confirmed',
               'acepta la primera programada');
select test.expect_error($$select test.agree('00000000-0000-0000-0000-000009a92b03')$$, 'HMY_SLOT_TAKEN');
select test.logout();

\o
\echo '0060 bloqueo al aceptar y una reseña por servicio: pruebas pasadas'
