-- Pruebas del ingreso con celular (0013): el número verificado pasa al perfil,
-- un número es una sola cuenta, las cuentas antiguas no bloquean a quien
-- verificó, nombre/ciudad/términos después del código, cambio de número,
-- confirmación con código nuevo y límites de envío. Corre después de 70.
-- Usa números de prueba +59160000 80x (no son reales).
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_ph (k text primary key, v text);
grant all on t_ph to authenticated, anon;

-- Inicio de sesión con código (amr "otp") hace p_seconds_ago segundos.
create function test.login_otp(p_user uuid, p_seconds_ago int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method', 'otp',
                            'timestamp', extract(epoch from now())::bigint - p_seconds_ago)))::text, false);
  execute 'set role authenticated';
end $$;

-- 1. Cuenta nueva por celular: Supabase la crea al pedir el código (sin
--    verificar) y la confirma al verificarlo. Sin correo ni contraseña.
insert into auth.users (id, phone) values ('00000000-0000-0000-0000-000000000081', '59160000801');
do $$ begin
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000081'), '+59160000801',
                  'celular: el perfil nace con el número de Supabase Auth');
  perform test.eq((select phone_verified_at from public.profiles where id = '00000000-0000-0000-0000-000000000081') is null,
                  true, 'celular: todavía sin verificar');
  perform test.eq((select count(*)::int from public.user_roles where user_id = '00000000-0000-0000-0000-000000000081'), 1,
                  'celular: la cuenta nueva empieza como cliente');
end $$;
update auth.users set phone_confirmed_at = now() where id = '00000000-0000-0000-0000-000000000081';
select test.eq((select phone_verified_at from public.profiles where id = '00000000-0000-0000-0000-000000000081') is not null,
               true, 'celular: verificado al confirmar el código');

-- 2. Un número, una cuenta
select test.expect_error($$insert into auth.users (id, phone) values ('00000000-0000-0000-0000-000000000089', '59160000801')$$,
                         'duplicate key|unique');
select test.expect_error($$update public.profiles set phone = '+59160000801' where id = '00000000-0000-0000-0000-000000000062'$$,
                         'duplicate key|unique');

-- 3. Después del código: nombre, ciudad y términos
select test.login_otp('00000000-0000-0000-0000-000000000081', 5);
select test.eq((public.my_account() ->> 'profile_complete')::boolean, false, 'perfil: falta nombre y ciudad');
select test.eq(public.my_account() ->> 'email', null::text, 'perfil: sin correo, y está bien');
select test.eq((public.my_account() ->> 'phone_verified')::boolean, true, 'perfil: celular verificado');
select test.expect_error($$select public.complete_signup('Jo', 1::smallint, true)$$, 'HMY_INVALID_NAME');
select test.expect_error($$select public.complete_signup('Juana Mamani', 999::smallint, true)$$, 'HMY_INVALID_CITY');
select test.expect_error($$select public.complete_signup('Juana Mamani', 1::smallint, false)$$, 'HMY_TERMS_REQUIRED');
select public.complete_signup('  Juana   Mamani ', 1::smallint, true);
do $$ begin
  perform test.eq(public.my_account() ->> 'full_name', 'Juana Mamani', 'perfil: guarda el nombre limpio');
  perform test.eq((public.my_account() ->> 'profile_complete')::boolean, true, 'perfil: completo');
end $$;
-- La app ya no puede escribir el celular ni la fecha de los términos.
select test.expect_error($$update public.profiles set phone = '+59160000809' where id = auth.uid()$$, 'permission denied');
select test.expect_error($$update public.profiles set terms_accepted_at = null where id = auth.uid()$$, 'permission denied');
update public.profiles set full_name = 'Juana Mamani Q.' where id = auth.uid();
select test.eq(public.my_account() ->> 'full_name', 'Juana Mamani Q.', 'perfil: el nombre se puede editar');
select test.logout();

-- 4. Una cuenta antigua (correo) con ese número escrito a mano no bloquea a
--    quien verifica el número, y no se pierde: queda sin celular.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000082', 'antigua80@test.bo', '{"full_name":"Cuenta Antigua","phone":"+59160000802"}');
select test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000082'), '+59160000802',
               'antigua: guarda el número que escribió (sin verificar)');
insert into auth.users (id, phone) values ('00000000-0000-0000-0000-000000000083', '59160000802');
select test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000083'), null::text,
               'antigua: la cuenta nueva espera a verificar para tomar el número');
update auth.users set phone_confirmed_at = now() where id = '00000000-0000-0000-0000-000000000083';
do $$ begin
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000083'), '+59160000802',
                  'antigua: quien verificó se queda con el número');
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000082'), null::text,
                  'antigua: la cuenta antigua queda sin ese número');
  perform test.eq((select count(*)::int from public.admin_audit_log
                   where action = 'auth.phone_released' and target_id = '+59160000802'), 1,
                  'antigua: queda registrado para el equipo');
end $$;

-- 5. Cuenta antigua por correo que agrega su celular (cambio de número):
--    conserva su id, pedidos y billetera.
update auth.users set phone = '59160000804', phone_confirmed_at = now() where id = '00000000-0000-0000-0000-000000000061';
do $$ begin
  perform test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000061'), '+59160000804',
                  'cambio: la cuenta antigua pasa a entrar con su celular');
  perform test.eq((select count(*)::int from public.wallets where professional_id = '00000000-0000-0000-0000-000000000061'), 1,
                  'cambio: conserva su billetera');
  perform test.eq((select count(*)::int from public.admin_audit_log
                   where action = 'auth.phone_changed' and target_id = '00000000-0000-0000-0000-000000000061'), 1,
                  'cambio: queda auditado');
