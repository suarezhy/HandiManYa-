-- Pruebas del código de llegada (0014): correcto, incorrecto, vencido,
-- intentos repetidos, personas no autorizadas, cancelación, excepción del
-- equipo y que sin llegada verificada no se empieza el trabajo. Corre después de 80.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_ar (k text primary key, v text);
grant all on t_ar to authenticated;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000009c1', 'arr-cliente@test.bo', '{"full_name":"Rosa Llegada","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000009c2', 'arr-otro@test.bo', '{"full_name":"Otro Cliente","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000009b1', 'arr-pro@test.bo', '{"full_name":"Luis Llegada","city_id":"1"}');

select test.login('00000000-0000-0000-0000-0000000009b1');
select public.start_professional_application();
update public.professional_profiles set display_name = 'Luis Llegada', primary_category_id = 1, city_id = 1,
  bio = 'Plomero puntual' where user_id = auth.uid();
insert into public.professional_services (professional_id, category_id, specialty, price_from) values (auth.uid(), 1, 'Plomería', 80);
insert into public.professional_documents (professional_id, doc_type, storage_path) values (auth.uid(), 'ci_anverso', auth.uid() || '/ci.jpg');
select public.submit_professional_application();
select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000009b1', 'approved');
select test.logout();
update public.wallets set available = 500 where professional_id = '00000000-0000-0000-0000-0000000009b1';
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.set_active_role('professional');
select public.set_availability(true);

-- Pedido 1: aceptado y en camino.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_ar select 'b1', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Gotea el grifo', 'Calle Llegada 1');
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.accept_booking((select v from t_ar where k = 'b1')::uuid);

-- 1. Sin "En camino" no hay código; sin llegada verificada no se empieza.
select test.expect_error(format('select public.mark_arrived(%L)', (select v from t_ar where k = 'b1')), 'HMY_INVALID_TRANSITION');
select test.expect_error(format('select public.update_job_progress(%L, %L)', (select v from t_ar where k = 'b1'), 'in_progress'),
                         'HMY_ARRIVAL_NOT_VERIFIED');
select public.update_job_progress((select v from t_ar where k = 'b1')::uuid, 'on_the_way');
select test.expect_error(format('select public.update_job_progress(%L, %L)', (select v from t_ar where k = 'b1'), 'in_progress'),
                         'HMY_ARRIVAL_NOT_VERIFIED');

-- 2. Solo el profesional asignado genera el código.
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.mark_arrived(%L)', (select v from t_ar where k = 'b1')), 'HMY_FORBIDDEN');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b1'), '123456'),
                         'HMY_ARRIVAL_NO_PIN');
select test.login('00000000-0000-0000-0000-0000000009b1');
insert into t_ar select 'pin1', public.mark_arrived((select v from t_ar where k = 'b1')::uuid) ->> 'pin';
do $$ begin
  perform test.eq((select v ~ '^[0-9]{6}$' from t_ar where k = 'pin1'), true, 'llegada: código de 6 números');
end $$;
select test.logout();
do $$ begin
  perform test.eq((select pin_hash <> (select v from t_ar where k = 'pin1') and pin_hash like '$2%'
                     from public.booking_arrivals where booking_id = (select v from t_ar where k = 'b1')::uuid),
                  true, 'llegada: se guarda solo el verificador, no el código');
  perform test.eq((select count(*)::int from public.notifications
                    where user_id = '00000000-0000-0000-0000-0000000009c1' and kind = 'arrival'), 1,
                  'llegada: el cliente recibe el aviso');
end $$;
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.expect_error(format('select public.mark_arrived(%L)', (select v from t_ar where k = 'b1')), 'HMY_ARRIVAL_PIN_TOO_SOON');

-- 3. Nadie más ve la tabla ni el código.
do $$ begin
  perform test.eq(public.booking_arrival((select v from t_ar where k = 'b1')::uuid) ->> 'state', 'waiting_pin',
                  'llegada: el profesional ve que espera el código');
  perform test.eq(public.booking_arrival((select v from t_ar where k = 'b1')::uuid) ? 'pin', false,
                  'llegada: el estado nunca incluye el código');
end $$;
select test.expect_error('select * from public.booking_arrivals', 'permission denied');

