-- Pruebas del Centro de Control IA (0012): solo administradores, avisos con
-- reglas sobre datos reales y sin duplicados, bandeja de aprobación con
-- confirmación, ajustes y reporte diario. Corre después de 60_wallet_confirmation_tests.sql.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_ai (k text primary key, v text);
grant all on t_ai to authenticated, anon;

-- 1. Agentes: los 18 del dueño y los agregados, todos visibles solo para el admin
select test.login('00000000-0000-0000-0000-00000000000a');
do $$ begin
  perform test.eq((select count(*)::int from public.ai_agents), 26, 'agentes: 18 del plan y 8 agregados');
  perform test.eq((select count(*)::int from public.ai_agents where not added_by_claude), 18, 'agentes: los 18 del dueño');
  perform test.eq((select count(*)::int from public.ai_agents where number between 1 and 18 and not added_by_claude), 18,
                  'agentes: numerados del 1 al 18 como en el plan');
  perform test.eq((select (value ->> 'timezone') from public.app_settings where key = 'daily_report'), 'America/New_York',
                  'reporte: hora de Miami');
  perform test.eq((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'), 0::numeric,
                  'presupuesto de IA: empieza en cero (no se gasta sin aprobación)');
end $$;
select test.logout();

select test.login('00000000-0000-0000-0000-000000000062');
do $$ begin
  perform test.eq((select count(*)::int from public.ai_agents), 0, 'privacidad: un usuario no ve los agentes');
  perform test.eq((select count(*)::int from public.ai_items), 0, 'privacidad: un usuario no ve los avisos');
  perform test.eq((select count(*)::int from public.daily_reports), 0, 'privacidad: un usuario no ve los reportes');
  perform test.eq((select count(*)::int from public.app_settings), 0, 'privacidad: un usuario no ve los ajustes');
end $$;
select test.expect_error($$select public.admin_ai_overview()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_run_monitors()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_generate_daily_report()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.run_marketplace_monitors()$$, 'permission denied');
select test.expect_error($$select public.hmy_raise_item('fraud', 'alert', 'high', 'ai', 'x y z', null, '{}', 'k')$$, 'permission denied');
select test.expect_error($$insert into public.ai_items (agent_key, kind, source, title) values ('boss', 'alert', 'ai', 'hola')$$,
                         'permission denied');
select test.logout();

-- 2. Situaciones reales para los monitores
update public.topup_requests set created_at = now() - interval '30 hours'
where id = (select min(id) from public.topup_requests where status = 'pending');
insert into t_ai values ('late_topup', (select min(id)::text from public.topup_requests where status = 'pending'));
update public.topup_requests set reference = 'COMP-999'
where id in (select id from public.topup_requests where status = 'pending' order by id limit 2);
update public.wallets set available = available + 7
where professional_id = '00000000-0000-0000-0000-000000000061';

-- 3. Los monitores crean avisos con evidencia y no los repiten
select test.login('00000000-0000-0000-0000-00000000000a');
insert into t_ai select 'n1', public.admin_run_monitors()::text;
insert into t_ai select 'n2', public.admin_run_monitors()::text;
do $$ begin
  perform test.eq((select v from t_ai where k = 'n1')::int > 0, true, 'monitores: encuentran problemas reales');
  perform test.eq((select v from t_ai where k = 'n2')::int, 0, 'monitores: no repiten avisos ya creados');
  perform test.eq((select severity from public.ai_items where agent_key = 'wallet'
                   and target_id = '00000000-0000-0000-0000-000000000061' and title like 'Saldo que no cuadra%'),
                  'critical', 'billetera: saldo que no cuadra con el libro mayor es crítico');
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key = 'topup-late:' || (select v from t_ai where k = 'late_topup')),
                  1, 'billetera: recarga atrasada más de 24 horas');
  perform test.eq((select count(*)::int from public.ai_items where title = 'Comprobante repetido en varias recargas'), 1,
                  'billetera: comprobante repetido');
  perform test.eq((select bool_and(source = 'rule') from public.ai_items), true,
                  'avisos: los de reglas se marcan como datos reales, no como IA');
  perform test.eq((select status from public.ai_agent_runs where agent_key = 'boss' order by id desc limit 1), 'ok',
                  'agentes: la ejecución queda registrada');
  perform test.eq((public.admin_ai_overview() ->> 'critical')::int >= 1, true, 'panel: cuenta los avisos críticos');
end $$;
select test.logout();
update public.wallets set available = available - 7
where professional_id = '00000000-0000-0000-0000-000000000061';

-- 4. Bandeja de aprobación
select test.login('00000000-0000-0000-0000-00000000000a');
insert into t_ai select 'alert', (select min(id)::text from public.ai_items where kind = 'alert');
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'approve')$$, (select v from t_ai where k = 'alert')),
                         'HMY_INVALID_STATUS');
