-- Pruebas de 0019: Didit devuelve la misma sesión abierta y la base la enlaza
-- al intento que ya la tenía, sin aceptar la de otro profesional ni un enlace
-- que no sea de Didit. Corre después de 94.
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_at (k text primary key, v text);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000af1', 'at-pro1@test.bo', '{"full_name":"Pro Uno","city_id":"1"}'),
  ('00000000-0000-0000-0000-000000000af2', 'at-pro2@test.bo', '{"full_name":"Pro Dos","city_id":"1"}');
select test.login('00000000-0000-0000-0000-000000000af1');
select public.start_professional_application();
select test.login('00000000-0000-0000-0000-000000000af2');
select public.start_professional_application();
select test.logout();

-- 1. Solo el servidor.
select test.login('00000000-0000-0000-0000-000000000af1');
select test.expect_error($$select public.hmy_identity_attach(1, 'x', 'https://verify.didit.me/s/x')$$, 'permission denied');
select test.expect_error($$select public.hmy_identity_session_free(1, 'x')$$, 'permission denied');
select test.expect_error($$select public.hmy_identity_forget_link(1)$$, 'permission denied');
select test.logout();

do $$
declare g jsonb; r jsonb; v_first bigint;
begin
  -- 2. Sesión nueva: se enlaza.
  g := public.hmy_identity_begin('00000000-0000-0000-0000-000000000af1', true);
  v_first := (g ->> 'id')::bigint;
  insert into t_at values ('first', v_first::text);
  perform test.expect_error(format($q$select public.hmy_identity_attach(%s, 'a1', 'https://evil.example/s/a1')$q$, v_first),
                            'HMY_INVALID_SESSION');
  perform test.expect_error(format($q$select public.hmy_identity_attach(%s, 'a1', 'https://verify.didit.me.evil.io/s')$q$, v_first),
                            'HMY_INVALID_SESSION');
  r := public.hmy_identity_attach(v_first, 'a1', 'https://verify.didit.me/session/t1');
  perform test.eq((r ->> 'saved')::boolean, true, 'enlazar: una sesión nueva se guarda');
  perform test.eq((r ->> 'reused')::boolean, false, 'enlazar: y no es reutilizada');
  perform test.eq(public.hmy_identity_session_free(v_first, 'a1'), true, 'enlazar: la sesión es de este intento');
  perform test.eq(public.hmy_identity_session_free(null, 'a1'), false, 'enlazar: para otro intento, no se puede borrar');
  perform test.eq(public.hmy_identity_session_free(null, 'zz'), true, 'enlazar: una sesión desconocida sí');

  -- 3. Más de una hora después, Didit devuelve la misma sesión abierta: se reutiliza.
  update public.identity_checks set created_at = now() - interval '2 hours' where id = v_first;
  g := public.hmy_identity_begin('00000000-0000-0000-0000-000000000af1', true);
  perform test.eq((g ->> 'resume')::boolean, false, 'enlazar: pasada la hora no se retoma sola');
  r := public.hmy_identity_attach((g ->> 'id')::bigint, 'a1', 'https://verify.didit.me/session/t1b');
  perform test.eq((r ->> 'saved')::boolean, true, 'enlazar: la misma sesión de Didit no choca');
  perform test.eq((r ->> 'check')::bigint, v_first, 'enlazar: queda en el intento que ya la tenía');
  perform test.eq((select count(*)::int from public.identity_checks where id = (g ->> 'id')::bigint), 0,
                  'enlazar: el intento vacío se quita');
  perform test.eq((select verification_url from public.identity_checks where id = v_first),
                  'https://verify.didit.me/session/t1b', 'enlazar: con el enlace nuevo');

  -- 4. La sesión de otro profesional nunca se acepta.
  g := public.hmy_identity_begin('00000000-0000-0000-0000-000000000af2', true);
  r := public.hmy_identity_attach((g ->> 'id')::bigint, 'a1', 'https://verify.didit.me/session/x');
  perform test.eq(r ->> 'reason', 'session_conflict', 'enlazar: la sesión de otro profesional se rechaza');
  perform test.eq((select professional_id from public.identity_checks where session_id = 'a1')::text,
                  '00000000-0000-0000-0000-000000000af1', 'enlazar: y sigue siendo del primero');
  perform public.hmy_identity_failed((g ->> 'id')::bigint);

  -- 5. Una sesión ya cerrada tampoco.
  perform public.hmy_identity_decision('a1', 'Approved', '{}', 'ev-a1', true);
  update public.professional_profiles set status = 'reverification_required' where user_id = '00000000-0000-0000-0000-000000000af1';
  g := public.hmy_identity_begin('00000000-0000-0000-0000-000000000af1', true);
  r := public.hmy_identity_attach((g ->> 'id')::bigint, 'a1', 'https://verify.didit.me/session/y');
  perform test.eq(r ->> 'reason', 'session_conflict', 'enlazar: una sesión ya decidida no se reutiliza');
  perform test.eq((public.hmy_identity_attach((g ->> 'id')::bigint, 'a2', 'https://verify.didit.me/session/a2') ->> 'saved')::boolean,
                  true, 'enlazar: el mismo intento acepta una sesión nueva');
  perform test.eq(public.hmy_identity_attach((g ->> 'id')::bigint, 'a3', 'https://verify.didit.me/session/a3') ->> 'reason',
                  'check_not_open', 'enlazar: un intento ya enlazado no cambia de sesión');

  -- 6. Un enlace guardado que no pasó la revisión deja de retomarse.
  perform test.eq((public.hmy_identity_begin('00000000-0000-0000-0000-000000000af1', true) ->> 'resume')::boolean, true,
                  'enlace: antes se retoma');
  perform public.hmy_identity_forget_link((g ->> 'id')::bigint);
  perform test.eq((select verification_url from public.identity_checks where id = (g ->> 'id')::bigint) is null, true,
                  'enlace: se borra');
  g := public.hmy_identity_begin('00000000-0000-0000-0000-000000000af1', true);
  perform test.eq((g ->> 'resume')::boolean, false, 'enlace: y ya no se entrega');
  r := public.hmy_identity_attach((g ->> 'id')::bigint, 'a2', 'https://verify.didit.me/session/a2b');
  perform test.eq((r ->> 'reused')::boolean, true, 'enlace: Didit devuelve la misma sesión y se recupera');
end $$;

-- Deja todo como estaba.
delete from public.cost_usage where vendor_key = 'didit_kyc';

\o
\echo 'PRUEBAS DE ENLACE DE SESIONES DE DIDIT PASARON'
