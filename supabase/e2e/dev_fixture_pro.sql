-- Profesional de prueba …02, solo en DESARROLLO (proyecto yldqopeldibwgbwmdnzy).
--   aprobar   deja a …02 aprobado como PERFIL DE PRUEBA (test_fixture), disponible
--             para ¡Ya! con lo que ya cargó en la app (Plomería, su municipio y zonas)
--   revertir  lo deja como estaba: borrador, sin la marca, sin los registros de prueba
--   saldo     carga Bs 100 de SALDO DE PRUEBA a la billetera de …02 (una sola vez:
--             la clave lo hace idempotente). No es dinero real ni una recarga; queda
--             como ajuste "Saldo de prueba (no es dinero real)" en el historial.
--   qr-simulado  activa el QR SIMULADO de desarrollo (proveedor 'dev_mock'): solo
--             perfiles de prueba generan QR, que no se pagan en ningún banco; el pago
--             se simula en la app y la recarga queda marcada "simulada"
--   qr-apagado   lo apaga (sin QR, solo transferencia bancaria)
--   estado    solo lectura
-- No es una verificación de identidad: no crea ninguna verificación (Didit) y los
-- clientes no lo ven como "Verificado". La regla de aprobación no cambia: la base
-- exige el carnet aceptado, así que se crean dos registros de carnet SIN archivo,
-- marcados como de prueba ("dev-fixture/…, no es un documento"), que "revertir" borra.
-- Todo queda en verification_events y admin_audit_log como "dev_fixture".
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -v action=estado -f supabase/e2e/dev_fixture_pro.sql
\set ON_ERROR_STOP 1
begin;
select :'action' in ('aprobar', 'revertir', 'saldo', 'qr-simulado', 'qr-apagado', 'estado') as action_ok \gset
\if :action_ok
\else
  \echo 'Acción desconocida: usa aprobar, revertir, saldo, qr-simulado, qr-apagado o estado.'
  \quit
\endif
-- Sin la cuenta …02, \gset no recibe fila y psql se detiene.
select id as p_id from auth.users where phone = '59170000002' \gset

-- Solo con las cuentas de prueba en la base: nunca donde haya personas reales.
do $$
begin
  if exists (select 1 from auth.users
             where coalesce(phone, '') not in ('59170000001', '59170000002', '59170000003', '59170000004', '59170000005')
               and coalesce(email, '') not like 'e2e-%@test.bo') then
    raise exception 'Hay cuentas que no son de prueba: no se hace nada';
  end if;
end $$;

select :'action' = 'aprobar' as do_approve, :'action' = 'revertir' as do_revert, :'action' = 'saldo' as do_balance,
       :'action' in ('qr-simulado', 'qr-apagado') as do_qr \gset

\if :do_approve
do $$
declare
  v_pro uuid := (select id from auth.users where phone = '59170000002');
  p public.professional_profiles;
  v_note constant text := 'FIXTURE DE DESARROLLO: perfil de prueba, sin verificación de identidad real';
