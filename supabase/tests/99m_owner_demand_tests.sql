-- Demanda de 30 días: cada fila del panel abre sus pedidos (0044). Cuentas
-- propias (…9a4000…); ningún dato real cambia.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a40001', '59170098401', now(), '{"full_name": "Dueño Demanda"}'),
  ('00000000-0000-0000-0000-000009a40002', '59170098402', now(), '{"full_name": "Gerente Demanda"}'),
  ('00000000-0000-0000-0000-000009a40006', '59170098406', now(), '{"full_name": "Cliente Demanda"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a40001', 'admin');
select test.grant('00000000-0000-0000-0000-000009a40001', '00000000-0000-0000-0000-000009a40002', 'manager');
select test.logout();

-- Un municipio sin profesionales con dos pedidos recientes y uno viejo.
create temp table m_city as
  select c.id, c.name, d.name as department from public.cities c join public.departments d on d.id = c.department_id
  where not exists (select 1 from public.professional_profiles pp where pp.city_id = c.id)
    and not exists (select 1 from public.bookings b where b.city_id = c.id)
  order by c.id limit 1;
grant select on m_city to authenticated;
insert into public.bookings (id, code, customer_id, category_id, city_id, mode, description, status, created_at)
select v.id::uuid, v.code, '00000000-0000-0000-0000-000009a40006', 1, (select id from m_city), 'now',
       'Pedido de prueba de demanda', v.status::public.booking_status, v.at
from (values ('00000000-0000-0000-0000-000009a4b001', 'DEM99M01', 'requested', now()),
             ('00000000-0000-0000-0000-000009a4b002', 'DEM99M02', 'cancelled', now() - interval '3 days'),
             ('00000000-0000-0000-0000-000009a4b003', 'DEM99M03', 'requested', now() - interval '40 days'),
             ('00000000-0000-0000-0000-000009a4b004', 'DEM99M04', 'draft', now())) v(id, code, status, at);

select test.login('00000000-0000-0000-0000-000009a40002');
select test.expect_error($$select public.owner_demand_bookings('municipio', 'x')$$, 'HMY_FORBIDDEN');
select test.logout();
select test.login(null);
select test.expect_error($$select public.owner_demand_bookings('municipio', 'x')$$, 'permission denied');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a40001');
create temp table m_dash as select public.owner_dashboard() as d;
create function pg_temp.dem(k text, n text, dep text default null) returns jsonb language sql as
  $$ select public.owner_demand_bookings(k, n, dep) $$;

select test.eq((pg_temp.dem('municipio', (select name from m_city), (select department from m_city)) ->> 'total')::int, 2,
               'municipio: los dos pedidos de 30 días (ni el viejo ni el borrador)');
select test.eq((pg_temp.dem('municipio', (select name from m_city), (select department from m_city)) ->> 'professionals')::int,
               0, 'municipio: sin profesionales con base allí');
select test.eq((select (r ->> 'count')::int from m_dash, jsonb_array_elements(d -> 'coverage_gaps') r
                where r ->> 'name' = (select name from m_city) and r ->> 'department' = (select department from m_city)),
               2, 'el panel lo cuenta igual en Sin cobertura');
-- Cada fila de cada lista del panel = el total de su lista.
do $$
declare r jsonb; k text; key text;
begin
  for k, key in values ('municipio', 'demand_municipality'), ('departamento', 'demand_department'),
                       ('categoria', 'demand_category') loop
    for r in select jsonb_array_elements((select d from m_dash) -> key) loop
      perform test.eq((pg_temp.dem(k, r ->> 'name', r ->> 'department') ->> 'total')::int, (r ->> 'count')::int,
                      'demanda: ' || k || ' ' || (r ->> 'name') || ' = su lista');
    end loop;
  end loop;
end $$;
select test.eq((pg_temp.dem('municipio', (select name from m_city), (select department from m_city)) -> 'items' -> 0 ->> 'code'),
               'DEM99M01', 'la lista trae los pedidos, el más nuevo primero');
select test.expect_error($$select public.owner_demand_bookings('barrio', 'x')$$, 'HMY_INVALID_STATUS');
select test.logout();

\o
\echo 'PRUEBAS DE DEMANDA PASARON'
