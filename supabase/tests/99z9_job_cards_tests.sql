-- 0064: las tarjetas de trabajos traen el número y el precio acordado, y un
-- trabajo en curso siempre sale en la lista aunque haya muchos pedidos.
-- Cuentas propias (…9a9f…), en Tupiza.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table z9_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a9f001', 'z9-c@test.bo', '{"full_name": "Rosa Cliente Z9"}'),
  ('00000000-0000-0000-0000-000009a9f002', 'z9-p@test.bo', '{"full_name": "Plomero Z9"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a9f002', 'Plomero Z9', (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009a9f002') on conflict do nothing;
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9f002', 100, 'Saldo de prueba', 'seed-z9');
select test.logout();

create temp table t69 (k text primary key, v text);
grant all on t69 to authenticated;
select test.login('00000000-0000-0000-0000-000009a9f001');
insert into t69 select 'a', public.create_booking('00000000-0000-0000-0000-000009a9f002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Gotea la ducha', 'Calle Tupiza 9');
insert into t69 select 'b', public.create_booking('00000000-0000-0000-0000-000009a9f002',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Cambiar el grifo', 'Calle Tupiza 9',
  p_scheduled_start => date_trunc('hour', now()) + interval '3 days');
select test.logout();

-- Sin precio todavía: la tarjeta dice "Precio pendiente".
select test.login('00000000-0000-0000-0000-000009a9f002');
select test.eq((select coalesce(agreed_amount::text, 'pendiente') from public.my_bookings('professional')
                where id = (select v::uuid from t69 where k = 'a')), 'pendiente', 'sin precio acordado: pendiente');
select test.agree((select v::uuid from t69 where k = 'a'), 120);
select test.eq((select code = (select code from public.bookings where id = (select v::uuid from t69 where k = 'a'))
                       and agreed_amount = 120 and extras_amount = 0 and status = 'confirmed' and not is_offer
                       and other_name = 'Rosa'
                from public.my_bookings('professional') where id = (select v::uuid from t69 where k = 'a')), true,
               'el profesional ve número, Bs 120, confirmado y el nombre del cliente');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9f001');
select test.eq((select agreed_amount || '/' || other_name from public.my_bookings('customer')
                where id = (select v::uuid from t69 where k = 'a')), '120.00/Plomero Z9', 'el cliente ve Bs 120 y al profesional');

-- Cancelado: guarda su número y su precio.
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9f002');
select test.agree((select v::uuid from t69 where k = 'b'), 80);
select public.cancel_booking((select v::uuid from t69 where k = 'b'), 'No llego a tiempo');
select test.eq((select status || '/' || agreed_amount from public.my_bookings('professional')
                where id = (select v::uuid from t69 where k = 'b')), 'cancelled/80.00', 'cancelado mantiene Bs 80');
select test.logout();

-- Con más de 100 pedidos cerrados más nuevos, el trabajo en curso sigue en la lista.
set session_replication_role = replica;
insert into public.bookings (customer_id, professional_id, category_id, city_id, mode, description, status, created_at)
select '00000000-0000-0000-0000-000009a9f001', '00000000-0000-0000-0000-000009a9f002',
       (select id from public.service_categories where slug = 'plomeria'), (select id from public.cities where slug = 'tupiza-pt'),
       'now', 'Viejo ' || i, 'completed', now() + make_interval(mins => i)
from generate_series(1, 120) i;
set session_replication_role = origin;
select test.login('00000000-0000-0000-0000-000009a9f002');
select test.eq((select count(*)::int from public.my_bookings('professional') where id = (select v::uuid from t69 where k = 'a')),
               1, 'el trabajo confirmado sale aunque haya 120 más nuevos');
select test.eq((select count(*)::int from public.my_bookings('professional')), 101, 'historial: 100 más el activo');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9f001');
select test.eq((select count(*)::int from public.my_bookings('customer') where id = (select v::uuid from t69 where k = 'a')),
               1, 'el cliente también lo ve');
select test.logout();

select test.login(null);
select test.expect_error($$select * from public.my_bookings('customer')$$, 'permission denied');
select test.logout();

update public.commission_rules r set is_active = z.is_active from z9_rules z where z.id = r.id;

\o
\echo '0064 tarjetas de trabajos: pruebas pasadas'