select public.admin_decide_ai_item((select v from t_ai where k = 'alert')::bigint, 'dismiss', 'Revisado: sin acción');
select test.eq((select status from public.ai_items where id = (select v from t_ai where k = 'alert')::bigint), 'dismissed',
               'bandeja: descartar un aviso');
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'dismiss')$$, (select v from t_ai where k = 'alert')),
                         'HMY_ALREADY_REVIEWED');
select test.logout();

-- Una recomendación que pide aprobación (la crea el sistema, no la app).
insert into t_ai select 'req', public.hmy_raise_item('fraud', 'approval_request', 'high', 'ai', 'Revisar cuenta sospechosa',
  'Recomendación de IA: revisar a mano antes de decidir.', '{"reports": 3}', 'test-approval-1', 'profiles',
  '00000000-0000-0000-0000-000000000062', '{"type": "review_account", "params": {}}')::text;
select test.login_pw('00000000-0000-0000-0000-00000000000a', 600);
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'approve', 'ok', 'password')$$,
                                (select v from t_ai where k = 'req')), 'HMY_CONFIRMATION_EXPIRED');
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'completed')$$, (select v from t_ai where k = 'req')),
                         'HMY_INVALID_STATUS');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-00000000000a', 7);
select public.admin_decide_ai_item((select v from t_ai where k = 'req')::bigint, 'approve', 'Aprobado por el dueño', 'password');
select public.admin_decide_ai_item((select v from t_ai where k = 'req')::bigint, 'completed', 'Cuenta revisada');
do $$ begin
  perform test.eq((select status from public.ai_items where id = (select v from t_ai where k = 'req')::bigint), 'completed',
                  'bandeja: aprobada y luego completada');
  perform test.eq((select decided_by from public.ai_items where id = (select v from t_ai where k = 'req')::bigint),
                  '00000000-0000-0000-0000-00000000000a'::uuid, 'bandeja: guarda quién decidió');
  perform test.eq((select count(*)::int from public.admin_audit_log where target_table = 'ai_items'
                   and target_id = (select v from t_ai where k = 'req')), 2, 'auditoría: aprobación y resultado registrados');
end $$;

-- 5. Ajustes
select test.expect_error($$select public.admin_set_setting('daily_report', '{"enabled": true, "timezone": "Marte/Base", "hour": 6}')$$,
                         'HMY_INVALID_SETTING');
select test.expect_error($$select public.admin_set_setting('otra_cosa', '{}')$$, 'HMY_INVALID_SETTING');
select test.expect_error($$select public.admin_set_setting('ai_budget', '{"monthly_usd": 20}', 'biometric')$$,
                         'HMY_BIOMETRIC_DISABLED');
select test.logout();
select test.login_pw('00000000-0000-0000-0000-00000000000a', 60); -- lejos del de arriba (7 s): si pasa un segundo entre ambos, serían el mismo inicio de sesión
select public.admin_set_setting('ai_budget', '{"monthly_usd": 20, "per_user_daily_requests": 30}', 'password');
select test.eq((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'), 20::numeric,
               'presupuesto: el dueño lo fija con confirmación');

-- 6. Reporte diario con datos reales
select public.admin_set_setting('daily_report', jsonb_build_object('enabled', true, 'timezone', 'America/New_York',
  'hour', extract(hour from now() at time zone 'America/New_York')::int));
select test.logout();
delete from public.daily_reports;  -- dentro de la prueba; en el proyecto real todo se deshace al final
select test.eq(public.run_daily_report_if_due(), true, 'reporte: se genera a la hora elegida (hora de Miami)');
select test.eq(public.run_daily_report_if_due(), false, 'reporte: no se genera dos veces');
select test.login('00000000-0000-0000-0000-00000000000a');
do $$
declare d jsonb := (select data from public.daily_reports order by generated_at desc limit 1);
begin
  perform test.eq(d ->> 'timezone', 'America/New_York', 'reporte: guarda la zona horaria');
  perform test.eq(jsonb_array_length(d -> 'priorities') between 1 and 5, true, 'reporte: hasta cinco prioridades');
  perform test.eq(jsonb_array_length(d -> 'unavailable') > 0, true, 'reporte: dice qué datos todavía no existen');
  perform test.eq((d -> 'current' ->> 'recharges_pending')::int,
                  (select count(*)::int from public.topup_requests where status = 'pending'), 'reporte: recargas pendientes reales');
  perform test.eq(d ? 'previous_day', true, 'reporte: compara con el día anterior');
  perform test.eq((public.admin_generate_daily_report(current_date) ->> 'date')::date, current_date,
                  'reporte: el admin puede generarlo a pedido');
end $$;
select test.logout();

\o
\echo 'PRUEBAS DEL CENTRO DE CONTROL IA PASARON'