-- 4. El profesional no puede verificarse a sí mismo; otro cliente tampoco.
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b1'),
                                (select v from t_ar where k = 'pin1')), 'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-0000000009c2');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b1'),
                                (select v from t_ar where k = 'pin1')), 'HMY_FORBIDDEN');
select test.expect_error(format('select public.booking_arrival(%L)', (select v from t_ar where k = 'b1')), 'HMY_FORBIDDEN');

-- 5. Incorrecto: cuenta el intento y avisa cuántos quedan.
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b1'), '12a456'),
                         'HMY_INVALID_PIN');
insert into t_ar select 'wrong', public.verify_arrival_pin((select v from t_ar where k = 'b1')::uuid,
  case when (select v from t_ar where k = 'pin1') = '000000' then '000001' else '000000' end)::text;
do $$ begin
  perform test.eq((select v::jsonb ->> 'reason' from t_ar where k = 'wrong'), 'wrong', 'llegada: código incorrecto');
  perform test.eq((select (v::jsonb ->> 'attempts_left')::int from t_ar where k = 'wrong'), 4, 'llegada: quedan 4 intentos');
end $$;

-- 6. Correcto: llegada verificada, avisa al profesional y el código no se repite.
do $$ begin
  perform test.eq((public.verify_arrival_pin((select v from t_ar where k = 'b1')::uuid,
                                             (select v from t_ar where k = 'pin1')) ->> 'ok')::boolean,
                  true, 'llegada: el código correcto verifica la llegada');
  perform test.eq(public.booking_arrival((select v from t_ar where k = 'b1')::uuid) ->> 'method', 'pin',
                  'llegada: queda verificada con el código');
end $$;
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b1'),
                                (select v from t_ar where k = 'pin1')), 'HMY_ARRIVAL_ALREADY_VERIFIED');
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.expect_error(format('select public.mark_arrived(%L)', (select v from t_ar where k = 'b1')), 'HMY_ARRIVAL_ALREADY_VERIFIED');
select test.eq(public.update_job_progress((select v from t_ar where k = 'b1')::uuid, 'in_progress')::text, 'in_progress',
               'llegada: con llegada verificada empieza el trabajo');
select test.logout();
do $$ begin
  perform test.eq((select count(*)::int from public.notifications
                    where user_id = '00000000-0000-0000-0000-0000000009b1' and kind = 'arrival'), 1,
                  'llegada: el profesional recibe "Llegada verificada"');
  perform test.eq((select pin_hash is null from public.booking_arrivals where booking_id = (select v from t_ar where k = 'b1')::uuid),
                  true, 'llegada: el código usado se borra');
end $$;

-- Pedido 2: intentos repetidos bloquean el código; vencido no sirve; máximo 3 códigos.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_ar select 'b2', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Revisar la ducha', 'Calle Llegada 2');
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.accept_booking((select v from t_ar where k = 'b2')::uuid);
select public.update_job_progress((select v from t_ar where k = 'b2')::uuid, 'on_the_way');
insert into t_ar select 'pin2', public.mark_arrived((select v from t_ar where k = 'b2')::uuid) ->> 'pin';
select test.login('00000000-0000-0000-0000-0000000009c1');
do $$
declare v_bad text := case when (select v from t_ar where k = 'pin2') = '999999' then '999998' else '999999' end;
        r jsonb;
begin
  for i in 1..5 loop
    r := public.verify_arrival_pin((select v from t_ar where k = 'b2')::uuid, v_bad);
  end loop;
  perform test.eq(r ->> 'reason', 'locked', 'llegada: 5 intentos fallidos bloquean el código');
end $$;
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b2'),
                                (select v from t_ar where k = 'pin2')), 'HMY_ARRIVAL_NO_PIN');
select test.logout();
-- Un código nuevo (simula que pasaron 30 segundos) que luego vence.
update public.booking_arrivals set last_issued_at = now() - interval '1 minute'
 where booking_id = (select v from t_ar where k = 'b2')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
insert into t_ar select 'pin3', public.mark_arrived((select v from t_ar where k = 'b2')::uuid) ->> 'pin';
select test.logout();
update public.booking_arrivals set pin_expires_at = now() - interval '1 second'
 where booking_id = (select v from t_ar where k = 'b2')::uuid;
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.eq(public.verify_arrival_pin((select v from t_ar where k = 'b2')::uuid, (select v from t_ar where k = 'pin3')) ->> 'reason',
               'expired', 'llegada: un código vencido no sirve');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b2'),
                                (select v from t_ar where k = 'pin3')), 'HMY_ARRIVAL_NO_PIN');
