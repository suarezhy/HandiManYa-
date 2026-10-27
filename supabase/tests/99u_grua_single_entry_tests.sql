-- Grúa solo como servicio propio (0052). Cuenta propia (…9a9200…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a92001', 'grua1-c@test.bo', '{"full_name": "Cliente Grua Uno"}');

-- Lo que ve el cliente.
select test.login('00000000-0000-0000-0000-000009a92001');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'mecanica' and p.name = 'Grúa'), 0, 'mecánica: ya no muestra Grúa');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'mecanica' and p.opens_category_id is not null), 0, 'mecánica: ninguna opción lleva a otro servicio');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'mecanica' and p.name in ('El auto no arranca', 'Batería descargada', 'Cambio de llanta')), 3,
               'mecánica: conserva sus opciones');
select test.eq((select (name, is_active, allows_ya)::text from public.service_categories where slug = 'grua'), '(Grúa,t,t)',
               'grúa: sigue como servicio propio, con ¡Ya!');
select test.eq((select count(*)::int from public.service_categories where name ilike '%grúa%' and is_active), 1,
               'grúa: un solo servicio');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'grua' and p.name = 'Remolque de vehículo'), 1, 'grúa: conserva el remolque');
select test.eq((select safety_note from public.service_categories where slug = 'mecanica'),
               'Si tu vehículo se averió, espera en un lugar seguro y enciende las luces de emergencia. '
               || 'Nunca entregues tu vehículo sin acordarlo previamente con el profesional.',
               'mecánica: aviso de seguridad corto');
select test.eq((select description from public.service_categories where slug = 'mecanica') not ilike '%grúa%', true,
               'mecánica: la descripción ya no promete grúa');
select test.logout();

-- No se borró nada: la opción vieja queda inactiva, así los pedidos que la nombran no cambian.
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                where c.slug = 'mecanica' and p.name = 'Grúa' and not p.is_active), 1, 'mecánica: la opción vieja se guarda inactiva');
\o
\echo 'PRUEBAS DE GRÚA ÚNICA PASARON'
