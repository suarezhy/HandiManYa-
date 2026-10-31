-- Pruebas del panel de administración, reportes, bloqueos, suspensiones,
-- consentimientos, límites de uso y auditoría. Corre después de 30_location_photos_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_adm (k text primary key, v text);
grant all on t_adm to authenticated;
insert into t_adm select 'conv_e1', id::text from public.conversations
  where professional_id = '00000000-0000-0000-0000-0000000000e1' limit 1;
insert into t_adm select 'conv_d1', id::text from public.conversations
  where professional_id = '00000000-0000-0000-0000-0000000000d1' limit 1;
insert into t_adm select 'book_d1', booking_id::text from public.conversations
  where professional_id = '00000000-0000-0000-0000-0000000000d1' limit 1;

-- 1. Solo el administrador usa el panel
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error($$select public.admin_dashboard()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.admin_users('carla')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-0000000000c2', true, 'x')$$, 'HMY_FORBIDDEN');
select test.eq((select count(*)::int from public.admin_audit_log), 0, 'auditoría: un cliente no la ve');
select test.expect_error($$insert into public.admin_audit_log (action) values ('falso')$$, 'permission denied');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((public.admin_dashboard() ->> 'approved_professionals')::int >= 6, true, 'panel: cuenta profesionales aprobados');
select test.eq((select count(*)::int from public.admin_applications('all')) >= 8, true, 'panel: lista postulaciones');
select test.eq((select email from public.admin_users('carla') limit 1), 'cliente@test.bo', 'panel: busca usuarios por nombre');
select test.eq((public.admin_application_detail('00000000-0000-0000-0000-0000000000e1') -> 'documents' -> 0 ->> 'doc_type'),
               'ci_anverso', 'panel: detalle con documentos');
select test.logout();

-- 2. Bloqueos: corta el chat y las ofertas ¡Ya!
-- e1 tiene un pedido ¡Ya! aceptado (de 30_) y desde 0057 un profesional con
-- trabajo en curso no recibe pedidos ¡Ya!. Para probar solo el bloqueo, ese
-- trabajo queda terminado mientras tanto y después vuelve a su estado.
create temp table t_e1_busy as select id, status from public.bookings
  where professional_id = '00000000-0000-0000-0000-0000000000e1'
    and (status in ('on_the_way', 'in_progress') or (status = 'confirmed' and mode = 'now'));
update public.bookings set status = 'work_finished' where id in (select id from t_e1_busy);
select test.login('00000000-0000-0000-0000-0000000000c1');
select public.send_message((select v::uuid from t_adm where k = 'conv_e1'), 'Hola, ¿a qué hora llega?');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000e1');
select public.block_user('00000000-0000-0000-0000-0000000000c1');
select public.block_user('00000000-0000-0000-0000-0000000000c1'); -- repetir no falla
select test.eq((public.my_status() -> 'blocked' ->> 0), '00000000-0000-0000-0000-0000000000c1', 'bloqueo: queda en mi lista');
select test.expect_error($$select public.block_user('00000000-0000-0000-0000-0000000000e1')$$, 'HMY_NOT_FOUND');
select test.expect_error($$insert into public.user_blocks values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c2')$$, 'permission denied');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.expect_error(format($$select public.send_message(%L, 'Hola?')$$, (select v from t_adm where k = 'conv_e1')), 'HMY_BLOCKED');
select test.eq(public.count_ya_available(3, 1::smallint), 2, 'bloqueo: el profesional que me bloqueó no recibe mis pedidos');
select test.eq((select count(*)::int from public.user_blocks), 0, 'bloqueo: el bloqueado no ve quién lo bloqueó');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000e1');
select public.unblock_user('00000000-0000-0000-0000-0000000000c1');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq(public.count_ya_available(3, 1::smallint), 3, 'bloqueo: al desbloquear vuelve a recibir pedidos');
select test.logout();
update public.bookings b set status = t.status from t_e1_busy t where b.id = t.id;
select test.login('00000000-0000-0000-0000-0000000000c1');

-- 3. Reportes con límite diario
select test.expect_error($$select public.report_user('00000000-0000-0000-0000-0000000000c1', 'fraude')$$, 'HMY_NOT_FOUND');
select test.expect_error($$select public.report_user('00000000-0000-0000-0000-0000000000d1', 'inventado')$$, 'user_reports_reason_check');
select test.expect_error(format($$select public.report_user('00000000-0000-0000-0000-0000000000d2', 'fraude', null, %L)$$,
                                (select v from t_adm where k = 'book_d1')), 'HMY_FORBIDDEN');
insert into t_adm select 'report', public.report_user('00000000-0000-0000-0000-0000000000d1', 'no_se_presento',
  'Dijo que venía a las 10 y no llegó', (select v::uuid from t_adm where k = 'book_d1'))::text;
select public.report_user('00000000-0000-0000-0000-0000000000d1', 'otro') from generate_series(1, 4);
select test.expect_error($$select public.report_user('00000000-0000-0000-0000-0000000000d2', 'otro')$$, 'HMY_RATE_LIMITED');
select test.eq((select count(*)::int from public.user_reports), 5, 'reporte: veo mis reportes');
select test.expect_error($$insert into public.user_reports (reporter_id, reported_id, reason) values (auth.uid(), '00000000-0000-0000-0000-0000000000d2', 'otro')$$, 'permission denied');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000d1');
select test.eq((select count(*)::int from public.user_reports), 0, 'reporte: el reportado no ve quién lo reportó');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((select reports_against from public.admin_reports('open') where id = (select v::bigint from t_adm where k = 'report')),
               5, 'reporte: el admin ve cuántos reportes tiene la persona');
select test.expect_error(format($$select public.admin_review_report(%s, 'resolved')$$, (select v from t_adm where k = 'report')), 'HMY_REASON_REQUIRED');
select public.admin_review_report((select v::bigint from t_adm where k = 'report'), 'resolved', 'Se habló con el profesional');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'report.resolved'), 1, 'auditoría: registra la revisión del reporte');

