-- Pruebas de los agentes con reglas (0018): avisan al equipo, no deciden.
-- Corre después de 93 y usa las cuentas arr-* (90) e id-* (93).
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_ra (k text primary key, v text);
grant all on t_ra to authenticated;

-- Un pedido "en camino" hace 4 horas, y tres llegadas con atraso.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_ra select 'b', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Revisar la ducha', 'Calle Reglas 1');
insert into t_ra select 'l' || i, public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Trabajo ' || i, 'Calle Reglas 2')
  from generate_series(1, 3) i;
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.agree((select v from t_ra where k = 'b')::uuid);
select public.update_job_progress((select v from t_ra where k = 'b')::uuid, 'on_the_way');
select test.logout();
update public.booking_events set created_at = now() - interval '4 hours'
 where booking_id = (select v from t_ra where k = 'b')::uuid and to_status = 'on_the_way';
insert into public.booking_arrivals (booking_id, professional_id, verified_at, method, delay_minutes)
select v::uuid, '00000000-0000-0000-0000-0000000009b1', now(), 'pin', 25 from t_ra where k like 'l%';

-- Un borrador viejo sin documentos.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000009f1', 'reglas-pro@test.bo', '{"full_name":"Pedro Borrador","city_id":"1"}');
select test.login('00000000-0000-0000-0000-0000000009f1');
select public.start_professional_application();
select test.logout();
update public.professional_profiles set created_at = now() - interval '3 days'
 where user_id = '00000000-0000-0000-0000-0000000009f1';

-- Un aprobado cuyo carnet dejó de estar aceptado (prueba 90), para la alerta.
update public.professional_documents set status = 'pending' where professional_id = '00000000-0000-0000-0000-0000000009b1';

-- Un documento aceptado que vence pronto (profesional de la prueba 93, aprobado).
update public.professional_profiles set status = 'approved' where user_id = '00000000-0000-0000-0000-0000000009e1';
update public.professional_documents set status = 'accepted', expires_on = current_date + 10
 where professional_id = '00000000-0000-0000-0000-0000000009e1'
   and storage_path not like '%/ci-_.jpg'; -- no el carnet de test.accept_id

-- 1. Solo el equipo los corre a mano.
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error('select public.admin_run_rule_agents()', 'HMY_FORBIDDEN');
select test.expect_error('select public.run_rule_agents()', 'permission denied');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq(public.admin_run_rule_agents() > 0, true, 'reglas: corren y avisan');
select test.eq(public.admin_run_rule_agents(), 0, 'reglas: no repiten avisos');
select test.logout();

do $$ begin
  perform test.eq((select count(*)::int from public.ai_items
                   where dedupe_key = 'trip-stuck:' || (select v from t_ra where k = 'b')), 1,
                  'seguridad: "en camino" por horas sin llegada avisa al equipo');
  perform test.eq((select severity from public.ai_items where dedupe_key = 'trip-stuck:' || (select v from t_ra where k = 'b')),
                  'high', 'seguridad: con prioridad alta');
  perform test.eq((select count(*)::int from public.ai_items
                   where agent_key = 'punctuality' and target_id = '00000000-0000-0000-0000-0000000009b1'), 1,
                  'puntualidad: tres atrasos en 30 días avisan');
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key = 'no-ci:00000000-0000-0000-0000-0000000009b1'), 1,
                  'documentos: aprobado sin carnet aceptado avisa');
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key like 'doc-expiry:%:soon'
                   and target_id in (select id::text from public.professional_documents
                                     where professional_id = '00000000-0000-0000-0000-0000000009e1')), 1,
                  'documentos: por vencer avisa');
  perform test.eq((select count(*)::int from public.notifications
                   where user_id = '00000000-0000-0000-0000-0000000009f1' and title = 'Te falta poco para postular'), 1,
                  'asistente: le dice al profesional qué falta, una vez');
  perform test.eq((select status from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000009b1')::text,
                  'approved', 'reglas: nadie es suspendido ni rechazado por una regla');
  perform test.eq((select count(*)::int from public.ai_agents
                   where key in ('service_safety', 'punctuality', 'background', 'pro_assistant') and status = 'rules'), 4,
                  'reglas: cuatro agentes más funcionan sin IA pagada');
  perform test.eq((select count(*)::int from public.ai_agent_runs where cost_usd > 0), 0, 'reglas: sin costo de IA');
end $$;

\o
\echo 'PRUEBAS DE AGENTES CON REGLAS PASARON'
