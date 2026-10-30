-- 0063: "Identidad verificada" solo con verificación real; categorías Plata,
-- Oro y Diamante calculadas por la base. Cuentas propias (…9a9c…), en Tupiza.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a9c001', 'z7-p@test.bo', '{"full_name": "Electricista Z7"}'),
  ('00000000-0000-0000-0000-000009a9c002', 'z7-f@test.bo', '{"full_name": "Prueba Z7"}'),
  ('00000000-0000-0000-0000-000009a9c011', 'z7-c1@test.bo', '{"full_name": "Cliente Z7 1"}'),
  ('00000000-0000-0000-0000-000009a9c012', 'z7-c2@test.bo', '{"full_name": "Cliente Z7 2"}'),
  ('00000000-0000-0000-0000-000009a9c013', 'z7-c3@test.bo', '{"full_name": "Cliente Z7 3"}'),
  ('00000000-0000-0000-0000-000009a9c014', 'z7-c4@test.bo', '{"full_name": "Cliente Z7 4"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a9c001', 'Electricista Z7', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true),
       ('00000000-0000-0000-0000-000009a9c002', 'Prueba Z7', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true);
update public.professional_profiles set test_fixture = true where user_id = '00000000-0000-0000-0000-000009a9c002';

-- ---------------------------------------------------------------- Identidad
select test.eq(public.hmy_identity_verified('00000000-0000-0000-0000-000009a9c001'), false,
               'aprobado sin verificación de identidad: no dice "Identidad verificada"');
insert into public.identity_checks (professional_id, sandbox, status)
values ('00000000-0000-0000-0000-000009a9c001', true, 'approved');
select test.eq(public.hmy_identity_verified('00000000-0000-0000-0000-000009a9c001'), false,
               'una verificación de prueba (sandbox) no cuenta');
insert into public.identity_checks (professional_id, sandbox, status)
values ('00000000-0000-0000-0000-000009a9c001', false, 'declined');
select test.eq(public.hmy_identity_verified('00000000-0000-0000-0000-000009a9c001'), false, 'una rechazada no cuenta');
insert into public.identity_checks (professional_id, sandbox, status)
values ('00000000-0000-0000-0000-000009a9c001', false, 'approved'),
       ('00000000-0000-0000-0000-000009a9c002', false, 'approved');
select test.eq(public.hmy_identity_verified('00000000-0000-0000-0000-000009a9c001'), true, 'verificación real aprobada');
select test.eq(public.hmy_identity_verified('00000000-0000-0000-0000-000009a9c002'), false,
               'un perfil de prueba nunca dice "Identidad verificada"');
select test.eq((select is_verified from public.get_professional_public('00000000-0000-0000-0000-000009a9c002')), false,
               'el perfil público de prueba tampoco');
select test.eq((select primary_category_id from public.get_professional_public('00000000-0000-0000-0000-000009a9c001')),
               (select id from public.service_categories where slug = 'plomeria'),
               'el perfil público trae su servicio principal (para "Programar")');

-- ---------------------------------------------------------------- Categoría
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none', 'sin trabajos: sin categoría');

-- Diez trabajos de cinco estrellas de un mismo cliente: cuentan tres.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status, completed_at)
select ('00000000-0000-0000-0000-0000a9c1' || lpad(n::text, 4, '0'))::uuid, '00000000-0000-0000-0000-000009a9c011',
       '00000000-0000-0000-0000-000009a9c001', 1, 1, 'now', 'Trabajo Z7', 'completed', now() - n * interval '1 hour'
from generate_series(1, 10) n;
insert into public.reviews (booking_id, customer_id, professional_id, rating)
select ('00000000-0000-0000-0000-0000a9c1' || lpad(n::text, 4, '0'))::uuid, '00000000-0000-0000-0000-000009a9c011',
       '00000000-0000-0000-0000-000009a9c001', 5
from generate_series(1, 10) n;
select test.eq((public.hmy_rank_metrics('00000000-0000-0000-0000-000009a9c001') ->> 'jobs')::int, 3,
               'de un mismo cliente cuentan como mucho tres trabajos');
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none',
               'diez trabajos de un solo cliente no dan Plata');

-- Tres clientes más: 12 trabajos y 12 reseñas que cuentan.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status, completed_at)
select ('00000000-0000-0000-0000-0000a9c' || c || lpad(n::text, 4, '0'))::uuid,
       ('00000000-0000-0000-0000-000009a9c01' || c)::uuid, '00000000-0000-0000-0000-000009a9c001', 1, 1, 'now',
       'Trabajo Z7', 'completed', now()
