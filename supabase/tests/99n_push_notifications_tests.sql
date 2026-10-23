-- Avisos push (0045): registro del teléfono, cola por aviso, texto sin datos
-- personales, estado veraz y permisos. Cuentas propias (…9a5000…); ningún
-- dato real cambia y nada sale a Firebase (la función send-push no corre aquí).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a50001', '59170098501', now(), '{"full_name": "Dueño Push"}'),
  ('00000000-0000-0000-0000-000009a50002', '59170098502', now(), '{"full_name": "Gerente Push"}'),
  ('00000000-0000-0000-0000-000009a50003', '59170098503', now(), '{"full_name": "Cliente Push"}'),
  ('00000000-0000-0000-0000-000009a50004', '59170098504', now(), '{"full_name": "Otra Persona Push"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a50001', 'admin');
select test.grant('00000000-0000-0000-0000-000009a50001', '00000000-0000-0000-0000-000009a50002', 'manager');
select test.logout();

-- Sin sesión no se registra nada.
select test.login(null);
select test.expect_error($$select public.register_push_device('tok-anon-00000000000000000000', 'web')$$, 'permission denied');
select test.logout();

-- Sin teléfono registrado, la prueba avisa con un error claro.
select test.login('00000000-0000-0000-0000-000009a50003');
select test.expect_error('select public.send_test_push()', 'HMY_NO_PUSH_DEVICE');
select test.expect_error($$select public.register_push_device('corto', 'web')$$, 'HMY_INVALID');
select test.expect_error($$select public.register_push_device('tok-cliente-0000000000000000000', 'blackberry')$$, 'HMY_INVALID');
select public.register_push_device('tok-cliente-0000000000000000000', 'web');
select public.register_push_device('tok-cliente-0000000000000000000', 'web'); -- repetir no duplica
select test.eq((public.my_push_status() ->> 'devices')::int, 1, 'un teléfono activo');
select test.eq((select count(*)::int from public.push_devices), 1, 'la persona ve solo su teléfono');
select test.expect_error('select token from public.push_devices', 'permission denied');
select test.eq((select count(*)::int from public.push_outbox), 0, 'la cola de envíos solo la ve el propietario');
select test.expect_error($$insert into public.push_devices (user_id, token, platform)
                           values ('00000000-0000-0000-0000-000009a50003', 'tok-directo-000000000000000000', 'web')$$,
                         'permission denied');
select test.logout();

-- Un aviso nuevo queda en cola para ese teléfono, con texto fijo.
select public.notify('00000000-0000-0000-0000-000009a50003', 'message', 'Nuevo mensaje',
                     'Mi dirección es Calle Falsa 123', '{"conversation_id": "c1", "booking_id": "b1"}');
select test.eq((select count(*)::int from public.push_outbox o join public.push_devices d on d.id = o.device_id
                where d.token = 'tok-cliente-0000000000000000000' and o.status = 'pending'), 1, 'el aviso queda en cola');

-- Un teléfono pasa a quien inició sesión en él: la cuenta anterior ya no recibe.
select test.login('00000000-0000-0000-0000-000009a50004');
select public.register_push_device('tok-cliente-0000000000000000000', 'android');
select test.logout();
select public.notify('00000000-0000-0000-0000-000009a50003', 'booking_status', 'Tu pedido cambió', '');
select test.eq((select count(*)::int from public.push_outbox o join public.notifications n on n.id = o.notification_id
                where n.user_id = '00000000-0000-0000-0000-000009a50003' and n.kind = 'booking_status'), 0,
               'la cuenta anterior no recibe avisos en un teléfono que ya no es suyo');
select test.login('00000000-0000-0000-0000-000009a50003');
select test.eq((public.my_push_status() ->> 'devices')::int, 0, 'el teléfono dejó de contar para la cuenta anterior');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a50004');
select public.unregister_push_device('tok-cliente-0000000000000000000');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a50003');
select public.register_push_device('tok-cliente-0000000000000000000', 'web');
select test.logout();
select public.notify('00000000-0000-0000-0000-000009a50003', 'message', 'Nuevo mensaje',
                     'Mi dirección es Calle Falsa 123', '{"conversation_id": "c1", "booking_id": "b1"}');

-- Solo el servidor reclama y reporta envíos.
select test.login('00000000-0000-0000-0000-000009a50003');
select test.expect_error('select public.hmy_push_claim(10)', 'permission denied');
select test.expect_error($$select public.hmy_push_report('[]')$$, 'permission denied');
select test.logout();

