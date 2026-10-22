-- Estado veraz de los agentes (0036): solo se ve "activo" lo que de verdad se
-- ejecutó, cada revisión deja su fila por agente y los avisos se abren con su
-- origen y se cierran con una nota auditada. Corre después de 99c.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_ta (k text primary key, v text);
grant all on t_ta to authenticated, anon;

-- 1. Estado sembrado veraz
do $$ begin
  perform test.eq((select string_agg(key, ',' order by number) from public.ai_agents where status = 'planned'),
                  'customer_assistant,qa,marketing,recruitment,launch,performance,pricing,invoicing,notifications',
                  'estado: lo que no está construido queda planificado');
  perform test.eq((select string_agg(key, ',' order by number) from public.ai_agents where status = 'needs_setup'),
                  'identity', 'estado: solo identidad espera configuración (Didit en sandbox)');
  perform test.eq((select count(*)::int from public.ai_agents where status = 'ai'), 0,
                  'estado: ningún agente usa IA (presupuesto 0)');
  perform test.eq((select status from public.ai_agents where key = 'support'), 'rules',
                  'estado: soporte corre una regla (tickets atrasados)');
  perform test.eq((select count(*)::int from public.ai_agents where status = 'rules'
                   and (schedule is null or max_gap_minutes is null)), 0,
                  'estado: cada agente con reglas dice cuándo corre');
  perform test.eq((select count(*)::int from public.ai_agents where status in ('planned', 'needs_setup')
                   and max_gap_minutes is not null), 0, 'estado: lo que no corre no tiene horario');
  perform test.eq((select prosrc from pg_proc where proname = 'generate_daily_report') like '%''sos''%', false,
                  'reporte: ya no cuenta un agente "sos" que no existe');
end $$;

-- 2. Solo el administrador
select test.login('00000000-0000-0000-0000-000000000062');
select test.expect_error($$select public.admin_run_all_checks()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_ai_agents()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_ai_item_detail(1)$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.run_rule_agents()$$, 'permission denied');
select test.expect_error($$select public.run_cost_monitors()$$, 'permission denied');
select test.expect_error($$select public.hmy_log_agent_run('boss', now(), 'ok', 'x')$$, 'permission denied');
select test.expect_error($$select public.hmy_agent_run_ok('boss', now(), 0, 1)$$, 'permission denied');
select test.login(null);
select test.expect_error($$select public.admin_run_all_checks()$$, 'permission denied');
select test.logout();

-- 3. Desde cero: sin ejecuciones no hay "activo"
delete from public.ai_agent_runs;
update public.ai_agents set last_run_at = null, last_run_status = null;
insert into t_ta select 'wallet_sum', (select coalesce(sum(available), 0)::text from public.wallets);
insert into t_ta select 'approved', (select count(*)::text from public.professional_profiles where status = 'approved');
insert into t_ta select 'suspended', (select count(*)::text from public.profiles where suspended_at is not null);
insert into t_ta select 'paid_usage', (select count(*)::text from public.cost_usage where cost_usd > 0);
select test.login('00000000-0000-0000-0000-00000000000a');
do $$
declare a jsonb := public.admin_ai_agents();
begin
  perform test.eq(jsonb_array_length(a), 26, 'panel: los 26 agentes');
  perform test.eq((select count(*)::int from jsonb_array_elements(a) e where e ->> 'execution' = 'active'), 0,
                  'panel: sin ejecuciones, ningún agente se ve activo');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'wallet'), 'never',
                  'panel: un agente con reglas sin ejecutar dice "nunca"');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'recruitment'), 'not_built',
                  'panel: reclutamiento figura sin construir');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'identity'), 'needs_setup',
                  'panel: identidad espera configuración');
end $$;

-- 4. "Revisar ahora" corre monitores, reglas y costos; una fila por agente que revisó
insert into t_ta select 'all', public.admin_run_all_checks()::text;
do $$
declare
  r jsonb := (select v from t_ta where k = 'all')::jsonb;
  a jsonb := public.admin_ai_agents();