end $$;
update auth.users set phone = '59160000805', phone_confirmed_at = now() where id = '00000000-0000-0000-0000-000000000061';
select test.eq((select phone from public.profiles where id = '00000000-0000-0000-0000-000000000061'), '+59160000805',
               'cambio: un número nuevo verificado reemplaza al anterior');

-- 6. Confirmar operaciones de dinero con un código nuevo
update public.topup_requests set status = 'cancelled'
where professional_id = '00000000-0000-0000-0000-000000000061' and status = 'pending';
select test.login_otp('00000000-0000-0000-0000-000000000061', 400);
select test.expect_error(format($$select public.request_topup(50, %s, 'OTP-1', null, 'otp', %L)$$,
                                (select min(id) from public.topup_methods), gen_random_uuid()), 'HMY_CONFIRMATION_EXPIRED');
select test.logout();
select test.login_otp('00000000-0000-0000-0000-000000000061', 20);
select public.set_biometric_enabled(false);
insert into t_ph select 'topup', public.request_topup(50, (select min(id) from public.topup_methods), 'OTP-2', null, 'otp',
                                                      gen_random_uuid())::text;
select test.eq((select auth_method from public.topup_requests where id = (select v from t_ph where k = 'topup')::bigint), 'otp',
               'código: la recarga queda pendiente y registra el método');
select test.expect_error(format($$select public.request_topup(50, %s, 'OTP-3', null, 'otp', %L)$$,
                                (select min(id) from public.topup_methods), gen_random_uuid()), 'HMY_CONFIRMATION_USED');
select test.expect_error($$select public.set_biometric_enabled(true, 'otp')$$, 'HMY_CONFIRMATION_USED');
select test.logout();
select test.login_otp('00000000-0000-0000-0000-000000000061', 3);
select test.expect_error($$select public.set_biometric_enabled(true, 'biometric')$$, 'HMY_CONFIRMATION_REQUIRED');
select public.set_biometric_enabled(true, 'otp');
select test.eq((select biometric_enabled from public.security_settings where user_id = auth.uid()), true,
               'código: activa huella o rostro');
select test.logout();

-- 7. Límites de envío de códigos (solo el servicio de envío puede usarlos)
select test.login('00000000-0000-0000-0000-000000000062');
select test.expect_error($$select public.hmy_otp_gate('+59160000806', 'sms')$$, 'permission denied');
select test.eq((select count(*)::int from public.otp_sends), 0, 'envío: un usuario no ve el registro de envíos');
select test.logout();
do $$ begin
  perform test.eq((public.hmy_otp_gate('+15551234567', 'sms') ->> 'reason'), 'invalid_phone', 'envío: solo celulares de Bolivia');
  perform test.eq((public.hmy_otp_gate('59160000806', 'fax') ->> 'reason'), 'invalid_channel', 'envío: WhatsApp o SMS');
  perform test.eq((public.hmy_otp_gate('59160000806', 'whatsapp') ->> 'allowed')::boolean, true, 'envío: el primero pasa');
  perform test.eq((public.hmy_otp_gate('59160000806', 'sms') ->> 'reason'), 'too_soon', 'envío: espera un minuto para reenviar');
  perform test.eq((public.hmy_otp_gate('59160000806', 'sms') ->> 'retry_after')::int between 1 and 60, true,
                  'envío: dice cuánto esperar');
end $$;
update public.otp_sends set created_at = created_at - interval '2 minutes' where phone = '+59160000806';
-- La elección de la persona (WhatsApp o SMS) llega al servicio de envío.
select test.login(null);
select public.choose_code_channel('+59160000806', 'sms');
select test.expect_error($$select public.choose_code_channel('+59160000806', 'fax')$$, 'HMY_INVALID_CHANNEL');
select test.expect_error($$select public.choose_code_channel('+5491112345678', 'sms')$$, 'HMY_INVALID_PHONE');
select test.expect_error($$select * from public.otp_channel_choices$$, 'permission denied');
select test.logout();
do $$
declare g jsonb := public.hmy_otp_gate('59160000806');
begin
  perform test.eq(g ->> 'channel', 'sms', 'envío: usa el canal que eligió la persona');
  perform test.eq((public.hmy_otp_gate('59160000807') ->> 'channel'), 'whatsapp', 'envío: WhatsApp si no eligió');
end $$;
update public.otp_sends set created_at = created_at - interval '2 minutes' where phone = '+59160000806';
do $$
declare i int;
begin
  for i in 1..3 loop
    perform test.eq((public.hmy_otp_gate('59160000806', 'sms') ->> 'allowed')::boolean, true, 'envío: reenvío permitido');
    update public.otp_sends set created_at = created_at - interval '2 minutes' where phone = '+59160000806';
  end loop;
  perform test.eq((public.hmy_otp_gate('59160000806', 'sms') ->> 'reason'), 'hourly_limit', 'envío: máximo 5 por hora');
end $$;
select public.hmy_otp_result((select max(id) from public.otp_sends where allowed), false, 'twilio', 'sin saldo');
select test.eq((select error from public.otp_sends where id = (select max(id) from public.otp_sends where allowed)), 'sin saldo',
               'envío: guarda si el proveedor falló');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((select count(*)::int > 0 from public.otp_sends), true, 'envío: el equipo ve el registro');
select test.logout();

\o
\echo 'PRUEBAS DEL INGRESO CON CELULAR PASARON'