create temp table claimed as select public.hmy_push_claim(10) as c;
select test.eq((select jsonb_array_length(c) from claimed), 1, 'reclama el envío pendiente');
select test.eq((select c -> 0 ->> 'body' from claimed), 'Ábrelo para leerlo.', 'el push no lleva el texto del mensaje');
select test.eq((select position('Calle Falsa' in c::text) from claimed), 0, 'ningún dato escrito por una persona sale en el push');
select test.eq((select c -> 0 -> 'data' ->> 'conversation_id' from claimed), 'c1', 'lleva a la conversación al tocarlo');
select test.eq((select jsonb_array_length(public.hmy_push_claim(10))), 0, 'no se reclama dos veces');

-- Firebase lo acepta: queda "sent" (aceptado, no "entregado").
select public.hmy_push_report(jsonb_build_array(jsonb_build_object('id', (select (c -> 0 ->> 'id')::bigint from claimed), 'ok', true)));
select test.login('00000000-0000-0000-0000-000009a50003');
select test.eq(public.my_push_status() ->> 'last_status', 'sent', 'estado: aceptado por Firebase');

-- Prueba: una por minuto.
select test.eq(public.send_test_push(), 1, 'la prueba sale a un teléfono');
select test.expect_error('select public.send_test_push()', 'HMY_RATE_LIMITED');
select test.logout();

-- Error temporal: vuelve a la cola. Token no registrado: el teléfono se apaga.
create temp table claimed2 as select public.hmy_push_claim(10) as c;
select test.eq((select c -> 0 ->> 'title' from claimed2), 'Aviso de prueba', 'la prueba se reclama');
select public.hmy_push_report(jsonb_build_array(jsonb_build_object('id', (select (c -> 0 ->> 'id')::bigint from claimed2),
                                                                   'ok', false, 'error', 'UNAVAILABLE', 'retry', true)));
select test.eq((select status from public.push_outbox where id = (select (c -> 0 ->> 'id')::bigint from claimed2)), 'pending',
               'un error temporal se reintenta');
create temp table claimed3 as select public.hmy_push_claim(10) as c;
select public.hmy_push_report(jsonb_build_array(jsonb_build_object('id', (select (c -> 0 ->> 'id')::bigint from claimed3),
                                                                   'ok', false, 'error', 'UNREGISTERED', 'unregistered', true)));
select test.eq((select status from public.push_outbox where id = (select (c -> 0 ->> 'id')::bigint from claimed3)), 'failed',
               'un token no registrado falla');
select test.eq((select disabled_reason from public.push_devices where token = 'tok-cliente-0000000000000000000'), 'unregistered',
               'y su teléfono se apaga');
select test.login('00000000-0000-0000-0000-000009a50003');
select test.eq(public.my_push_status() ->> 'last_status', 'failed', 'estado veraz: falló');
select test.eq((public.my_push_status() ->> 'devices')::int, 0, 'sin teléfonos activos');
select test.logout();

-- Lo viejo no se manda.
select test.login('00000000-0000-0000-0000-000009a50003');
select public.register_push_device('tok-cliente-0000000000000000000', 'web');
select test.logout();
select public.notify('00000000-0000-0000-0000-000009a50003', 'booking_status', 'Viejo', '');
update public.push_outbox set created_at = now() - interval '25 hours' where status = 'pending';
select test.eq((select jsonb_array_length(public.hmy_push_claim(10))), 0, 'un aviso de hace más de 24 horas no se manda');
select test.eq((select count(*)::int from public.push_outbox where status = 'expired'), 1, 'queda como vencido');

-- Propietario: resumen sin tokens; el gerente no lo ve.
select test.login('00000000-0000-0000-0000-000009a50002');
select test.expect_error('select public.owner_push_overview()', 'HMY_FORBIDDEN');
select test.logout();
select test.login('00000000-0000-0000-0000-000009a50001');
select test.eq((public.owner_push_overview() -> 'devices' ->> 'web')::int >= 1, true, 'resumen: teléfonos por plataforma');
select test.eq(position('tok-' in public.owner_push_overview()::text), 0, 'resumen: sin tokens');
select test.logout();

-- Cuentas de prueba: borrar los teléfonos para que los avisos de otras pruebas no se encolen.
delete from public.push_devices where user_id::text like '00000000-0000-0000-0000-000009a5%';

\o
\echo 'PRUEBAS DE AVISOS PUSH PASARON'