begin
  perform test.eq(r ? 'rules' and r ? 'costs' and r ? 'monitors', true, 'revisar ahora: corre las tres revisiones');
  perform test.eq((r ->> 'failed')::int, 0, 'revisar ahora: sin fallas');
  perform test.eq((select string_agg(distinct agent_key, ',' order by agent_key) from public.ai_agent_runs),
                  'ai_auditor,background,boss,dispatch,disputes,finance,fraud,moderation,privacy,pro_assistant,punctuality,quality,service_safety,support,wallet',
                  'ejecuciones: una fila para cada agente que de verdad revisó algo');
  perform test.eq((select count(*)::int from public.ai_agent_runs where status <> 'ok' or finished_at is null), 0,
                  'ejecuciones: todas terminaron bien');
  perform test.eq((select count(*)::int from public.ai_agent_runs where agent_key = 'background'), 2,
                  'ejecuciones: antecedentes corre en monitores y en reglas');
  perform test.eq((select count(*)::int from public.ai_agents where last_run_at is not null
                   and key not in (select agent_key from public.ai_agent_runs)), 0,
                  'última vez: solo para agentes que se ejecutaron');
  perform test.eq((select count(*)::int from public.ai_agents where status = 'planned' and last_run_at is not null), 0,
                  'última vez: nada para lo planificado');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'support'), 'active',
                  'panel: soporte activo después de ejecutarse');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'daily_report'), 'never',
                  'panel: el reporte diario no se marca activo por la revisión');
  perform test.eq((select (e ->> 'last_ok_run_at') is not null from jsonb_array_elements(a) e where e ->> 'key' = 'finance'),
                  true, 'panel: la última ejecución correcta sale del historial');
  perform test.eq((public.admin_ai_overview() ->> 'last_monitor_run')::timestamptz,
                  (select max(finished_at) from public.ai_agent_runs where agent_key = 'boss' and status = 'ok'),
                  'panel: última revisión = última ejecución del AI Boss');
  perform test.eq((select count(*)::int from public.admin_audit_log where action = 'ai.run_checks'), 1,
                  'auditoría: "Revisar ahora" queda registrado');
end $$;
select public.admin_generate_daily_report();
select test.eq((select count(*)::int from public.ai_agent_runs where agent_key = 'daily_report' and status = 'ok'), 1,
               'reporte: generarlo a pedido deja su ejecución');
select test.logout();

-- 5. Los agentes no deciden: saldos, aprobaciones, suspensiones y gasto quedan igual
do $$ begin
  perform test.eq((select coalesce(sum(available), 0)::text from public.wallets), (select v from t_ta where k = 'wallet_sum'),
                  'seguridad: ningún saldo cambió');
  perform test.eq((select count(*)::text from public.professional_profiles where status = 'approved'),
                  (select v from t_ta where k = 'approved'), 'seguridad: nadie fue aprobado ni rechazado');
  perform test.eq((select count(*)::text from public.profiles where suspended_at is not null),
                  (select v from t_ta where k = 'suspended'), 'seguridad: nadie fue suspendido');
  perform test.eq((select count(*)::text from public.cost_usage where cost_usd > 0), (select v from t_ta where k = 'paid_usage'),
                  'seguridad: no se gastó dinero');
  perform test.eq((select coalesce(sum(cost_usd), 0) from public.ai_agent_runs), 0::numeric, 'seguridad: sin costo de IA');
end $$;

-- 6. Una regla que falla queda registrada (solo el código) y las demás siguen
alter table public.support_tickets rename to support_tickets_off;
select test.login('00000000-0000-0000-0000-00000000000a');
insert into t_ta select 'fail', public.admin_run_all_checks()::text;
select test.logout();
alter table public.support_tickets_off rename to support_tickets;
select test.login('00000000-0000-0000-0000-00000000000a');
do $$
declare a jsonb := public.admin_ai_agents();
begin
  perform test.eq(((select v from t_ta where k = 'fail')::jsonb ->> 'failed')::int, 1, 'falla: se informa');
  perform test.eq((select status || ':' || error from public.ai_agent_runs where agent_key = 'support' order by id desc limit 1),
                  'failed:42P01', 'falla: guarda el código, no el texto del error');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'support'), 'failed',
                  'panel: soporte ya no se ve activo');
  perform test.eq((select e ->> 'execution' from jsonb_array_elements(a) e where e ->> 'key' = 'wallet'), 'active',
                  'falla: los demás agentes siguen');
  perform test.eq((select summary from public.ai_agent_runs where agent_key = 'boss' order by id desc limit 1)
                  like '%fallaron: support%', true, 'AI Boss: el resumen dice qué falló');
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key = 'agent-failed:support:' || current_date), 1,
                  'Auditor de IA: ve la falla en la misma revisión');
