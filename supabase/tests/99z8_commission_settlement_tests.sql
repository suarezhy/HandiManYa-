-- La comisión se cobra solo cuando el cliente confirma que el trabajo terminó
-- (pedido del dueño, 30-10-2026). Al acordar el precio se reserva; reservado
-- no es cobrado ni se puede usar en otro trabajo. Al cancelar vuelve entera.
-- El ejemplo del dueño: saldo Bs 100, precio Bs 120, comisión Bs 12.
-- Cuentas propias (…9a9c…), en Tupiza. Sin migración: prueba lo de 0062.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table z8_rules as select id, is_active from public.commission_rules;
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a9d001', 'z8-c@test.bo', '{"full_name": "Cliente Z8"}'),
  ('00000000-0000-0000-0000-000009a9d002', 'z8-p@test.bo', '{"full_name": "Electricista Z8"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-000009a9d002', 'Electricista Z8',
        (select id from public.service_categories where slug = 'plomeria'),
        (select id from public.cities where slug = 'tupiza-pt'), 'approved', true);
insert into public.wallets (professional_id) values ('00000000-0000-0000-0000-000009a9d002') on conflict do nothing;

create temp table t68 (k text primary key, v text);
grant all on t68 to authenticated;

-- Saldo, reservado y cobrado de la billetera, como los ve el profesional.
create function pg_temp.z8_wallet() returns text language sql as $$
  select (s ->> 'available')::numeric || '/' || (s ->> 'reserved')::numeric || '/'
         || ((s ->> 'available')::numeric + (s ->> 'reserved')::numeric) || '/'
         || (s ->> 'commissions_collected')::numeric
  from (select public.my_wallet_summary() s) x
$$;
grant execute on function pg_temp.z8_wallet() to authenticated;

select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9d002', 100, 'Saldo de prueba', 'seed-z8');
select test.logout();

-- 1. El ejemplo del dueño.
select test.login('00000000-0000-0000-0000-000009a9d001');
insert into t68 select 'a', public.create_booking('00000000-0000-0000-0000-000009a9d002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Cambiar un enchufe', 'Calle Tupiza 8');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.eq(pg_temp.z8_wallet(), '100.00/0.00/100.00/0', 'antes de acordar: total Bs 100, nada reservado');
select test.agree((select v::uuid from t68 where k = 'a'), 120);
-- disponible / reservado / total / cobrado
select test.eq(pg_temp.z8_wallet(), '88.00/12.00/100.00/0', 'acordado Bs 120: Bs 12 reservados, total sigue en Bs 100');
select test.eq((select commission_captured is null from public.bookings where id = (select v::uuid from t68 where k = 'a')),
               true, 'reservar no es cobrar');
select public.update_job_progress((select v::uuid from t68 where k = 'a'), 'on_the_way');
select test.arrive((select v::uuid from t68 where k = 'a'), '00000000-0000-0000-0000-000009a9d002',
                   '00000000-0000-0000-0000-000009a9d001');
select public.update_job_progress((select v::uuid from t68 where k = 'a'), 'in_progress');
select public.update_job_progress((select v::uuid from t68 where k = 'a'), 'work_finished');
select test.eq(pg_temp.z8_wallet(), '88.00/12.00/100.00/0', '"Terminé el trabajo" del profesional todavía no cobra');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a9d001');
select public.confirm_completion((select v::uuid from t68 where k = 'a'));
-- Confirmar dos veces (doble toque o reintento) no cobra dos veces.
do $$ begin
  perform public.confirm_completion((select v::uuid from t68 where k = 'a'));
exception when others then null;
end $$;
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.eq(pg_temp.z8_wallet(), '88.00/0.00/88.00/12.00', 'el cliente confirma: se cobran Bs 12, total Bs 88');
select test.logout();
select test.eq((select count(*)::int from public.wallet_ledger
                where booking_id = (select v::uuid from t68 where k = 'a') and entry_type = 'commission_capture'), 1,
               'un solo cobro en el historial');
select test.eq((select final_amount || '/' || commission_captured || '/' || commission_reserved from public.bookings
                where id = (select v::uuid from t68 where k = 'a')), '120.00/12.00/0.00', 'el trabajo guarda Bs 120 y Bs 12');