from generate_series(2, 4) c, generate_series(1, 3) n;
insert into public.reviews (booking_id, customer_id, professional_id, rating)
select ('00000000-0000-0000-0000-0000a9c' || c || lpad(n::text, 4, '0'))::uuid,
       ('00000000-0000-0000-0000-000009a9c01' || c)::uuid, '00000000-0000-0000-0000-000009a9c001', case when n = 1 then 4 else 5 end
from generate_series(2, 4) c, generate_series(1, 3) n;
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'plata',
               '12 trabajos, 12 reseñas, 4,75 estrellas: Plata');
select test.eq((select count(*)::int from public.professional_rank_events
                where professional_id = '00000000-0000-0000-0000-000009a9c001' and new_tier = 'plata'), 1,
               'el cambio queda en el historial');
select test.eq((select rank_tier from public.get_professional_public('00000000-0000-0000-0000-000009a9c001')), 'plata',
               'el perfil público muestra Plata');
select test.eq((select rank_tier from public.search_professionals(
                  p_city_id => (select id from public.cities where slug = 'tupiza-pt'), p_limit => 50)
                where id = '00000000-0000-0000-0000-000009a9c001'), 'plata', 'la búsqueda muestra Plata');

select test.login('00000000-0000-0000-0000-000009a9c011');
select test.eq((select p ->> 'rank_tier' from jsonb_array_elements(
                  public.home_map_professionals((select id from public.cities where slug = 'tupiza-pt')) -> 'professionals') p
                where p ->> 'id' = '00000000-0000-0000-0000-000009a9c001'), 'plata', 'el mapa muestra Plata');
select test.eq((select (p ->> 'is_verified')::boolean from jsonb_array_elements(
                  public.home_map_professionals((select id from public.cities where slug = 'tupiza-pt')) -> 'professionals') p
                where p ->> 'id' = '00000000-0000-0000-0000-000009a9c001'), true, 'y su identidad verificada');
select test.logout();

-- Un reporte grave sin resolver la quita; descartado, vuelve.
insert into public.user_reports (reporter_id, reported_id, reason, details)
values ('00000000-0000-0000-0000-000009a9c012', '00000000-0000-0000-0000-000009a9c001', 'acoso', 'Prueba Z7');
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none',
               'un reporte de acoso abierto quita la categoría');
update public.user_reports set status = 'dismissed' where reported_id = '00000000-0000-0000-0000-000009a9c001';
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'plata', 'descartado, vuelve Plata');
insert into public.user_reports (reporter_id, reported_id, reason, details)
values ('00000000-0000-0000-0000-000009a9c012', '00000000-0000-0000-0000-000009a9c001', 'mal_trabajo', 'Prueba Z7');
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'plata',
               'una queja que no es de seguridad no la quita sola');

-- Un reclamo abierto la quita; resuelto, vuelve.
insert into public.disputes (booking_id, opened_by, reason)
values ('00000000-0000-0000-0000-0000a9c20001', '00000000-0000-0000-0000-000009a9c012', 'Prueba Z7 de reclamo');
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none', 'con un reclamo abierto no hay categoría');
update public.disputes set status = 'resolved' where booking_id = '00000000-0000-0000-0000-0000a9c20001';
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'plata', 'reclamo resuelto: vuelve');

-- Suspendido: sin categoría.
update public.profiles set suspended_at = now() where id = '00000000-0000-0000-0000-000009a9c001';
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none', 'suspendido: sin categoría');
update public.profiles set suspended_at = null where id = '00000000-0000-0000-0000-000009a9c001';
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'plata', 'sin suspensión: vuelve');

-- Abandonar trabajos baja el cumplimiento.
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status, cancelled_by)
select ('00000000-0000-0000-0000-0000a9c9' || lpad(n::text, 4, '0'))::uuid, '00000000-0000-0000-0000-000009a9c013',
       '00000000-0000-0000-0000-000009a9c001', 1, 1, 'now', 'Trabajo Z7', 'confirmed', null
from generate_series(1, 4) n;
update public.bookings set status = 'cancelled', cancelled_by = professional_id
where id::text like '00000000-0000-0000-0000-0000a9c9%';
select test.eq(public.hmy_rank_tier_of('00000000-0000-0000-0000-000009a9c001'), 'none',
               '19 hechos y 4 abandonados (83 %, menos de 85 %): pierde Plata');
select test.eq((select new_tier from public.professional_rank_events
                where professional_id = '00000000-0000-0000-0000-000009a9c001' order by id desc limit 1), 'none',
               'la baja también queda en el historial');

-- Los umbrales de cada categoría.
select test.eq(public.hmy_rank_tier('{"jobs":150,"reviews":100,"rating":4.8,"completion":0.95,"good_standing":true}'),
               'diamante', 'Diamante en el límite');