end $$;
select test.logout();

-- 7. El Auditor avisa si un agente con reglas deja de ejecutarse
update public.app_settings set value = jsonb_build_object('since', now() - interval '1 day') where key = 'agent_run_log';
update public.ai_agent_runs set started_at = now() - interval '5 hours', finished_at = now() - interval '5 hours'
 where agent_key = 'punctuality';
select public.run_marketplace_monitors();
select test.eq((select count(*)::int from public.ai_items where dedupe_key = 'agent-stale:punctuality:' || current_date), 1,
               'Auditor de IA: avisa que puntualidad dejó de ejecutarse');
select test.eq((select count(*)::int from public.ai_items where dedupe_key like 'agent-stale:wallet:%'), 0,
               'Auditor de IA: no avisa de los que sí corrieron');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((select e ->> 'execution' from jsonb_array_elements(public.admin_ai_agents()) e where e ->> 'key' = 'punctuality'),
               'stale', 'panel: puntualidad figura sin ejecución reciente');
select test.logout();

-- 8. Abrir un aviso muestra su origen; cerrarlo exige una nota auditada
insert into t_ta select 'item', public.hmy_raise_item('service_safety', 'alert', 'high', 'rule', 'Prueba de origen',
  'Aviso de prueba.', '{"booking_id": "x"}', 'trip-stuck:prueba-99e', 'bookings', 'prueba-99e')::text;
select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'dismiss')$$, (select v from t_ta where k = 'item')),
                         'HMY_NOTE_REQUIRED');
select test.expect_error(format($$select public.admin_decide_ai_item(%s, 'completed', '  ')$$, (select v from t_ta where k = 'item')),
                         'HMY_NOTE_REQUIRED');
select public.admin_decide_ai_item((select v from t_ta where k = 'item')::bigint, 'completed', 'Llamé al cliente: todo bien');
do $$
declare d jsonb := public.admin_ai_item_detail((select v from t_ta where k = 'item')::bigint);
begin
  perform test.eq(d ->> 'rule', 'trip-stuck', 'detalle: dice qué regla lo creó');
  perform test.eq(d ->> 'agent_name', 'Seguridad en el servicio', 'detalle: dice qué agente');
  perform test.eq((d ->> 'target_table') || ':' || (d ->> 'target_id'), 'bookings:prueba-99e', 'detalle: el registro');
  perform test.eq(d ? 'created_at', true, 'detalle: la hora');
  perform test.eq(d ->> 'status', 'completed', 'detalle: resuelto');
  perform test.eq(d ->> 'decided_by', '00000000-0000-0000-0000-00000000000a', 'detalle: quién lo resolvió');
  perform test.eq(d -> 'history' -> 0 ->> 'note', 'Llamé al cliente: todo bien', 'detalle: el historial trae la nota');
  perform test.eq(d -> 'history' -> 0 ->> 'action', 'ai_item.completed', 'detalle: el historial trae la acción');
end $$;
select test.expect_error($$select public.admin_ai_item_detail(-1)$$, 'HMY_NOT_FOUND');

-- 9. La seguridad en el servicio cuenta en el reporte diario
select test.logout();
select public.hmy_raise_item('service_safety', 'alert', 'high', 'rule', 'Prueba de reporte', null, '{}', 'trip-stuck:prueba-99e-2');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((public.admin_generate_daily_report() -> 'current' ->> 'security_alerts_open')::int,
               (select count(*)::int from public.ai_items where status in ('open', 'more_info')
                and agent_key in ('fraud', 'wallet', 'service_safety') and severity in ('high', 'critical')),
               'reporte: las alertas de seguridad en el servicio cuentan');
select test.logout();

\o
\echo '99e agentes veraces: ok'
