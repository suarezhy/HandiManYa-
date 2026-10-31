-- Equipo: buscar cuentas y dar roles con confirmación (0039). Corre después de 99g.
-- Cuentas de prueba propias (…99h0…); ninguna cuenta real recibe un rol.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009b10001', '59170099501', now(), '{"full_name": "Dueña Equipo"}'),
  ('00000000-0000-0000-0000-000009b10002', '59177099502', now(), '{"full_name": "Rosa Quispe Mamani"}'),
  ('00000000-0000-0000-0000-000009b10003', '59170099503', now(), '{"full_name": "Juan Equipo"}'),
  ('00000000-0000-0000-0000-000009b10004', '59170099504', now(), '{"full_name": "Ana Equipo"}'),
  ('00000000-0000-0000-0000-000009b10005', '59170099505', null, '{"full_name": "Sin Confirmar Equipo"}'),
  ('00000000-0000-0000-0000-000009b10006', '59170099506', now(), '{"full_name": "Suspendida Equipo"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009b10001', 'admin');
update public.profiles set suspended_at = now(), suspension_reason = 'Prueba' where id = '00000000-0000-0000-0000-000009b10006';

-- Solo el Propietario busca cuentas para el equipo.
select test.login('00000000-0000-0000-0000-000009b10003');
select test.expect_error($$select * from public.owner_staff_candidates('Rosa')$$, 'HMY_FORBIDDEN');
select test.logout();

select test.login('00000000-0000-0000-0000-000009b10001');
-- Por celular, con o sin +591, con espacios: el mismo resultado, enmascarado.
select test.eq((select id from public.owner_staff_candidates('77099502')), '00000000-0000-0000-0000-000009b10002'::uuid,
               'buscar: ocho dígitos encuentran la cuenta');
select test.eq((select id from public.owner_staff_candidates('+591 7709 9502')), '00000000-0000-0000-0000-000009b10002'::uuid,
               'buscar: con +591 y espacios también');
select test.eq((select phone_masked from public.owner_staff_candidates('77099502')), '+591 7••• ••02',
               'buscar: el celular sale enmascarado');
select test.eq((select count(*)::int from public.owner_staff_candidates('77099502') where phone_masked like '%099%'), 0,
               'buscar: nunca el número completo');
-- Por nombre, sin tildes ni mayúsculas.
select test.eq((select id from public.owner_staff_candidates('rosa quispe')), '00000000-0000-0000-0000-000009b10002'::uuid,
               'buscar: por nombre');
-- Un número que no existe no devuelve nada (la app lo explica).
select test.eq((select count(*)::int from public.owner_staff_candidates('70000005')), 0,
               'buscar: un número sin cuenta no devuelve nada');
-- Cada cuenta dice si puede recibir un rol y, si no, por qué.
select test.eq((select reason from public.owner_staff_candidates('Sin Confirmar Equipo')), 'phone_unconfirmed',
               'buscar: sin celular confirmado no puede');
select test.eq((select reason from public.owner_staff_candidates('Suspendida Equipo')), 'suspended',
               'buscar: suspendida no puede');
select test.eq((select reason from public.owner_staff_candidates('Dueña Equipo')), 'self', 'buscar: el propietario no se da un rol');
select test.eq((select eligible from public.owner_staff_candidates('Juan Equipo')), true, 'buscar: cuenta disponible');

-- Dar un rol pide un código nuevo; por id, no por número.
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10003', 'employee', null)$$,
                         'HMY_CONFIRMATION_REQUIRED');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10003', 'employee', 'biometric')$$,
                         'HMY_CONFIRMATION_REQUIRED');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10005', 'employee', 'otp')$$,
                         'HMY_STAFF_ACCOUNT_REQUIRED');
select test.grant('00000000-0000-0000-0000-000009b10001', '00000000-0000-0000-0000-000009b10003', 'employee');
select test.grant('00000000-0000-0000-0000-000009b10001', '00000000-0000-0000-0000-000009b10004', 'employee');
select test.eq((select reason from public.owner_staff_candidates('Juan Equipo')), 'already_staff', 'buscar: ya es del equipo');
select test.otp('00000000-0000-0000-0000-000009b10001');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10003', 'employee', 'otp')$$,
                         'HMY_ALREADY_STAFF');

