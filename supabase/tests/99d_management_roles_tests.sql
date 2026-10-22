-- Propietario, Gerente de Operaciones y Empleado (0035). Corre después de 99c.
-- Cuentas de prueba propias (…99d…); ninguna cuenta real recibe un rol.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000099d001', '59170099101', now(), '{"full_name": "Dueña Prueba"}'),
  ('00000000-0000-0000-0000-00000099d002', '59170099102', now(), '{"full_name": "Gerente Prueba"}'),
  ('00000000-0000-0000-0000-00000099d003', '59170099103', now(), '{"full_name": "Empleada Uno"}'),
  ('00000000-0000-0000-0000-00000099d004', '59170099104', now(), '{"full_name": "Empleado Dos"}'),
  ('00000000-0000-0000-0000-00000099d005', '59170099105', now(), '{"full_name": "Cliente Prueba"}'),
  ('00000000-0000-0000-0000-00000099d006', '59170099106', now(), '{"full_name": "Profesional Prueba"}'),
  ('00000000-0000-0000-0000-00000099d007', null, null, '{"full_name": "Sin Celular"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-00000099d001', 'admin');

-- Nada en la migración dio roles.
select test.eq((select count(*)::int from public.staff_members
                where user_id::text not like '00000000-0000-0000-0000-00000099d%'), 0,
               'roles: la migración no da roles a ninguna cuenta');

-- Solo el propietario da roles.
select test.login('00000000-0000-0000-0000-00000099d005');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d005', 'manager')$$, 'HMY_FORBIDDEN');
select test.eq(public.hmy_staff_role(), null::text, 'roles: un cliente no tiene rol de gestión');
select test.expect_error('select public.ops_dashboard()', 'HMY_FORBIDDEN');
select test.expect_error($$select public.ops_cases_list('all')$$, 'HMY_FORBIDDEN');

select test.login('00000000-0000-0000-0000-00000099d001');
select test.eq(public.hmy_staff_role(), 'owner', 'roles: el admin es el propietario');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d002', 'owner')$$, 'HMY_INVALID_ROLE');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d001', 'manager')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d007', 'employee')$$,
                         'HMY_STAFF_ACCOUNT_REQUIRED');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-0000000999ff', 'employee')$$,
                         'HMY_STAFF_ACCOUNT_REQUIRED');
select public.owner_grant_staff('00000000-0000-0000-0000-00000099d002', 'manager');
select public.owner_grant_staff('00000000-0000-0000-0000-00000099d003', 'employee');
select public.owner_grant_staff('00000000-0000-0000-0000-00000099d004', 'employee');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log where action = 'staff.grant'
                and target_id like '00000000-0000-0000-0000-00000099d%'), 3, 'roles: cada rol dado queda en la auditoría');

-- Cinco empleados o más: cada uno con su cuenta y su estado.
insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000009e' || lpad(g::text, 4, '0'))::uuid, '591700992' || lpad(g::text, 2, '0'), now(),
       jsonb_build_object('full_name', 'Empleado Extra ' || g)
from generate_series(1, 4) g;
select test.login('00000000-0000-0000-0000-00000099d001');
select public.owner_grant_staff(('00000000-0000-0000-0000-0000009e' || lpad(g::text, 4, '0'))::uuid, 'employee')
from generate_series(1, 4) g;
select test.eq((select count(*)::int from public.staff_members where role = 'employee' and status = 'active'
                and (user_id::text like '00000000-0000-0000-0000-00000099d%' or user_id::text like '00000000-0000-0000-0000-0000009e%')),
               6, 'roles: seis empleados activos, cada uno con su propia fila');

-- El gerente no puede dar ni cambiar roles.
select test.login('00000000-0000-0000-0000-00000099d002');
select test.eq(public.hmy_staff_role(), 'manager', 'roles: gerente');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d005', 'employee')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_grant_staff('00000000-0000-0000-0000-00000099d003', 'manager')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_set_staff_status('00000000-0000-0000-0000-00000099d003', 'suspended', 'x')$$, 'HMY_FORBIDDEN');
select test.expect_error($$insert into public.staff_members (user_id, role, granted_by) values
  ('00000000-0000-0000-0000-00000099d005', 'manager', auth.uid())$$, 'permission denied');