-- 4. Suspensiones
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-0000000000d3', true)$$, 'HMY_REASON_REQUIRED');
select test.expect_error($$select public.admin_set_suspension('00000000-0000-0000-0000-00000000000a', true, 'x')$$, 'HMY_FORBIDDEN');
select public.admin_set_suspension('00000000-0000-0000-0000-0000000000d3', true, 'Varios reportes de cobro indebido');
select test.eq((select status::text from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000d3'),
               'suspended', 'suspensión: el profesional queda suspendido');
select test.eq((select is_available from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000d3'),
               false, 'suspensión: deja de estar disponible');
select test.eq((select count(*)::int from public.admin_audit_log where action in ('account.suspend', 'professional.suspended')
                and target_id = '00000000-0000-0000-0000-0000000000d3'), 2, 'auditoría: registra la suspensión');
select public.admin_set_suspension('00000000-0000-0000-0000-0000000000c2', true, 'Pedidos falsos');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000d3');
select test.eq((public.my_status() ->> 'suspension_reason'), 'Varios reportes de cobro indebido', 'suspensión: el usuario ve el motivo');
select test.expect_error($$select public.set_availability(true)$$, 'HMY_PROFESSIONAL_NOT_APPROVED');
select test.eq((select count(*)::int from public.notifications where kind = 'account'), 1, 'suspensión: se avisa al usuario');
select test.logout();
select test.login('00000000-0000-0000-0000-0000000000c2');
select test.expect_error($$select public.create_ya_request(2, 1::smallint, 'Se quemó un enchufe', 'Calle 1')$$, 'HMY_ACCOUNT_SUSPENDED');
select test.expect_error($$update public.profiles set suspended_at = null where id = auth.uid()$$, 'permission denied');
-- Aun suspendido puede escribir a soporte, con límite diario.
insert into public.support_tickets (user_id, subject, body)
select auth.uid(), 'Mi cuenta', 'Creo que mi cuenta fue suspendida por error' from generate_series(1, 5);
select test.expect_error($$insert into public.support_tickets (user_id, subject, body) values (auth.uid(), 'Otra vez', 'Por favor revisen')$$, 'HMY_RATE_LIMITED');
select test.logout();

select test.login('00000000-0000-0000-0000-00000000000a');
select public.admin_set_suspension('00000000-0000-0000-0000-0000000000d3', false);
select test.eq((select status::text from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000000d3'),
               'approved', 'suspensión: al levantarla vuelve a estar aprobado');
select test.eq((select suspended_at from public.profiles where id = '00000000-0000-0000-0000-0000000000d3'), null::timestamptz,
               'suspensión: se borra la fecha');
select public.admin_update_ticket((select max(id) from public.support_tickets), 'closed', 'Revisamos tu caso.');
select test.eq((select count(*)::int from public.admin_tickets('open')), 4, 'soporte: el admin cierra tickets');

-- 5. Comisiones configurables y auditadas
select test.expect_error($$select public.admin_save_commission_rule(null, 'Sin monto', null, null, null, null, 0, 0, 'completed', true)$$, 'HMY_COMMISSION_REQUIRED');
insert into t_adm select 'rule', public.admin_save_commission_rule(null, 'Limpieza Santa Cruz', 3, 1::smallint, 8, null, 5, 10, 'completed', true)::text;
select test.eq((select name from public.commission_rules where is_active and category_id = 3 and city_id = 1), 'Limpieza Santa Cruz', 'comisión: la regla nueva se aplica a su categoría y ciudad');
select public.admin_save_commission_rule((select v::int from t_adm where k = 'rule'), 'Limpieza Santa Cruz', 3, 1::smallint, 8, null, 5, 10, 'completed', false);
select test.eq((select is_active from public.commission_rules where id = (select v::int from t_adm where k = 'rule')), false, 'comisión: se puede desactivar');
select test.eq((select count(*)::int from public.admin_audit_log where action in ('commission_rules.insert', 'commission_rules.update')
                and target_id = (select v from t_adm where k = 'rule')), 2, 'auditoría: registra cambios de comisión con antes y después');

-- 6. Catálogo y documentos
update public.service_categories set is_active = false where id = 18;
select test.eq((select count(*)::int from public.admin_audit_log where action = 'service_categories.update' and target_id = '18'), 1,
               'auditoría: registra cambios de categorías');
update public.service_categories set is_active = true where id = 18;
select test.expect_error(format($$select public.admin_review_document(%s, 'rejected')$$,
  (select min(id) from public.professional_documents)), 'HMY_REASON_REQUIRED');
select public.admin_review_document((select min(id) from public.professional_documents), 'accepted');
select test.eq((select status from public.professional_documents order by id limit 1), 'accepted', 'documentos: el admin los acepta');
select test.eq((select count(*)::int from public.admin_audit_entries(500)) >= 8, true, 'auditoría: el admin lee el historial');
select test.logout();

select test.login('00000000-0000-0000-0000-0000000000c1');
update public.service_categories set is_active = false where id = 1;
select test.logout();
select test.eq((select is_active from public.service_categories where id = 1), true, 'catálogo: un cliente no puede cambiarlo');

-- 7. Consentimientos
select test.login('00000000-0000-0000-0000-0000000000c1');
select public.record_consent('terminos', '2026-10');
select public.record_consent('terminos', '2026-10');
select public.record_consent('privacidad', '2026-10');
select test.eq((select count(*)::int from public.consent_records), 2, 'consentimiento: guarda cada versión una sola vez');
select test.expect_error($$select public.record_consent('inventado', '1')$$, 'consent_records_document_check');

-- 8. Límite de mensajes por minuto
do $$
declare
  v_conv uuid := (select v::uuid from t_adm where k = 'conv_d1');
  v_err text;
begin
  for i in 1..30 loop
    begin
      perform public.send_message(v_conv, 'Mensaje ' || i);
    exception when others then
      v_err := sqlerrm;
      exit;
    end;
  end loop;
  if v_err is distinct from 'HMY_RATE_LIMITED' then raise exception 'FALLÓ: límite de mensajes (error: %)', v_err; end if;
  if (select count(*) from public.messages where sender_id = auth.uid() and created_at > now() - interval '1 minute') <> 20 then
    raise exception 'FALLÓ: límite de mensajes, no son 20';
  end if;
  raise notice 'ok - mensajes: máximo 20 por minuto';
end $$;
select test.logout();

\o
\echo 'PRUEBAS DE ADMINISTRACIÓN Y SEGURIDAD PASARON'