begin
  select * into p from public.professional_profiles where user_id = v_pro for update;
  if not found then raise exception '…02 todavía no tiene postulación: guárdala en la app primero'; end if;
  if p.test_fixture and p.status = 'approved' then
    raise notice '…02 ya es un perfil de prueba aprobado; no se cambia nada';
    return;
  end if;
  if p.status not in ('draft', 'submitted', 'under_review') then
    raise exception '…02 está en estado %: no se aprueba como prueba', p.status;
  end if;
  if char_length(trim(p.display_name)) < 3 or p.city_id is null or p.primary_category_id is null then
    raise exception 'A la postulación de …02 le falta nombre, municipio o servicio';
  end if;
  if coalesce((select (value ->> 'required')::boolean from public.app_settings where key = 'identity_check'), false) then
    raise exception 'Este proyecto exige verificación de identidad real: no se aprueba como prueba';
  end if;

  insert into public.professional_documents (professional_id, doc_type, storage_path, status, review_note)
  select v_pro, t, 'dev-fixture/' || v_pro || '/' || t || '-no-es-un-documento', 'accepted',
         'FIXTURE DE DESARROLLO: no es un documento de identidad'
  from unnest(array['ci_anverso', 'ci_reverso']) t;

  update public.professional_profiles set test_fixture = true where user_id = v_pro;
  update public.professional_profiles
  set status = 'approved', submitted_at = coalesce(submitted_at, now()), reviewed_at = now(), reviewed_by = null,
      review_note = v_note, is_available = true, available_since = now()
  where user_id = v_pro;
  insert into public.verification_events (professional_id, from_status, to_status, actor_id, note)
  values (v_pro, p.status, 'approved', null, v_note);
  insert into public.user_roles (user_id, role) values (v_pro, 'professional') on conflict do nothing;
  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (null, 'dev_fixture.approve', 'professional_profiles', v_pro::text,
          jsonb_build_object('from', p.status, 'note', v_note));
  raise notice '…02 aprobado como perfil de prueba y disponible para ¡Ya!';
end $$;
\endif

\if :do_revert
do $$
declare
  v_pro uuid := (select id from auth.users where phone = '59170000002');
  p public.professional_profiles;
begin
  select * into p from public.professional_profiles where user_id = v_pro for update;
  if not found or not p.test_fixture then
    raise notice '…02 no es un perfil de prueba; no se cambia nada';
    return;
  end if;
  if exists (select 1 from public.bookings where professional_id = v_pro
             and status in ('quote_sent', 'awaiting_confirmation', 'confirmed', 'on_the_way', 'in_progress', 'work_finished')) then
    raise exception '…02 tiene un trabajo en curso: termínalo o cancélalo primero';
  end if;
  update public.professional_profiles
  set status = 'draft', is_available = false, available_since = null, reviewed_at = null, review_note = null
  where user_id = v_pro;
  update public.professional_profiles set test_fixture = false where user_id = v_pro;
  delete from public.professional_documents where professional_id = v_pro and storage_path like 'dev-fixture/%';
  delete from public.user_roles where user_id = v_pro and role = 'professional';
  update public.profiles set active_role = 'customer' where id = v_pro and active_role = 'professional';
  insert into public.verification_events (professional_id, from_status, to_status, actor_id, note)
  values (v_pro, p.status, 'draft', null, 'FIXTURE DE DESARROLLO: revertido');
  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (null, 'dev_fixture.revert', 'professional_profiles', v_pro::text, jsonb_build_object('from', p.status));
  raise notice '…02 volvió a borrador, sin la marca de prueba';
end $$;
\endif

\if :do_balance
do $$
declare v_pro uuid := (select id from auth.users where phone = '59170000002');
begin
  if not exists (select 1 from public.professional_profiles where user_id = v_pro and test_fixture) then
    raise exception 'Solo para …02 marcado como perfil de prueba: usa "aprobar" primero';
  end if;
  insert into public.wallets (professional_id) values (v_pro) on conflict do nothing;
  if exists (select 1 from public.wallet_ledger where idempotency_key = 'adjust:dev-fixture-saldo-1') then
    raise notice 'El saldo de prueba ya estaba cargado: no se carga otra vez';
  else
    perform public.wallet_post(v_pro, 'adjustment', 100, 0, 'adjust:dev-fixture-saldo-1', null, null,
                               'Saldo de prueba (no es dinero real)');
    insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
    values (null, 'dev_fixture.test_balance', 'wallets', v_pro::text, jsonb_build_object('amount', 100));
    raise notice 'Bs 100 de saldo de prueba cargados a …02';
  end if;
end $$;
\endif

\if :do_qr
delete from public.app_settings where key = 'qr_recharge_provider';
insert into public.app_settings (key, value)
select 'qr_recharge_provider', '{"provider": "dev_mock"}'::jsonb where :'action' = 'qr-simulado';
insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
values (null, 'dev_fixture.qr_provider', 'app_settings', 'qr_recharge_provider',
        jsonb_build_object('provider', case when :'action' = 'qr-simulado' then 'dev_mock' end));