select test.expect_error($$update public.staff_members set role = 'manager' where user_id = '00000000-0000-0000-0000-00000099d003'$$,
                         'permission denied');
select test.expect_error($$insert into public.user_roles (user_id, role) values (auth.uid(), 'admin')$$, 'permission denied');

-- ---------------------------------------------------------------------------
-- Sin datos de dinero para el gerente ni el empleado, ni por la API
-- ---------------------------------------------------------------------------
select test.logout();
select test.eq((select count(*) > 0 from public.wallets), true, 'dinero: hay billeteras en la base de prueba');
select test.eq((select count(*) > 0 from public.commission_rules), true, 'dinero: hay reglas de comisión');

create temp table t_staff (id uuid);
insert into t_staff values ('00000000-0000-0000-0000-00000099d002'), ('00000000-0000-0000-0000-00000099d003');
grant select on t_staff to authenticated;

do $$
declare r record; v_sql text;
begin
  for r in select id from t_staff loop
    perform test.login(r.id);
    foreach v_sql in array array[
      'select public.admin_dashboard()',
      'select * from public.admin_topups(''pending'')',
      'select public.review_topup(1, true, null)',
      'select public.admin_wallet_adjustment(''00000000-0000-0000-0000-00000099d006'', 10, ''prueba'', ''k1'')',
      'select public.admin_cost_dashboard(null)',
      'select public.admin_set_setting(''identity_check'', ''{"required": false}'', null)',
      'select public.admin_set_vendor(''ai_model'', ''live'', 100, null)',
      'select public.admin_ai_overview()',
      'select public.admin_run_monitors()',
      'select * from public.admin_audit_entries(10)',
      'select public.resolve_dispute(''00000000-0000-0000-0000-000000000000'', ''completed'', ''x'')'] loop
      perform test.expect_error(v_sql, 'HMY_FORBIDDEN|permission denied');
    end loop;
    perform test.eq((select count(*)::int from public.wallets), 0, 'dinero: no ve billeteras ' || r.id);
    perform test.eq((select count(*)::int from public.wallet_ledger), 0, 'dinero: no ve movimientos ' || r.id);
    perform test.eq((select count(*)::int from public.topup_requests), 0, 'dinero: no ve recargas ' || r.id);
    perform test.eq((select count(*)::int from storage.objects where bucket_id = 'topup-proofs'), 0,
                    'dinero: no ve comprobantes de recarga ' || r.id);
    perform test.expect_error('delete from public.admin_audit_log', 'permission denied');
    perform test.expect_error('update public.admin_audit_log set action = ''x''', 'permission denied');
    perform test.eq((select (public.ops_dashboard() ?| array['pending_topups', 'revenue', 'commissions', 'wallet'])),
                    false, 'dinero: el panel de operaciones no trae dinero ' || r.id);
  end loop;
  perform test.logout();
end $$;

-- ---------------------------------------------------------------------------
-- Casos: se abren solos y el gerente los asigna
-- ---------------------------------------------------------------------------
insert into public.support_tickets (user_id, subject, body) values
  ('00000000-0000-0000-0000-00000099d005', 'No puedo pagar', 'El profesional no aceptó el QR.'),
  ('00000000-0000-0000-0000-00000099d005', 'Duda de horario', 'Quiero cambiar el horario de mi pedido.');
insert into public.user_reports (reporter_id, reported_id, reason, details) values
  ('00000000-0000-0000-0000-00000099d005', '00000000-0000-0000-0000-00000099d006', 'acoso', 'Mensajes ofensivos.'),
  ('00000000-0000-0000-0000-00000099d005', '00000000-0000-0000-0000-00000099d006', 'no_se_presento', 'No llegó.');