-- Volver a correr el cobro a mano tampoco cobra otra vez.
select public._commission_capture((select v::uuid from t68 where k = 'a'));
select test.eq((select available || '/' || reserved from public.wallets
                where professional_id = '00000000-0000-0000-0000-000009a9d002'), '88.00/0.00', 'el cobro es una sola vez');

-- 2. Cancelar un trabajo acordado devuelve toda la reserva.
select test.login('00000000-0000-0000-0000-000009a9d001');
insert into t68 select 'b', public.create_booking('00000000-0000-0000-0000-000009a9d002',
  (select id from public.service_categories where slug = 'plomeria'), 'now', 'Revisar el tablero', 'Calle Tupiza 8');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.agree((select v::uuid from t68 where k = 'b'), 120);
select test.eq(pg_temp.z8_wallet(), '76.00/12.00/88.00/12.00', 'otro trabajo de Bs 120 reserva Bs 12');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d001');
select public.cancel_booking((select v::uuid from t68 where k = 'b'), 'Ya no lo necesito');
-- Cancelar de nuevo no devuelve dos veces.
do $$ begin
  perform public.cancel_booking((select v::uuid from t68 where k = 'b'), 'Ya no lo necesito');
exception when others then null;
end $$;
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.eq(pg_temp.z8_wallet(), '88.00/0.00/88.00/12.00', 'al cancelar vuelven los Bs 12, sin cobro');
select test.logout();
select test.eq((select count(*)::int || '/' || count(*) filter (where entry_type = 'commission_capture')::int
                from public.wallet_ledger where booking_id = (select v::uuid from t68 where k = 'b')
                  and entry_type in ('commission_release', 'commission_capture')), '1/0', 'una devolución, ningún cobro');

-- 3. Saldo reservado no se usa en otro trabajo; sin saldo no se acuerda.
select test.login('00000000-0000-0000-0000-000009a9d001');
insert into t68 select 'c', public.create_booking('00000000-0000-0000-0000-000009a9d002',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Instalar luces', 'Calle Tupiza 8',
  p_scheduled_start => date_trunc('hour', now()) + interval '3 days');
insert into t68 select 'd', public.create_booking('00000000-0000-0000-0000-000009a9d002',
  (select id from public.service_categories where slug = 'plomeria'), 'scheduled', 'Cambiar cables', 'Calle Tupiza 8',
  p_scheduled_start => date_trunc('hour', now()) + interval '4 days');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.agree((select v::uuid from t68 where k = 'c'), 500);
select test.eq(pg_temp.z8_wallet(), '38.00/50.00/88.00/12.00', 'Bs 500 programado reserva Bs 50');
select test.expect_error($$select test.agree((select v::uuid from t68 where k = 'd'), 500)$$, 'HMY_INSUFFICIENT_BALANCE');
select test.eq(pg_temp.z8_wallet(), '38.00/50.00/88.00/12.00', 'el segundo no toca el saldo ni lo deja negativo');
select test.eq((select status::text from public.bookings where id = (select v::uuid from t68 where k = 'd')),
               'requested', 'el segundo sigue esperando precio');
select test.eq((public.commission_for_amount((select v::uuid from t68 where k = 'd'), 500) ->> 'missing')::numeric,
               12.00::numeric, 've que le faltan Bs 12');
-- Un precio que sí cubre con lo disponible se acuerda.
select test.agree((select v::uuid from t68 where k = 'd'), 300);
select test.eq(pg_temp.z8_wallet(), '8.00/80.00/88.00/12.00', 'Bs 300: reserva Bs 30 de lo disponible');
select test.logout();

-- 4. Una recarga no paga nada viejo: todo va a disponible.
select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_wallet_adjustment('00000000-0000-0000-0000-000009a9d002', 20, 'Saldo de prueba', 'seed-z8-b');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a9d002');
select test.eq(pg_temp.z8_wallet(), '28.00/80.00/108.00/12.00', 'la recarga suma entera a disponible');
select test.eq((public.my_wallet_summary() ->> 'commission_pending')::numeric, 0::numeric, 'no hay comisión pendiente');
select test.logout();
select test.eq((select count(*)::int from public.wallets where available < 0 or reserved < 0), 0, 'ningún saldo negativo');

update public.commission_rules r set is_active = z.is_active from z8_rules z where z.id = r.id;

\o
\echo 'Comisión al confirmar el cliente (ejemplo Bs 100 / 120 / 12): pruebas pasadas'
