-- Pruebas de seguridad y reglas de negocio de la base de datos.
-- Se ejecutan en una base local con 00_supabase_stub.sql y las migraciones.
-- Cada bloque falla con una excepción clara si algo no se cumple.

\set ON_ERROR_STOP 1
\o /dev/null

create schema if not exists test;

create function test.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', case when p_user is null then 'anon' else 'authenticated' end,
                      -- Como Supabase: método y hora del inicio de sesión.
                      'amr', json_build_array(json_build_object('method', 'password',
                                                                'timestamp', extract(epoch from now())::bigint)))::text, false);
  if p_user is null then
    execute 'set role anon';
  else
    execute 'set role authenticated';
  end if;
end $$;

create function test.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', false);
end $$;

create function test.expect_error(p_sql text, p_pattern text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm !~* p_pattern then
      raise exception 'Se esperaba error "%", pero fue "%" en: %', p_pattern, sqlerrm, p_sql;
    end if;
    return;
  end;
  raise exception 'Se esperaba error "%", pero no hubo error en: %', p_pattern, p_sql;
end $$;

create function test.eq(p_actual anyelement, p_expected anyelement, p_msg text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FALLÓ: % (esperado %, obtenido %)', p_msg, p_expected, p_actual;
  end if;
  raise notice 'ok - %', p_msg;
end $$;

-- Carnet aceptado (anverso y reverso): aprobar a un profesional lo exige (0032).
create function test.accept_id(p_pro uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.professional_documents (professional_id, doc_type, storage_path, status)
  values (p_pro, 'ci_anverso', p_pro || '/ci-a.jpg', 'accepted'), (p_pro, 'ci_reverso', p_pro || '/ci-r.jpg', 'accepted');
end $$;

-- Llegada verificada (0014): el profesional marca "He llegado" y el cliente
-- escribe el código. Deja la sesión como el profesional.
create function test.arrive(p_booking uuid, p_pro uuid, p_customer uuid) returns void language plpgsql as $$
declare v_pin text;
begin
  perform test.login(p_pro);
  v_pin := public.mark_arrived(p_booking) ->> 'pin';
  perform test.login(p_customer);
  if not (public.verify_arrival_pin(p_booking, v_pin) ->> 'ok')::boolean then
    raise exception 'FALLÓ: no se verificó la llegada de %', p_booking;
  end if;
  perform test.login(p_pro);
end $$;

grant usage on schema test to anon, authenticated;
grant execute on all functions in schema test to anon, authenticated;

-- Usuarios de prueba
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.bo', '{"full_name":"Ana Admin"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cliente@test.bo', '{"full_name":"Carla Rojas","phone":"+59171234567","city_id":"1","terms_accepted":"true"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'otro@test.bo', '{"full_name":"Otro Cliente","phone":"12345"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'pro@test.bo', '{"full_name":"Juan Mamani","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'pro2@test.bo', '{"full_name":"Pedro Quispe","city_id":"1"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-00000000000a', 'admin');

-- 1. Registro
do $$ begin
  -- Solo las cuentas de prueba: en dev también hay cuentas reales de las pruebas en celulares.
  perform test.eq((select count(*)::int from public.profiles p join auth.users u on u.id = p.id
                   where u.email like '%@test.bo'), 5, 'cada cuenta nueva tiene perfil');
  perform test.eq((select count(*)::int from public.user_roles r join auth.users u on u.id = r.user_id
                   where r.role = 'customer' and u.email like '%@test.bo'), 5, 'cada cuenta nueva es cliente');
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'), '+59171234567', 'guarda celular boliviano válido');
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-0000000000c2'), null::text, 'descarta celular inválido');
  perform test.eq((select terms_accepted_at is not null from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'), true, 'registra aceptación de términos');
end $$;

-- 2. Roles: el rol activo no se puede cambiar desde la app
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error($$update public.profiles set active_role = 'admin' where id = auth.uid()$$, 'permission denied');
select test.expect_error($$select public.set_active_role('professional')$$, 'HMY_ROLE_NOT_GRANTED');
select test.expect_error($$insert into public.user_roles values (auth.uid(), 'admin', now(), null)$$, 'permission denied');
do $$ begin
  update public.profiles set full_name = 'Carla Rojas Vaca' where id = auth.uid();
  perform test.eq((select full_name from public.profiles where id = auth.uid()), 'Carla Rojas Vaca', 'el cliente edita su nombre');
  perform test.eq((select count(*)::int from public.profiles), 1, 'el cliente solo ve su propio perfil');
end $$;
select test.logout();

-- 3. Postulación profesional
select test.login('00000000-0000-0000-0000-0000000000b1');
select public.start_professional_application();
update public.professional_profiles set display_name = 'Juan Mamani', primary_category_id = 1, bio = 'Plomero con 10 años', years_experience = 10 where user_id = auth.uid();
select test.expect_error($$update public.professional_profiles set status = 'approved' where user_id = auth.uid()$$, 'permission denied');
select test.expect_error($$update public.professional_profiles set rating_avg = 5 where user_id = auth.uid()$$, 'permission denied');
select test.expect_error($$select public.submit_professional_application()$$, 'HMY_DOCUMENTS_REQUIRED');
insert into public.professional_services (professional_id, category_id, specialty, price_from) values (auth.uid(), 1, 'Plomería general', 80);
insert into public.professional_zones (professional_id, zone_id) values (auth.uid(), 1);
insert into public.professional_documents (professional_id, doc_type, storage_path) values (auth.uid(), 'ci_anverso', auth.uid() || '/ci.jpg');
select test.eq(public.submit_professional_application()::text, 'submitted', 'el profesional envía su postulación');
select test.expect_error($$select public.review_professional_application(auth.uid(), 'approved')$$, 'HMY_FORBIDDEN');
select test.logout();

-- Un cliente no ve a profesionales no aprobados
select test.login(null);
select test.eq((select count(*)::int from public.search_professionals()), 0, 'búsqueda no muestra postulaciones pendientes');
select test.eq((select count(*)::int from public.professional_profiles), 0, 'la tabla de profesionales no es pública');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000000b1', 'rejected')$$, 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000000b1', 'approved')$$, 'HMY_ID_DOCUMENTS_REQUIRED');
select test.eq((select status from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000b1')::text, 'submitted',
               'sin carnet aceptado no se puede aprobar');
select test.accept_id('00000000-0000-0000-0000-0000000000b1');
select public.review_professional_application('00000000-0000-0000-0000-0000000000b1', 'approved', 'Documentos correctos');
select test.logout();

do $$ begin
  perform test.eq(public.has_role('professional', '00000000-0000-0000-0000-0000000000b1'), true, 'aprobar concede el rol profesional');
  perform test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000b1'), 0.00::numeric, 'aprobar crea la billetera en Bs 0');
  perform test.eq((select count(*)::int from public.verification_events where professional_id = '00000000-0000-0000-0000-0000000000b1'), 2, 'historial de verificación registrado');
end $$;

select test.login(null);
do $$ begin
  perform test.eq((select count(*)::int from public.search_professionals()), 1, 'búsqueda anónima muestra profesionales aprobados');
  perform test.eq((select count(*)::int from public.search_professionals(p_query => 'plomeria')), 1, 'búsqueda sin tildes encuentra Plomería');
  perform test.eq((select count(*)::int from public.search_professionals(p_query => 'pintor')), 0, 'búsqueda sin coincidencias');
  perform test.eq((select count(*)::int from public.search_professionals(p_available_now => true)), 0, 'filtro disponible ahora');
  perform test.eq((select zones[1] from public.search_professionals()), 'Centro', 'muestra solo la zona general');
  perform test.eq((select count(*)::int from public.professional_documents), 0, 'documentos de identidad no son públicos');
end $$;
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000b1');
select public.set_active_role('professional');
select public.set_availability(true);
select test.logout();

-- Segundo profesional aprobado (para pruebas de privacidad)
select test.login('00000000-0000-0000-0000-0000000000b2');
select public.start_professional_application();
update public.professional_profiles set primary_category_id = 2 where user_id = auth.uid();
insert into public.professional_documents (professional_id, doc_type, storage_path) values (auth.uid(), 'ci_anverso', auth.uid() || '/ci.jpg');
select public.submit_professional_application();
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select test.accept_id('00000000-0000-0000-0000-0000000000b2');
select public.review_professional_application('00000000-0000-0000-0000-0000000000b2', 'approved');
select test.logout();

-- 4. Reserva inmediata, privacidad y comisiones
select test.login('00000000-0000-0000-0000-00000000000a');
insert into public.commission_rules (name, reserve_amount, fixed_fee, min_balance, capture_at)
values ('Prueba', 10, 15, 20, 'completed');
insert into public.topup_methods (name, instructions) values ('QR', 'Escanea el QR');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error($$select public.create_booking('00000000-0000-0000-0000-0000000000b2', 2, 'now', 'Se cortó la luz', 'Calle 1')$$, 'HMY_PROFESSIONAL_NOT_AVAILABLE');
create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;
insert into t_ids select 'b1', public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'now',
  'Se rompió la cañería del baño', 'Av. Banzer 123, 4to anillo', 'Casa verde', 1, null, 120, 'cash');
select test.expect_error($$insert into public.bookings (customer_id, category_id, city_id, mode, description) values (auth.uid(), 1, 1, 'now', 'directo')$$, 'permission denied');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000b1');
do $$ begin
  perform test.eq((select count(*)::int from public.bookings), 1, 'el profesional ve la solicitud');
  perform test.eq((select count(*)::int from public.booking_addresses), 0, 'dirección oculta antes de aceptar');
  perform test.eq((select count(*)::int from public.notifications where kind = 'booking_new'), 1, 'el profesional recibe notificación');
end $$;
select test.expect_error(format('select public.accept_booking(%L)', (select v from t_ids where k = 'b1')), 'HMY_INSUFFICIENT_BALANCE');
select test.expect_error($$select public.request_topup(100, 999, null, null, 'password', gen_random_uuid())$$, 'HMY_INVALID_METHOD');
create temp table t_topup as select public.request_topup(100, (select id from public.topup_methods limit 1), 'REF-1', null, 'password', gen_random_uuid()) as id;
select test.eq((select available from public.wallets), 0.00::numeric, 'pedir recarga no acredita saldo');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000b2');
select test.eq((select count(*)::int from public.bookings), 0, 'otro profesional no ve la solicitud');
select test.expect_error(format('select public.accept_booking(%L)', (select v from t_ids where k = 'b1')), 'HMY_FORBIDDEN');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_topup((select id from t_topup), true, 'Pago verificado');
select test.expect_error(format('select public.review_topup(%s, true)', (select id from t_topup)), 'HMY_ALREADY_REVIEWED');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000b1');
select test.eq((select available from public.wallets), 100.00::numeric, 'recarga aprobada acredita Bs 100');
select test.eq(public.accept_booking((select v from t_ids where k = 'b1'))::text, 'confirmed', 'el profesional acepta');
select test.expect_error(format('select public.accept_booking(%L)', (select v from t_ids where k = 'b1')), 'HMY_INVALID_TRANSITION');
do $$ begin
  perform test.eq((select available from public.wallets), 90.00::numeric, 'aceptar reserva la comisión (disponible)');
  perform test.eq((select reserved from public.wallets), 10.00::numeric, 'aceptar reserva la comisión (reservado)');
  perform test.eq((select count(*)::int from public.booking_addresses), 1, 'dirección visible después de aceptar');
  perform test.eq((select count(*)::int from public.conversations), 1, 'se abre el chat al confirmar');
end $$;
select test.expect_error($$update public.wallets set available = 9999$$, 'permission denied');
select test.expect_error($$insert into public.wallet_ledger (professional_id, entry_type, available_delta, available_after, reserved_after, idempotency_key) values (auth.uid(), 'topup', 1000, 1000, 0, 'x')$$, 'permission denied');
select public.send_message((select id from public.conversations limit 1), 'Voy en camino, llego en 20 minutos');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000c1');
do $$ begin
  perform test.eq((select unread_count from public.my_conversations()), 1, 'el cliente tiene 1 mensaje sin leer');
  perform public.mark_conversation_read((select id from public.conversations limit 1));
  perform test.eq((select unread_count from public.my_conversations()), 0, 'marcar como leído');
end $$;
select test.expect_error(format('select public.confirm_completion(%L)', (select v from t_ids where k = 'b1')), 'HMY_INVALID_TRANSITION');
select test.expect_error(format('select public.submit_review(%L, 5)', (select v from t_ids where k = 'b1')), 'HMY_REVIEW_NOT_ALLOWED');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000c2');
do $$ begin
  perform test.eq((select count(*)::int from public.messages), 0, 'un tercero no lee mensajes ajenos');
  perform test.eq((select count(*)::int from public.bookings), 0, 'un tercero no ve reservas ajenas');
end $$;
select test.expect_error(format('select public.send_message(%L, %L)', (select id from public.conversations limit 1), 'hola'), 'HMY_FORBIDDEN|permission denied|null');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000b1');
select public.update_job_progress((select v from t_ids where k = 'b1'), 'on_the_way');
select test.arrive((select v from t_ids where k = 'b1')::uuid, '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c1');
select public.update_job_progress((select v from t_ids where k = 'b1'), 'in_progress');
select public.update_job_progress((select v from t_ids where k = 'b1'), 'work_finished', 250);
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000c1');
select public.acknowledge_payment((select v from t_ids where k = 'b1'), 'cash');
select test.eq(public.confirm_completion((select v from t_ids where k = 'b1'))::text, 'completed', 'el cliente confirma el trabajo');
select public.submit_review((select v from t_ids where k = 'b1'), 5, 'Muy puntual y prolijo');
select test.expect_error(format('select public.submit_review(%L, 4)', (select v from t_ids where k = 'b1')), 'duplicate key');
select test.logout();

do $$
declare v_b uuid := (select v from t_ids where k = 'b1');
begin
  perform test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000b1'), 85.00::numeric, 'al completar se cobra la comisión fija de Bs 15');
  perform test.eq((select reserved from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000b1'), 0.00::numeric, 'la reserva se libera al cobrar');
  perform public._commission_capture(v_b);
  perform test.eq((select available from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000b1'), 85.00::numeric, 'cobrar dos veces no duplica el cargo');
  perform test.eq((select count(*)::int from public.wallet_ledger where booking_id = v_b), 2, 'libro mayor: reserva + cobro');
  perform test.eq((select rating_avg from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000b1'), 5.00::numeric, 'calificación calculada de reseñas reales');
  perform test.eq((select completed_jobs from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000b1'), 1, 'trabajos completados');
  perform test.eq((select count(*)::int from public.booking_events where booking_id = v_b), 6, 'historial de estados completo');
  perform test.eq((select customer_paid_ack_at is not null from public.bookings where id = v_b), true, 'pago confirmado por el cliente');
  perform test.eq((select professional_paid_ack_at is null from public.bookings where id = v_b), true, 'pago del profesional se registra aparte');
end $$;
select test.expect_error($$update public.wallet_ledger set available_delta = 0$$, 'HMY_LEDGER_APPEND_ONLY');
select test.expect_error($$delete from public.wallet_ledger$$, 'HMY_LEDGER_APPEND_ONLY');

-- 5. Cancelar libera la reserva
select test.login('00000000-0000-0000-0000-0000000000c1');
insert into t_ids select 'b2', public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'now', 'Gotea el grifo de la cocina', 'Calle Sucre 45');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
select public.accept_booking((select v from t_ids where k = 'b2'));
select test.eq((select reserved from public.wallets), 10.00::numeric, 'segunda reserva retenida');
select test.expect_error(format('select public.cancel_booking(%L, %L)', (select v from t_ids where k = 'b2'), ''), 'HMY_REASON_REQUIRED');
select public.cancel_booking((select v from t_ids where k = 'b2'), 'Emergencia familiar');
select test.eq((select reserved from public.wallets), 0.00::numeric, 'cancelar libera la reserva');
select test.eq((select available from public.wallets), 85.00::numeric, 'cancelar devuelve el saldo');
select test.logout();

-- 6. Cotización y disputa
select test.login('00000000-0000-0000-0000-0000000000c1');
insert into t_ids select 'b3', public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'now', 'Cambiar todas las cañerías', 'Calle Sucre 45');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
select test.eq(public.send_quote((select v from t_ids where k = 'b3'), 1200, 'Incluye materiales')::text, 'quote_sent', 'el profesional envía cotización');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq(public.respond_quote((select v from t_ids where k = 'b3'), true)::text, 'confirmed', 'el cliente acepta la cotización');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
select public.update_job_progress((select v from t_ids where k = 'b3'), 'on_the_way');
select test.arrive((select v from t_ids where k = 'b3')::uuid, '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c1');
select public.update_job_progress((select v from t_ids where k = 'b3'), 'in_progress');
select public.update_job_progress((select v from t_ids where k = 'b3'), 'work_finished');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq(public.open_dispute((select v from t_ids where k = 'b3'), 'Quedó una fuga')::text, 'disputed', 'el cliente abre una disputa');
select test.expect_error(format('select public.confirm_completion(%L)', (select v from t_ids where k = 'b3')), 'HMY_INVALID_TRANSITION');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
select test.expect_error(format('select public.update_job_progress(%L, %L)', (select v from t_ids where k = 'b3'), 'work_finished'), 'HMY_INVALID_TRANSITION');
select test.eq((select reserved from public.wallets), 10.00::numeric, 'la reserva se mantiene durante la disputa');
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq(public.resolve_dispute((select v from t_ids where k = 'b3'), 'cancelled', 'Se reembolsa por trabajo incompleto')::text, 'cancelled', 'el admin resuelve la disputa');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'dispute.resolve'), 1, 'auditoría de la resolución');
select test.logout();
select test.eq((select reserved from public.wallets where professional_id = '00000000-0000-0000-0000-0000000000b1'), 0.00::numeric, 'resolver con cancelación libera la reserva');

-- 7. Reservas programadas sin cruces
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error($$select public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'scheduled', 'Instalar ducha', 'Calle 1', null, null, now() + interval '5 minutes')$$, 'HMY_INVALID_SCHEDULE');
insert into t_ids select 's1', public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'scheduled', 'Instalar ducha eléctrica', 'Calle 1', null, null, date_trunc('hour', now()) + interval '2 days', 120);
insert into t_ids select 's2', public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'scheduled', 'Revisar el tanque de agua', 'Calle 1', null, null, date_trunc('hour', now()) + interval '2 days 1 hour', 60);
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
select public.accept_booking((select v from t_ids where k = 's1'));
select test.expect_error(format('select public.accept_booking(%L)', (select v from t_ids where k = 's2')), 'bookings_no_overlap|conflicting key');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c2');
select test.expect_error($$select public.create_booking('00000000-0000-0000-0000-0000000000b1', 1, 'scheduled', 'Otra cosa en el mismo horario', 'Calle 2', null, null, date_trunc('hour', now()) + interval '2 days 30 minutes', 60)$$, 'HMY_SLOT_TAKEN');
select test.logout();

-- 8. Tareas automáticas: solicitudes sin respuesta
update public.bookings set response_deadline = now() - interval '1 minute' where id = (select v from t_ids where k = 's2');
select test.eq(public.run_booking_housekeeping() >= 1, true, 'vence solicitudes sin respuesta');
select test.eq((select status::text from public.bookings where id = (select v from t_ids where k = 's2')), 'cancelled', 'solicitud vencida queda cancelada');

-- 9. Almacenamiento privado
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error($$insert into storage.objects (bucket_id, name, owner) values ('professional-documents', '00000000-0000-0000-0000-0000000000b1/ci.jpg', auth.uid())$$, 'row-level security');
insert into storage.objects (bucket_id, name, owner) values ('avatars', auth.uid() || '/foto.jpg', auth.uid());
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000b1');
insert into storage.objects (bucket_id, name, owner) values ('professional-documents', auth.uid() || '/ci.jpg', auth.uid());
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c2');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'professional-documents'), 0, 'documentos privados invisibles para otros');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'avatars'), 1, 'fotos de perfil públicas');
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'professional-documents'), 1, 'el admin ve documentos para verificar');
select test.logout();

-- 10. Suspender quita el modo profesional
select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000000b1', 'suspended', 'Reclamos repetidos');
select test.logout();
do $$ begin
  perform test.eq((select active_role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'), 'customer', 'suspender devuelve al modo cliente');
  perform test.eq((select count(*)::int from public.search_professionals()), 1, 'suspendido sale de la búsqueda');
end $$;
select test.login('00000000-0000-0000-0000-0000000000b1');
select test.expect_error($$select public.set_active_role('professional')$$, 'HMY_PROFESSIONAL_NOT_APPROVED');
select test.logout();

\o
\echo 'TODAS LAS PRUEBAS PASARON'