create temp table t_case (name text, id bigint);
insert into t_case select 'pago', id from public.ops_cases where kind = 'support'
  and ref_id = (select id::text from public.support_tickets where subject = 'No puedo pagar'
                and user_id = '00000000-0000-0000-0000-00000099d005');
insert into t_case select 'horario', id from public.ops_cases where kind = 'support'
  and ref_id = (select id::text from public.support_tickets where subject = 'Duda de horario'
                and user_id = '00000000-0000-0000-0000-00000099d005');
insert into t_case select 'acoso', id from public.ops_cases where kind = 'report'
  and ref_id = (select id::text from public.user_reports where reason = 'acoso'
                and reporter_id = '00000000-0000-0000-0000-00000099d005');
insert into t_case select 'rutina', id from public.ops_cases where kind = 'report'
  and ref_id = (select id::text from public.user_reports where reason = 'no_se_presento'
                and reporter_id = '00000000-0000-0000-0000-00000099d005');
grant select on t_case to authenticated;
select test.eq((select count(*)::int from t_case where id is not null), 4, 'casos: cada solicitud abre su caso');
select test.eq((select (category, priority)::text from public.ops_cases where id = (select id from t_case where name = 'acoso')),
               '(safety,high)', 'casos: el acoso es de seguridad y prioritario');

-- El empleado no asigna.
select test.login('00000000-0000-0000-0000-00000099d003');
select test.expect_error(format('select public.ops_assign_case(%s, %L)', (select id from t_case where name = 'pago'),
                                '00000000-0000-0000-0000-00000099d003'), 'HMY_FORBIDDEN');

select test.login('00000000-0000-0000-0000-00000099d002');
select public.ops_assign_case((select id from t_case where name = 'pago'), '00000000-0000-0000-0000-00000099d003');
select public.ops_assign_case((select id from t_case where name = 'acoso'), '00000000-0000-0000-0000-00000099d003');
select public.ops_assign_case((select id from t_case where name = 'rutina'), '00000000-0000-0000-0000-00000099d003');
select public.ops_assign_case((select id from t_case where name = 'horario'), '00000000-0000-0000-0000-00000099d004');
-- Solo a miembros activos del equipo.
select test.expect_error(format('select public.ops_assign_case(%s, %L)', (select id from t_case where name = 'pago'),
                                '00000000-0000-0000-0000-00000099d005'), 'HMY_STAFF_NOT_ACTIVE');
select test.eq(jsonb_array_length(public.ops_cases_list('all')) >= 4, true, 'casos: el gerente ve todos');

-- La empleada ve solo los suyos, pida lo que pida.
select test.login('00000000-0000-0000-0000-00000099d003');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_cases_list('all')) e
                where (e ->> 'assigned_to')::uuid is distinct from auth.uid()), 0,
               'aislamiento: la empleada no recibe casos ajenos');
select test.eq((select count(*)::int from public.ops_cases where assigned_to is distinct from auth.uid()), 0,
               'aislamiento: tampoco leyendo la tabla');
select test.expect_error(format('select public.ops_case_detail(%s)', (select id from t_case where name = 'horario')), 'HMY_FORBIDDEN');
select test.expect_error(format('select public.ops_add_note(%s, %L)', (select id from t_case where name = 'horario'), 'hola'),
                         'HMY_FORBIDDEN');
select test.expect_error(format('select public.ops_reply(%s, %L)', (select id from t_case where name = 'horario'), 'hola'),
                         'HMY_FORBIDDEN');
select test.eq((select count(*)::int from public.ops_case_notes n
                where n.case_id = (select id from t_case where name = 'horario')), 0,
               'aislamiento: no lee notas de casos ajenos');
-- Las funciones viejas del panel tampoco: sin lista de postulaciones,
-- reportes, tickets, disputas ni usuarios.
select test.expect_error($$select * from public.admin_applications('pending')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.admin_tickets('open')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.admin_reports('open')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.admin_disputes('open')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.admin_users(null)$$, 'HMY_FORBIDDEN');

