-- Pruebas de la verificación de identidad con Didit (0017): sandbox sin costo,
-- el resultado nunca aprueba solo, el sandbox nunca cuenta como real, sin datos
-- personales guardados y la exigencia opcional al aprobar. Corre después de 92.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_id (k text primary key, v text);
grant all on t_id to authenticated;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000009e1', 'id-pro@test.bo', '{"full_name":"Marta Identidad","city_id":"1"}'),
  ('00000000-0000-0000-0000-0000000009e2', 'id-cliente@test.bo', '{"full_name":"Juan Cliente","city_id":"1"}');
select test.login('00000000-0000-0000-0000-0000000009e1');
select public.start_professional_application();
update public.professional_profiles set display_name = 'Marta Identidad', primary_category_id = 1, city_id = 1
 where user_id = auth.uid();
insert into public.professional_documents (professional_id, doc_type, storage_path) values (auth.uid(), 'ci_anverso', auth.uid() || '/ci.jpg');
select public.submit_professional_application();

-- 1. Solo el servidor crea sesiones; la persona ve solo su estado.
select test.expect_error($$select public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', true)$$, 'permission denied');
select test.eq(public.my_identity_check() ->> 'status', 'none', 'identidad: sin verificación todavía');
select test.logout();
do $$ begin
  perform test.eq(public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e2', true) ->> 'reason', 'no_application',
                  'identidad: solo quien postula');
end $$;

-- 2. Sandbox: se crea gratis; en real con el proveedor apagado, se frena.
do $$
declare g jsonb := public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', true);
begin
  perform test.eq((g ->> 'allowed')::boolean, true, 'identidad: el sandbox crea la sesión');
  insert into t_id values ('c1', g ->> 'id');
  perform test.eq(public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', false) ->> 'reason', 'vendor_off',
                  'identidad: uso real sin autorización, se frena');
  perform test.eq((select count(*)::int from public.cost_usage where vendor_key = 'didit_kyc' and sandbox and allowed), 1,
                  'identidad: el sandbox queda registrado sin costo');
end $$;
select public.hmy_identity_session((select v from t_id where k = 'c1')::bigint, 'ses-sbx-1', 'https://verify.didit.me/s/1');
select test.expect_error(format('select public.hmy_identity_session(%s, %L, %L)', (select v from t_id where k = 'c1'), 'x', 'http://mal'),
                         'HMY_INVALID_SESSION');
do $$ begin
  perform test.eq((public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', true) ->> 'resume')::boolean, true,
                  'identidad: una sesión abierta se retoma (no se paga otra)');
end $$;

-- 3. Resultado: solo estado, puntajes y avisos; nunca aprueba al profesional.
do $$
declare r jsonb;
begin
  r := public.hmy_identity_decision('ses-sbx-1', 'Approved',
         '{"document_type": "Identity Card", "id_document_status": "Approved", "liveness_score": 95.4,
           "face_match_score": 96.1, "warnings": [], "first_name": "Marta", "date_of_birth": "1990-01-01"}', 'ev1', true);
  perform test.eq(r ->> 'status', 'approved', 'identidad: guarda el resultado');
  perform test.eq((select status from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000009e1')::text,
                  'submitted', 'identidad: el resultado no aprueba al profesional');
  perform test.eq((select to_jsonb(c)::text ~* 'Marta|1990' from public.identity_checks c where session_id = 'ses-sbx-1'), false,
                  'identidad: no guarda nombre ni fecha de nacimiento');
  perform test.eq(public.hmy_identity_decision('ses-sbx-1', 'Approved', '{}', 'ev1', true) ->> 'reason', 'duplicate',
                  'identidad: el mismo aviso dos veces no cambia nada');
  perform test.eq(public.hmy_identity_decision('ses-sbx-1', 'In Progress', '{}', 'ev0', true) ->> 'reason', 'stale',
                  'identidad: un aviso atrasado no borra el resultado');
  perform test.eq(public.hmy_identity_decision('nadie', 'Approved', '{}', 'ev9', true) ->> 'reason', 'unknown_session',
                  'identidad: sesión desconocida, se ignora');
end $$;
select test.expect_error($$select public.hmy_identity_decision('ses-sbx-1', 'Approved', '{}', 'ev2', false)$$,
                         'HMY_ENVIRONMENT_MISMATCH');
select test.expect_error($$select public.hmy_identity_decision('ses-sbx-1', 'Aprobadísimo', '{}', 'ev3', true)$$,
                         'HMY_INVALID_STATUS');
do $$ begin
  perform test.eq(public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', true) ->> 'reason', 'already_approved',
                  'identidad: ya aprobada, no se repite');
  perform test.eq((select count(*)::int from public.hmy_identity_pending() where session_id = 'ses-sbx-1'), 1,
                  'identidad: pendiente de borrar en Didit');
  perform public.hmy_identity_deleted('ses-sbx-1');
  perform test.eq((select count(*)::int from public.hmy_identity_pending() where session_id = 'ses-sbx-1'), 0,
                  'identidad: borrada en Didit');
end $$;

-- 4. El profesional ve su estado; el equipo, el detalle en la postulación.
select test.login('00000000-0000-0000-0000-0000000009e1');
select test.eq(public.my_identity_check() ->> 'status', 'approved', 'identidad: el profesional ve su estado');
select test.eq((public.my_identity_check() ->> 'sandbox')::boolean, true, 'identidad: y que fue una prueba');
select test.eq((select count(*)::int from public.identity_checks), 0, 'identidad: no lee la tabla directamente');
select test.login('00000000-0000-0000-0000-00000000000a');
do $$
declare d jsonb := public.admin_application_detail('00000000-0000-0000-0000-0000000009e1');
begin
  perform test.eq(jsonb_array_length(d -> 'identity_checks'), 1, 'identidad: el equipo la ve en la postulación');
  perform test.eq((d -> 'identity_checks' -> 0 ->> 'face_match_score')::numeric, 96.1::numeric, 'identidad: con los puntajes');
  perform test.eq((d ->> 'identity_check_required')::boolean, false, 'identidad: hoy no se exige');
end $$;

-- 5. Si se exige, una prueba del sandbox no alcanza: hace falta una real aprobada.
select public.admin_set_setting('identity_check', '{"required": true}');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000009e1', 'approved')$$,
                         'HMY_IDENTITY_CHECK_REQUIRED');
select test.expect_error($$select public.admin_set_setting('identity_check', '{"required": false}')$$, 'HMY_CONFIRMATION');
select test.logout();
insert into public.identity_checks (professional_id, sandbox, session_id, status)
values ('00000000-0000-0000-0000-0000000009e1', false, 'ses-real-1', 'approved');
select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000009e1', 'approved');
select test.eq((select status from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000009e1')::text,
               'approved', 'identidad: con una verificación real, el equipo puede aprobar');
select test.login_pw('00000000-0000-0000-0000-00000000000a', 30);
select public.admin_set_setting('identity_check', '{"required": false}', 'password');
select test.logout();

-- 6. En real: máximo 3 intentos al mes por profesional; un rechazo avisa al equipo.
update public.professional_profiles set status = 'reverification_required' where user_id = '00000000-0000-0000-0000-0000000009e1';
update public.cost_vendors set status = 'free', free_units_month = 30 where key = 'didit_kyc';
do $$
declare g jsonb;
begin
  g := public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', false);
  perform test.eq((g ->> 'allowed')::boolean, true, 'identidad: dentro del plan gratis, en real pasa');
  perform public.hmy_identity_session((g ->> 'id')::bigint, 'ses-real-2', 'https://verify.didit.me/s/2');
  perform public.hmy_identity_decision('ses-real-2', 'Declined', '{"warnings": ["FACE_MISMATCH"]}', 'ev10', false);
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key = format('identity:%s:declined', g ->> 'id')), 1,
                  'identidad: un rechazo avisa al equipo');
  g := public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', false);
  perform public.hmy_identity_failed((g ->> 'id')::bigint);
  perform test.eq(public.hmy_identity_begin('00000000-0000-0000-0000-0000000009e1', false) ->> 'reason', 'attempt_limit',
                  'identidad: máximo 3 intentos reales en 30 días');
end $$;

-- Deja todo como estaba.
update public.cost_vendors set status = 'sandbox' where key = 'didit_kyc';
delete from public.cost_usage where vendor_key = 'didit_kyc';
delete from public.ai_items where dedupe_key like 'identity:%';

\o
\echo 'PRUEBAS DE VERIFICACIÓN DE IDENTIDAD PASARON'