\endif

\echo '== …02 =='
select 'estado ' || pp.status || ' · perfil de prueba=' || pp.test_fixture || ' · disponible=' || pp.is_available
       || ' · rol profesional=' || exists (select 1 from public.user_roles r where r.user_id = pp.user_id and r.role = 'professional')
       || ' · ciudad ' || coalesce((select name from public.cities where id = pp.city_id), '-')
       || ' · zonas: ' || coalesce((select string_agg(zn.name, ', ' order by zn.name) from public.professional_zones z
                                    join public.service_zones zn on zn.id = z.zone_id where z.professional_id = pp.user_id), '-')
       || ' · carnet de prueba: ' || (select count(*) from public.professional_documents d
                                      where d.professional_id = pp.user_id and d.storage_path like 'dev-fixture/%')
       || ' · verificación de identidad: ' || coalesce((select status::text from public.identity_checks i
                                                       where i.professional_id = pp.user_id order by created_at desc limit 1), 'ninguna')
       || ' · saldo disponible Bs ' || coalesce((select available::text from public.wallets w where w.professional_id = pp.user_id), '-')
       || ' (de prueba: Bs ' || coalesce((select sum(available_delta)::text from public.wallet_ledger l
                                         where l.professional_id = pp.user_id and l.idempotency_key like 'adjust:dev-fixture-%'), '0') || ')'
       || ' · QR de recarga: ' || coalesce(public.hmy_qr_provider(), 'apagado')
       || ' · teléfonos con avisos: ' || (select count(*) from public.push_devices d where d.user_id = pp.user_id and d.disabled_at is null)
from public.professional_profiles pp where pp.user_id = :'p_id';
select '¡Ya! de Plomería de …01, todo el municipio: le llega a '
       || coalesce(string_agg(case when e = :'p_id'::uuid then '…02' else 'otra cuenta' end, ', '), 'nadie')
from public.ya_eligible_professionals(
       (select id from public.service_categories where slug = 'plomeria'),
       (select city_id from public.professional_profiles where user_id = :'p_id'),
       null, (select id from auth.users where phone = '59170000001')) e;
-- Trabajos de …02 (solo códigos y estados, sin datos personales) y si salen en
-- su lista "Mis trabajos", vista como …02 (my_bookings tiene un límite de 100).
select 'trabajos de …02: ' || count(*) || ' en total · activos: '
       || count(*) filter (where status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished'))
from public.bookings where professional_id = :'p_id';
select '(lo que sigue, visto como …02)' where set_config('request.jwt.claims', json_build_object('sub', :'p_id', 'role', 'authenticated')::text, true) is not null;
select 'lista de …02: ' || count(*) || ' filas (' || count(*) filter (where is_offer) || ' ofertas)'
from public.my_bookings('professional');
select 'activo ' || b.code || ' · ' || b.status || ' · ' || b.mode || ' · acordado Bs ' || coalesce(b.agreed_amount::text, '-')
       || ' · reservado Bs ' || b.commission_reserved || ' · creado ' || to_char(b.created_at at time zone 'America/La_Paz', 'DD-MM HH24:MI')
       || ' · en su lista: ' || exists (select 1 from public.my_bookings('professional') m where m.id = b.id)
from public.bookings b
where b.professional_id = :'p_id' and b.status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished')
order by b.created_at desc limit 10;
select 'pedido F9A50778: ' || coalesce((select b.status || ' · ' || b.mode || ' · profesional '
       || case when b.professional_id = :'p_id'::uuid then '…02' when b.professional_id is null then 'ninguno' else 'otra cuenta' end
       || ' · acordado Bs ' || coalesce(b.agreed_amount::text, '-') || ' · reservado Bs ' || b.commission_reserved
       || ' · en la lista de …02: ' || exists (select 1 from public.my_bookings('professional') m where m.id = b.id)
       from public.bookings b where b.code = 'F9A50778'), 'no existe');
commit;
