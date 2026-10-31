-- Mapa del inicio (0048): solo profesionales aprobados, disponibles y activos,
-- con un punto aproximado; nunca la ubicación guardada. Cuentas propias (…9a8000…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a80001', 'mapa-c@test.bo', '{"full_name": "Cliente Mapa"}'),
  ('00000000-0000-0000-0000-000009a80002', 'mapa-p1@test.bo', '{"full_name": "Pro Con Ubicacion"}'),
  ('00000000-0000-0000-0000-000009a80003', 'mapa-p2@test.bo', '{"full_name": "Pro Sin Ubicacion"}'),
  ('00000000-0000-0000-0000-000009a80004', 'mapa-p3@test.bo', '{"full_name": "Pro Ocupado"}'),
  ('00000000-0000-0000-0000-000009a80005', 'mapa-p4@test.bo', '{"full_name": "Pro Pendiente"}'),
  ('00000000-0000-0000-0000-000009a80006', 'mapa-p5@test.bo', '{"full_name": "Pro Bloqueado"}'),
  ('00000000-0000-0000-0000-000009a80007', 'mapa-p6@test.bo', '{"full_name": "Pro Suspendido"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available) values
  ('00000000-0000-0000-0000-000009a80002', 'Pro Con Ubicacion', 1, 1, 'approved', true),
  ('00000000-0000-0000-0000-000009a80003', 'Pro Sin Ubicacion', 2, 1, 'approved', true),
  ('00000000-0000-0000-0000-000009a80004', 'Pro Ocupado', 1, 1, 'approved', false),
  ('00000000-0000-0000-0000-000009a80005', 'Pro Pendiente', 1, 1, 'under_review', true),
  ('00000000-0000-0000-0000-000009a80006', 'Pro Bloqueado', 1, 1, 'approved', true),
  ('00000000-0000-0000-0000-000009a80007', 'Pro Suspendido', 1, 1, 'approved', true);
update public.profiles set suspended_at = now() where id = '00000000-0000-0000-0000-000009a80007';
-- Ubicación real de trabajo (privada): no debe salir tal cual.
insert into public.professional_locations (professional_id, base_latitude, base_longitude, service_radius_km)
values ('00000000-0000-0000-0000-000009a80002', -17.781234, -63.187654, 10);
insert into public.user_blocks (blocker_id, blocked_id)
values ('00000000-0000-0000-0000-000009a80001', '00000000-0000-0000-0000-000009a80006');

-- Sin sesión, nada.
select test.login(null);
select test.expect_error($$select public.home_map_professionals(1::smallint)$$, 'permission denied');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a80001');
create temp table t_map as select public.home_map_professionals(1::smallint) as m;
select test.eq((select jsonb_array_length(m -> 'professionals') from t_map) >= 2, true, 'mapa: aparecen los disponibles');
select test.eq((select count(*)::int from t_map, jsonb_array_elements(m -> 'professionals') p
                where p ->> 'id' like '00000000-0000-0000-0000-000009a8000%'
                  and p ->> 'id' not in ('00000000-0000-0000-0000-000009a80002', '00000000-0000-0000-0000-000009a80003')), 0,
               'mapa: ni ocupados, ni pendientes, ni bloqueados, ni suspendidos');
-- El punto queda a unos 2 km o menos de la ubicación real, pero no es la ubicación real.
create temp table t_p1 as
  select (p ->> 'latitude')::numeric as lat, (p ->> 'longitude')::numeric as lng
  from t_map, jsonb_array_elements(m -> 'professionals') p where p ->> 'id' = '00000000-0000-0000-0000-000009a80002';
select test.eq((select count(*)::int from t_p1), 1, 'mapa: el profesional con ubicación aparece una vez');
select test.eq((select lat <> -17.781234 and lng <> -63.187654 from t_p1), true, 'mapa: no sale la ubicación guardada');
select test.eq((select public.hmy_distance_km(lat, lng, -17.781234, -63.187654) < 3 from t_p1), true,
               'mapa: el punto es aproximado (menos de 3 km)');
select test.eq((select public.hmy_distance_km(lat, lng, -17.781234, -63.187654) > 0.05 from t_p1), true,
               'mapa: y no es el punto exacto');
select test.eq((select m::text not like '%17.781234%' and m::text not like '%63.187654%' from t_map), true,
               'mapa: la coordenada guardada no aparece en ninguna parte');
select test.eq((select m::text not like '%address%' and m::text not like '%phone%' from t_map), true,
               'mapa: sin direcciones ni teléfonos');
-- El mismo punto cada vez.
select test.eq((select public.home_map_professionals(1::smallint) = m from t_map), true, 'mapa: el punto no cambia');
select test.eq((select m -> 'city' ->> 'name' from t_map) is not null, true, 'mapa: trae la ciudad para centrar');
select test.logout();

-- El profesional no se ve a sí mismo.
select test.login('00000000-0000-0000-0000-000009a80002');
select test.eq((select count(*)::int from jsonb_array_elements(public.home_map_professionals(1::smallint) -> 'professionals') p
                where p ->> 'id' = '00000000-0000-0000-0000-000009a80002'), 0, 'mapa: uno no se ve a sí mismo');
select test.logout();

select test.eq(has_function_privilege('authenticated', 'public.hmy_map_jitter(uuid, integer)', 'execute'), false,
               'mapa: el corrimiento solo lo usa el servidor');
\o
\echo 'PRUEBAS DEL MAPA DEL INICIO PASARON'
