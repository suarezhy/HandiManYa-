-- Pruebas de la confirmación de identidad para recargas de saldo (0011):
-- contraseña reciente, huella o rostro activados, intentos repetidos,
-- confirmaciones vencidas o reutilizadas, auditoría y que el saldo solo sube
-- cuando el equipo aprueba el pago. Corre después de 50_service_problems_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000061', 'pro60@test.bo', '{"full_name":"Rosa Choque","city_id":"1"}'),
  ('00000000-0000-0000-0000-000000000062', 'cli60@test.bo', '{"full_name":"Luis Vargas","city_id":"1"}');

-- Inicio de sesión con contraseña hace p_seconds_ago segundos (null: sin contraseña en el JWT).
create function test.login_pw(p_user uuid, p_seconds_ago int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'role', 'authenticated',
    'amr', case when p_seconds_ago is null then json_build_array()
                else json_build_array(json_build_object('method', 'password',
                                      'timestamp', extract(epoch from now())::bigint - p_seconds_ago)) end)::text, false);
  execute 'set role authenticated';
end $$;

-- Una profesional aprobada, con billetera en cero.
do $$
declare v uuid := '00000000-0000-0000-0000-000000000061';
begin
  perform test.login(v);
  perform public.start_professional_application();
  update public.professional_profiles
  set primary_category_id = (select id from public.service_categories where slug = 'plomeria') where user_id = v;
  insert into public.professional_documents (professional_id, doc_type, storage_path) values (v, 'ci_anverso', v || '/ci.jpg');
  perform public.submit_professional_application();
  perform test.logout();
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform public.review_professional_application(v, 'approved');
  perform test.logout();
end $$;

create temp table t_w (k text primary key, v text);
grant all on t_w to authenticated, anon;
insert into t_w values ('method', (select min(id)::text from public.topup_methods)),
                       ('key1', gen_random_uuid()::text), ('key2', gen_random_uuid()::text),
                       ('key3', gen_random_uuid()::text), ('key4', gen_random_uuid()::text);

-- 1. Quien no tiene billetera no puede pedir recargas
select test.login_pw('00000000-0000-0000-0000-000000000062', 5);
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'password', gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_WALLET_NOT_FOUND');
select test.logout();

-- 2. Confirmación vencida, ausente o desconocida: no se crea nada
select test.login_pw('00000000-0000-0000-0000-000000000061', 600);
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'password', gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_CONFIRMATION_EXPIRED');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', null);
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'password', gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_CONFIRMATION_EXPIRED');
select test.expect_error(format($$select public.request_topup(100, %s, null, null, null, gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_CONFIRMATION_REQUIRED');
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'pin', gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_CONFIRMATION_REQUIRED');
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'password', null)$$,
                                (select v from t_w where k = 'method')), 'HMY_CONFIRMATION_REQUIRED');
select test.expect_error(format($$select public.request_topup(100, %s, null, null, 'biometric', gen_random_uuid())$$,
                                (select v from t_w where k = 'method')), 'HMY_BIOMETRIC_DISABLED');
select test.eq((select count(*)::int from public.topup_requests), 0, 'confirmación: sin confirmación válida no se crea ninguna solicitud');
select test.logout();

-- 3. Montos inválidos
select test.login_pw('00000000-0000-0000-0000-000000000061', 5);
do $$
declare a numeric;
begin
  foreach a in array array[0, -5, 10.005, 20000]::numeric[] loop
    perform test.expect_error(format($q$select public.request_topup(%s, %s, null, null, 'password', gen_random_uuid())$q$,
                                     a, (select v from t_w where k = 'method')), 'HMY_INVALID_AMOUNT');
  end loop;
end $$;

-- 4. Contraseña recién confirmada: crea la solicitud pendiente, sin acreditar
insert into t_w select 'id1', public.request_topup(150.50, (select v from t_w where k = 'method')::int, 'QR-123', null,
                                                   'password', (select v from t_w where k = 'key1')::uuid)::text;
do $$ begin
  perform test.eq((select status::text from public.topup_requests where id = (select v from t_w where k = 'id1')::bigint),
                  'pending', 'recarga: queda pendiente de verificación');
  perform test.eq((select auth_method from public.topup_requests where id = (select v from t_w where k = 'id1')::bigint),
                  'password', 'recarga: guarda con qué se confirmó');
  perform test.eq((select available from public.wallets), 0.00::numeric, 'recarga: pedirla no acredita saldo');
end $$;

-- 5. El mismo intento repetido (doble toque o reintento) devuelve la misma solicitud
select test.eq(public.request_topup(150.50, (select v from t_w where k = 'method')::int, 'QR-123', null,
                                    'password', (select v from t_w where k = 'key1')::uuid)::text,
               (select v from t_w where k = 'id1'), 'repetida: devuelve la misma solicitud');