select test.eq(public.hmy_rank_tier('{"jobs":150,"reviews":99,"rating":4.9,"completion":1,"good_standing":true}'),
               'oro', 'sin 100 reseñas no es Diamante');
select test.eq(public.hmy_rank_tier('{"jobs":50,"reviews":30,"rating":4.6,"completion":0.9,"good_standing":true}'),
               'oro', 'Oro en el límite');
select test.eq(public.hmy_rank_tier('{"jobs":200,"reviews":200,"rating":4.59,"completion":1,"good_standing":true}'),
               'plata', 'con 4,59 estrellas no llega a Oro');
select test.eq(public.hmy_rank_tier('{"jobs":10,"reviews":8,"rating":4.3,"completion":0.85,"good_standing":true}'),
               'plata', 'Plata en el límite');
select test.eq(public.hmy_rank_tier('{"jobs":10,"reviews":8,"rating":4.29,"completion":1,"good_standing":true}'),
               'none', 'con 4,29 estrellas no hay Plata');
select test.eq(public.hmy_rank_tier('{"jobs":500,"reviews":500,"rating":5,"completion":1,"good_standing":false}'),
               'none', 'sin buena situación de la cuenta no hay categoría');
select test.eq(public.hmy_rank_tier('{"jobs":0,"reviews":0,"rating":null,"completion":null,"good_standing":true}'),
               'none', 'sin reseñas: sin categoría');

-- El perfil de prueba nunca tiene categoría.
select test.eq(public.hmy_rank_tier((public.hmy_rank_metrics('00000000-0000-0000-0000-000009a9c002'))), 'none',
               'perfil de prueba: sin categoría');

-- Programar a una persona: dentro de su horario publicado (hora de Bolivia).
create temp table z7_t (k text primary key, v text);
grant all on z7_t to authenticated;
insert into public.professional_availability (professional_id, weekday, start_time, end_time)
values ('00000000-0000-0000-0000-000009a9c001', 1, '08:00', '18:00');
-- El próximo lunes a las 10:00 y a las 20:00 de Bolivia (UTC-4).
insert into z7_t select 'lunes', (date_trunc('week', now() at time zone 'America/La_Paz') + interval '7 days')::date::text;
select test.login('00000000-0000-0000-0000-000009a9c014');
insert into z7_t select 'ok', public.create_booking('00000000-0000-0000-0000-000009a9c001',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Programada Z7', 'Calle Z7',
  p_scheduled_start => ((select v from z7_t where k = 'lunes') || ' 10:00')::timestamp at time zone 'America/La_Paz',
  p_duration_minutes => 120);
select test.expect_error($$select public.create_booking('00000000-0000-0000-0000-000009a9c001',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Programada Z7 tarde', 'Calle Z7',
  p_scheduled_start => ((select v from z7_t where k = 'lunes') || ' 17:00')::timestamp at time zone 'America/La_Paz',
  p_duration_minutes => 120)$$, 'HMY_OUTSIDE_AVAILABILITY');
select test.expect_error($$select public.create_booking('00000000-0000-0000-0000-000009a9c001',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Programada Z7 martes', 'Calle Z7',
  p_scheduled_start => ((select v from z7_t where k = 'lunes') || ' 10:00')::timestamp at time zone 'America/La_Paz'
                       + interval '1 day', p_duration_minutes => 60)$$, 'HMY_OUTSIDE_AVAILABILITY');
select test.logout();
select test.eq((select professional_id::text || '/' || mode from public.bookings where id = (select v::uuid from z7_t where k = 'ok')),
               '00000000-0000-0000-0000-000009a9c001/scheduled', 'la programada es solo para esa persona');
select test.eq((select count(*)::int from public.booking_offers where booking_id = (select v::uuid from z7_t where k = 'ok')), 0,
               'y no se ofrece a nadie más');

-- Nadie la lee ni la escribe directo.
select test.login('00000000-0000-0000-0000-000009a9c001');
select test.expect_error($$select * from public.professional_ranks$$, 'permission denied');
select test.expect_error($$update public.professional_ranks set tier = 'diamante'$$, 'permission denied');
select test.expect_error($$select * from public.professional_rank_events$$, 'permission denied');
select test.expect_error($$select public.hmy_recompute_rank(auth.uid())$$, 'permission denied');
select test.logout();
select test.eq(has_function_privilege('authenticated', 'public.hmy_identity_verified(uuid)', 'execute'), false,
               'la app no llama a las funciones internas');

\o
\echo '0063 identidad verificada y categorías: pruebas pasadas'