-- Responder y resolver un caso de rutina propio.
select public.ops_reply((select id from t_case where name = 'pago'), 'Hola, ya hablamos con el profesional.');
select public.ops_add_note((select id from t_case where name = 'pago'), 'Llamar mañana si no responde.');
select test.expect_error(format('select public.ops_set_case_status(%s, %L, null)', (select id from t_case where name = 'pago'),
                                'resolved'), 'HMY_REASON_REQUIRED');
select public.ops_set_case_status((select id from t_case where name = 'pago'), 'resolved', 'Resuelto con el profesional.');
select public.ops_set_case_status((select id from t_case where name = 'rutina'), 'resolved', 'Se reprogramó la visita.');
-- Seguridad: no lo resuelve, lo escala.
select test.expect_error(format('select public.ops_set_case_status(%s, %L, %L)', (select id from t_case where name = 'acoso'),
                                'resolved', 'listo'), 'HMY_ESCALATE_REQUIRED');
select public.ops_escalate((select id from t_case where name = 'acoso'), 'Mensajes de acoso, revisar cuenta.', 'safety');
select test.expect_error(format('select public.ops_set_case_status(%s, %L, null)', (select id from t_case where name = 'acoso'),
                                'in_progress'), 'HMY_FORBIDDEN');
-- No suspende cuentas.
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-00000099d006', true, 'acoso')$$,
                         'HMY_FORBIDDEN');
select test.logout();
select test.eq((select status from public.support_tickets where id = (select ref_id::bigint from public.ops_cases
                where id = (select id from t_case where name = 'pago'))), 'closed', 'casos: resolver cierra el ticket');
select test.eq((select count(*)::int from public.notifications where user_id = '00000000-0000-0000-0000-00000099d005'
                and kind = 'support'), 1, 'casos: la respuesta le llega a quien escribió');
select test.eq((select (status, escalated_to, priority)::text from public.ops_cases
                where id = (select id from t_case where name = 'acoso')), '(escalated,manager,urgent)',
               'casos: la empleada escala al gerente');
select test.eq((select count(*)::int from public.admin_audit_log where actor_id = '00000000-0000-0000-0000-00000099d003'
                and action in ('case.reply', 'case.note', 'case.resolved', 'case.escalate')), 5,
               'auditoría: cada acción de la empleada queda registrada');

-- El gerente escala al propietario y suspende la cuenta denunciada (no a
-- miembros del equipo ni al propietario).
select test.login('00000000-0000-0000-0000-00000099d002');
select public.ops_escalate((select id from t_case where name = 'acoso'), 'Pedir revisión del propietario.', null);
select test.eq((select escalated_to from public.ops_cases where id = (select id from t_case where name = 'acoso')), 'owner',
               'casos: el gerente escala al propietario');
select public.admin_set_suspension('00000000-0000-0000-0000-00000099d006', true, 'Acoso reportado');
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-00000099d003', true, 'x')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-00000099d001', true, 'x')$$, 'HMY_FORBIDDEN');
select public.admin_set_suspension('00000000-0000-0000-0000-00000099d006', false, null);
select test.eq(jsonb_array_length(public.ops_staff_overview()) >= 3, true, 'equipo: el gerente ve tiempos y carga');
select test.eq((select (e ->> 'resolved_7d')::int from jsonb_array_elements(public.ops_staff_overview()) e
                where e ->> 'user_id' = '00000000-0000-0000-0000-00000099d003'), 2, 'equipo: casos resueltos por la empleada');
select test.eq((select (e ->> 'avg_first_response_min') is not null from jsonb_array_elements(public.ops_staff_overview()) e
                where e ->> 'user_id' = '00000000-0000-0000-0000-00000099d003'), true, 'equipo: tiempo de primera respuesta');