select test.eq((select count(*)::int from public.topup_requests), 1, 'repetida: no crea una segunda solicitud');

-- 6. Una confirmación sirve para una sola recarga
select test.expect_error(format($$select public.request_topup(80, %s, null, null, 'password', %L)$$,
                                (select v from t_w where k = 'method'), (select v from t_w where k = 'key2')), 'HMY_CONFIRMATION_USED');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', 2);
select test.eq(public.request_topup(80, (select v from t_w where k = 'method')::int, null, null,
                                    'password', (select v from t_w where k = 'key2')::uuid) > 0, true,
               'confirmación: una contraseña nueva permite otra recarga');

-- 7. Huella o rostro: solo si se activó con la contraseña
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', 600);
select test.expect_error($$select public.set_biometric_enabled(true)$$, 'HMY_CONFIRMATION_EXPIRED');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', 1);
select public.set_biometric_enabled(true);
select test.eq((select biometric_enabled from public.security_settings), true, 'seguridad: huella o rostro activados');
select test.expect_error($$update public.security_settings set biometric_enabled = false$$, 'permission denied');
select test.expect_error($$insert into public.security_confirmations values (auth.uid(), 1, 'x')$$, 'permission denied');
select test.expect_error($$select public.hmy_require_confirmation('biometric', 'x')$$, 'permission denied');
select test.expect_error(format($$insert into public.topup_requests (professional_id, method_id, amount) values (auth.uid(), %s, 10)$$,
                                (select v from t_w where k = 'method')), 'permission denied|row-level security');
select test.eq(public.request_topup(60, (select v from t_w where k = 'method')::int, null, null,
                                    'biometric', (select v from t_w where k = 'key3')::uuid) > 0, true,
               'huella o rostro: crea la solicitud');
select test.eq((select auth_method from public.topup_requests where client_key = (select v from t_w where k = 'key3')::uuid),
               'biometric', 'huella o rostro: queda registrado el método');

-- 8. Límite de solicitudes pendientes
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', 3);
select test.expect_error(format($$select public.request_topup(40, %s, null, null, 'password', %L)$$,
                                (select v from t_w where k = 'method'), (select v from t_w where k = 'key4')), 'HMY_TOO_MANY_PENDING');
select test.eq((select count(*)::int from public.security_settings where user_id <> auth.uid()), 0, 'seguridad: nadie ve la configuración de otros');
select test.logout();

-- 9. Otro usuario no ve las solicitudes ni la configuración ajena
select test.login_pw('00000000-0000-0000-0000-000000000062', 4);
select test.eq((select count(*)::int from public.topup_requests), 0, 'recarga: otro usuario no ve las solicitudes');
select test.eq((select count(*)::int from public.security_settings), 0, 'seguridad: otro usuario no ve la configuración');
select test.logout();

-- 10. Auditoría y acreditación solo al aprobar
select test.login('00000000-0000-0000-0000-00000000000a');
do $$ begin
  perform test.eq((select count(*)::int from public.admin_audit_log where action = 'topup.request'
                   and actor_id = '00000000-0000-0000-0000-000000000061'), 3, 'auditoría: cada solicitud queda registrada');
  perform test.eq((select details ->> 'auth_method' from public.admin_audit_log where action = 'topup.request'
                   and target_id = (select v from t_w where k = 'id1')), 'password', 'auditoría: registra el método de confirmación');
  perform test.eq((select count(*)::int from public.admin_audit_log where action = 'security.biometric_on'
                   and actor_id = '00000000-0000-0000-0000-000000000061'), 1, 'auditoría: activar la huella queda registrado');
end $$;
select public.review_topup((select v from t_w where k = 'id1')::bigint, true, 'Pago verificado');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-000000000061', 5);
select test.eq((select available from public.wallets), 150.50::numeric, 'recarga: el saldo sube solo cuando el equipo aprueba');

-- 11. Desactivar no pide contraseña, y después la huella ya no sirve
select public.set_biometric_enabled(false);
select test.eq((select biometric_enabled from public.security_settings), false, 'seguridad: huella o rostro desactivados');
select test.expect_error(format($$select public.request_topup(40, %s, null, null, 'biometric', %L)$$,
                                (select v from t_w where k = 'method'), (select v from t_w where k = 'key4')), 'HMY_BIOMETRIC_DISABLED');
select test.logout();
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'security.biometric_off'
                and actor_id = '00000000-0000-0000-0000-000000000061'), 1, 'auditoría: desactivar la huella queda registrado');
select test.logout();

\o
\echo 'PRUEBAS DE CONFIRMACIÓN DE RECARGAS PASARON'