-- Un empleado no puede darse ni darle roles a otro, ni con código.
select test.otp('00000000-0000-0000-0000-000009b10003');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10003', 'manager', 'otp')$$, 'HMY_FORBIDDEN');
select test.otp('00000000-0000-0000-0000-000009b10003');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-000009b10002', 'employee', 'otp')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.owner_staff_candidates('Rosa')$$, 'HMY_FORBIDDEN');

-- Dos empleados activos: cada uno ve solo lo suyo.
select test.logout();
insert into public.support_tickets (id, user_id, subject, body)
values (99000801, '00000000-0000-0000-0000-000009b10002', 'Caso de Juan', 'Prueba 99h'),
       (99000802, '00000000-0000-0000-0000-000009b10002', 'Caso de Ana', 'Prueba 99h');
select test.login('00000000-0000-0000-0000-000009b10001');
select public.ops_assign_case((select id from public.ops_cases where kind = 'support' and ref_id = '99000801'),
                              '00000000-0000-0000-0000-000009b10003');
select public.ops_assign_case((select id from public.ops_cases where kind = 'support' and ref_id = '99000802'),
                              '00000000-0000-0000-0000-000009b10004');
select test.logout();
create temp table t_ana as select id from public.ops_cases where kind = 'support' and ref_id = '99000802';
grant select on t_ana to authenticated;
select test.login('00000000-0000-0000-0000-000009b10003');
select test.eq((select count(*)::int from public.ops_cases where ref_id in ('99000801', '99000802')), 1,
               'aislamiento: Juan ve solo su caso');
select test.eq((select ref_id from public.ops_cases where ref_id in ('99000801', '99000802')), '99000801',
               'aislamiento: y es el suyo');
select test.expect_error(format('select public.ops_case_detail(%s)', (select id from t_ana)), 'HMY_FORBIDDEN');
select test.logout();

-- Directorio: rol, estado, casos y celular enmascarado.
select test.login('00000000-0000-0000-0000-000009b10001');
select test.eq((select (m ->> 'open_cases')::int from jsonb_array_elements(public.ops_staff_overview()) m
                where m ->> 'user_id' = '00000000-0000-0000-0000-000009b10003'), 1, 'directorio: casos abiertos de Juan');
select test.eq((select m ->> 'phone_masked' from jsonb_array_elements(public.ops_staff_overview()) m
                where m ->> 'user_id' = '00000000-0000-0000-0000-000009b10003'), '+591 7••• ••03',
               'directorio: celular enmascarado');

-- Quitar el acceso: sin código (es la acción de seguridad), los casos vuelven a la bandeja.
select public.owner_set_staff_status('00000000-0000-0000-0000-000009b10003', 'revoked', 'Prueba de revocación');
select test.login('00000000-0000-0000-0000-000009b10003');
select test.eq(public.hmy_staff_role(), null::text, 'revocado: sin rol');
select test.eq((select count(*)::int from public.ops_cases where ref_id in ('99000801', '99000802')), 0,
               'revocado: ya no ve casos');
select test.expect_error($$select public.ops_cases_list('mine')$$, 'HMY_FORBIDDEN');
select test.logout();
select test.eq((select assigned_to from public.ops_cases where ref_id = '99000801'), null::uuid,
               'revocado: su caso vuelve a la bandeja');
-- Reactivar devuelve el acceso: pide código.
select test.login('00000000-0000-0000-0000-000009b10001');
select test.expect_error($$select public.owner_set_staff_status('00000000-0000-0000-0000-000009b10003', 'active', null, null)$$,
                         'HMY_CONFIRMATION_REQUIRED');
select test.otp('00000000-0000-0000-0000-000009b10001');
select public.owner_set_staff_status('00000000-0000-0000-0000-000009b10003', 'active', null, 'otp');
select test.login('00000000-0000-0000-0000-000009b10003');
select test.eq(public.hmy_staff_role(), 'employee', 'reactivado: vuelve a ser empleado');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log where target_table = 'staff_members'
                and target_id = '00000000-0000-0000-0000-000009b10003'
                and action in ('staff.grant', 'staff.revoked', 'staff.active')), 3,
               'auditoría: dar, quitar y reactivar quedan registrados');