-- ---------------------------------------------------------------------------
-- Postulaciones: el empleado marca, el gerente decide con las mismas reglas
-- ---------------------------------------------------------------------------
select test.logout();
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id)
values ('00000000-0000-0000-0000-00000099d006', 'Profesional Prueba', 1, 1);
insert into public.professional_documents (professional_id, doc_type, storage_path, status) values
  ('00000000-0000-0000-0000-00000099d006', 'ci_anverso', '00000000-0000-0000-0000-00000099d006/ci-a.jpg', 'pending'),
  ('00000000-0000-0000-0000-00000099d006', 'ci_reverso', '00000000-0000-0000-0000-00000099d006/ci-r.jpg', 'pending');
insert into storage.objects (bucket_id, name, owner) values
  ('professional-documents', '00000000-0000-0000-0000-00000099d006/ci-a.jpg', '00000000-0000-0000-0000-00000099d006');
update public.professional_profiles set status = 'submitted', submitted_at = now()
where user_id = '00000000-0000-0000-0000-00000099d006';
insert into t_case select 'postulacion', id from public.ops_cases where kind = 'application'
  and ref_id = '00000000-0000-0000-0000-00000099d006';
select test.eq((select count(*)::int from t_case where name = 'postulacion'), 1, 'postulación: abre su caso');
insert into t_case select 'ci_a', id from public.professional_documents
  where professional_id = '00000000-0000-0000-0000-00000099d006' and doc_type = 'ci_anverso';

select test.login('00000000-0000-0000-0000-00000099d002');
select public.ops_assign_case((select id from t_case where name = 'postulacion'), '00000000-0000-0000-0000-00000099d003');

select test.login('00000000-0000-0000-0000-00000099d003');
select test.eq((public.ops_application_basic('00000000-0000-0000-0000-00000099d006') ->> 'display_name'), 'Profesional Prueba',
               'postulación: la empleada ve lo básico');
select test.eq((public.ops_application_basic('00000000-0000-0000-0000-00000099d006')::text ~ 'storage_path|phone|liveness'),
               false, 'postulación: sin archivos, teléfono ni puntajes de identidad');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'professional-documents'
                and name like '00000000-0000-0000-0000-00000099d006/%'), 0, 'postulación: la empleada no abre el carnet');
select test.expect_error($$select public.admin_application_detail('00000000-0000-0000-0000-00000099d006')$$, 'HMY_FORBIDDEN');
-- La empleada no lee la tabla de documentos: usa los ids del resumen.
select test.eq((select count(*)::int from public.professional_documents
                where professional_id = '00000000-0000-0000-0000-00000099d006'), 0, 'postulación: la empleada no lee la tabla de documentos');
select public.ops_flag_document((select (d ->> 'id')::bigint
                                 from jsonb_array_elements(public.ops_application_basic('00000000-0000-0000-0000-00000099d006') -> 'documents') d
                                 where d ->> 'doc_type' = 'ci_reverso'),
                                'El reverso está borroso.');
select test.expect_error(format('select public.admin_review_document(%s, %L, null)',
                                (select id from t_case where name = 'ci_a'),
                                'accepted'), 'HMY_FORBIDDEN');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-00000099d006', 'approved', null)$$,
                         'HMY_FORBIDDEN');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-00000099d006', 'rejected', 'x')$$,
                         'HMY_FORBIDDEN');
select test.expect_error(format('select public.ops_set_case_status(%s, %L, %L)', (select id from t_case where name = 'postulacion'),
                                'resolved', 'ok'), 'HMY_ESCALATE_REQUIRED');

select test.login('00000000-0000-0000-0000-00000099d002');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'professional-documents'
                and name like '00000000-0000-0000-0000-00000099d006/%'), 1, 'postulación: el gerente abre el carnet para revisarlo');
select test.eq((select count(*)::int from storage.objects where bucket_id = 'topup-proofs'), 0,
               'postulación: el gerente no ve comprobantes de recarga');
select test.eq(((public.admin_application_detail('00000000-0000-0000-0000-00000099d006') -> 'documents') @>
                '[{"flag_note": "El reverso está borroso."}]'), true, 'postulación: el gerente ve la marca de la empleada');