select test.logout();
update public.booking_arrivals set last_issued_at = now() - interval '1 minute'
 where booking_id = (select v from t_ar where k = 'b2')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.mark_arrived((select v from t_ar where k = 'b2')::uuid);
select test.logout();
update public.booking_arrivals set last_issued_at = now() - interval '1 minute'
 where booking_id = (select v from t_ar where k = 'b2')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.expect_error(format('select public.mark_arrived(%L)', (select v from t_ar where k = 'b2')), 'HMY_ARRIVAL_PIN_LIMIT');

-- 7. Excepción del equipo: solo admin, con motivo, y queda en la auditoría.
select test.logout();
insert into t_ar select 'code2', code from public.bookings where id = (select v from t_ar where k = 'b2')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.expect_error(format('select public.admin_verify_arrival(%L, %L)', (select v from t_ar where k = 'code2'), 'Llamé al cliente'),
                         'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error(format('select public.admin_verify_arrival(%L, %L)', (select v from t_ar where k = 'code2'), ''), 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.admin_verify_arrival('NOEXISTE', 'Llamé al cliente')$$, 'HMY_NOT_FOUND');
select public.admin_verify_arrival(lower((select v from t_ar where k = 'code2')), 'El cliente confirmó por teléfono');
select test.logout();
do $$ begin
  perform test.eq((select method from public.booking_arrivals where booking_id = (select v from t_ar where k = 'b2')::uuid), 'admin',
                  'llegada: el equipo puede verificar con un motivo');
  perform test.eq((select count(*)::int from public.admin_audit_log where action = 'arrival.admin_verified'
                     and target_id = (select v from t_ar where k = 'b2')), 1, 'llegada: la excepción queda en la auditoría');
end $$;

-- 8. Cancelación: el código deja de servir.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_ar select 'b3', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Cambiar el flotador', 'Calle Llegada 3');
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.accept_booking((select v from t_ar where k = 'b3')::uuid);
select public.update_job_progress((select v from t_ar where k = 'b3')::uuid, 'on_the_way');
insert into t_ar select 'pin4', public.mark_arrived((select v from t_ar where k = 'b3')::uuid) ->> 'pin';
select public.cancel_booking((select v from t_ar where k = 'b3')::uuid, 'No encontré la dirección');
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b3'),
                                (select v from t_ar where k = 'pin4')), 'HMY_INVALID_TRANSITION');
select test.logout();
select test.eq((select pin_hash is null from public.booking_arrivals where booking_id = (select v from t_ar where k = 'b3')::uuid),
               true, 'llegada: cancelar borra el código');

-- 9. Puntualidad: en un programado se guarda cuánto tarde llegó (sin multas).
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_ar select 'b4', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'scheduled', 'Instalar lavamanos',
  'Calle Llegada 4', null, null, date_trunc('hour', now()) + interval '3 days', 60);
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.accept_booking((select v from t_ar where k = 'b4')::uuid);
select test.logout();
update public.bookings set scheduled_start = now() - interval '25 minutes' where id = (select v from t_ar where k = 'b4')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.update_job_progress((select v from t_ar where k = 'b4')::uuid, 'on_the_way');
select test.arrive((select v from t_ar where k = 'b4')::uuid, '00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c1');
select test.logout();
select test.eq((select delay_minutes from public.booking_arrivals where booking_id = (select v from t_ar where k = 'b4')::uuid), 25,
               'puntualidad: se guardan los minutos de atraso');
select test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-0000000009b1') > 0,
               true, 'puntualidad: llegar tarde no descuenta dinero');

-- 10. Límite por cliente: 10 intentos fallidos por hora en todos sus pedidos.
insert into public.arrival_pin_attempts (booking_id, customer_id, ok)
select (select v from t_ar where k = 'b1')::uuid, '00000000-0000-0000-0000-0000000009c1', false from generate_series(1, 10);
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.verify_arrival_pin(%L, %L)', (select v from t_ar where k = 'b2'), '123456'),
                         'HMY_TOO_MANY_ATTEMPTS');
select test.logout();

\o
\echo 'PRUEBAS DEL CÓDIGO DE LLEGADA PASARON'