-- Sin el carnet aceptado, ni el gerente aprueba.
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-00000099d006', 'approved', null)$$,
                         'HMY_ID_DOCUMENTS_REQUIRED');
select public.admin_review_document((d ->> 'id')::bigint, 'accepted', null)
from jsonb_array_elements(public.admin_application_detail('00000000-0000-0000-0000-00000099d006') -> 'documents') d;
-- Una verificación de identidad real rechazada: el gerente no la pasa por alto.
select test.logout();
insert into public.identity_checks (professional_id, sandbox, status)
values ('00000000-0000-0000-0000-00000099d006', false, 'declined');
select test.login('00000000-0000-0000-0000-00000099d002');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-00000099d006', 'approved', null)$$,
                         'HMY_IDENTITY_DECLINED');
select test.logout();
delete from public.identity_checks where professional_id = '00000000-0000-0000-0000-00000099d006';
select test.login('00000000-0000-0000-0000-00000099d002');
select public.review_professional_application('00000000-0000-0000-0000-00000099d006', 'approved', null);
select test.logout();
select test.eq((select status::text from public.professional_profiles where user_id = '00000000-0000-0000-0000-00000099d006'),
               'approved', 'postulación: el gerente aprueba con todo en regla');
select test.eq((select status from public.ops_cases where id = (select id from t_case where name = 'postulacion')), 'resolved',
               'postulación: la decisión cierra el caso');
select test.eq((select count(*)::int from public.admin_audit_log where actor_id = '00000000-0000-0000-0000-00000099d002'
                and action = 'application.approved' and details ->> 'by_role' = 'manager'), 1,
               'auditoría: la aprobación del gerente queda registrada');

-- ---------------------------------------------------------------------------
-- Suspender y quitar el acceso
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-00000099d002');
select public.ops_assign_case((select id from t_case where name = 'horario'), '00000000-0000-0000-0000-00000099d004');
select test.login('00000000-0000-0000-0000-00000099d001');
select test.expect_error($$select public.owner_set_staff_status('00000000-0000-0000-0000-00000099d004', 'suspended', null)$$,
                         'HMY_REASON_REQUIRED');
select public.owner_set_staff_status('00000000-0000-0000-0000-00000099d004', 'suspended', 'Vacaciones');
select test.login('00000000-0000-0000-0000-00000099d004');
select test.eq(public.hmy_staff_role(), null::text, 'suspensión: sin rol en la siguiente llamada');
select test.expect_error('select public.ops_dashboard()', 'HMY_FORBIDDEN');
select test.expect_error($$select public.ops_cases_list('mine')$$, 'HMY_FORBIDDEN');
select test.eq((select count(*)::int from public.ops_cases), 0, 'suspensión: no lee casos');
select test.eq((public.my_staff_role() ->> 'status'), 'suspended', 'suspensión: la app sabe por qué');
select test.logout();
select test.eq((select assigned_to from public.ops_cases where id = (select id from t_case where name = 'horario')), null::uuid,
               'suspensión: sus casos vuelven a la bandeja');
select test.login('00000000-0000-0000-0000-00000099d001');
select public.owner_set_staff_status('00000000-0000-0000-0000-00000099d004', 'active', null);
select public.owner_set_staff_status('00000000-0000-0000-0000-00000099d004', 'revoked', 'Ya no trabaja con nosotros');
select test.login('00000000-0000-0000-0000-00000099d004');
select test.eq(public.hmy_staff_role(), null::text, 'revocado: sin acceso');
select test.login('00000000-0000-0000-0000-00000099d001');
-- El propietario ve todo; el panel de operaciones también le sirve.
select test.eq((public.ops_dashboard() ->> 'escalated_cases')::int >= 1, true, 'propietario: ve los casos escalados');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log where target_table = 'staff_members'
                and target_id = '00000000-0000-0000-0000-00000099d004'), 4,
               'auditoría: dar, suspender, reactivar y revocar quedan registrados');

\o
\echo 'PRUEBAS DE ROLES DE GESTIÓN PASARON'
