-- Pruebas de costos operativos (0016): plan gratis, frenos sin autorización,
-- tope mensual, tablero y quién puede autorizar. Corre después de 91.
\set ON_ERROR_STOP 1
\o /dev/null

-- Punto de partida conocido (la prueba 80 activó los códigos).
update public.cost_vendors set status = 'off', paid_authorized = false, monthly_cap_usd = 0
 where key in ('whatsapp_otp', 'sms_otp');
update public.cost_vendors set status = 'sandbox', paid_authorized = false, monthly_cap_usd = 0, free_units_month = 30
 where key = 'didit_kyc';
delete from public.cost_usage where vendor_key = 'didit_kyc';

-- 1. Solo el servidor usa la compuerta; solo el equipo ve los costos.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000009d1', 'costo-cliente@test.bo', '{"full_name":"Ana Costos","city_id":"1"}');
select test.login('00000000-0000-0000-0000-0000000009d1');
select test.expect_error($$select public.hmy_cost_gate('didit_kyc')$$, 'permission denied');
select test.expect_error($$select public.admin_cost_dashboard()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.admin_set_vendor('didit_kyc', 'paid', 50, 'password')$$, 'HMY_FORBIDDEN');
select test.eq((select count(*)::int from public.cost_vendors), 0, 'costos: un usuario no ve los proveedores');
select test.logout();

-- 2. Sandbox: pasa y nunca cuesta. En real, apagado: se frena.
do $$
declare g jsonb;
begin
  g := public.hmy_cost_gate('didit_kyc', 1, true);
  perform test.eq((g ->> 'allowed')::boolean, true, 'costos: el sandbox pasa');
  perform test.eq((g ->> 'cost_usd')::numeric, 0::numeric, 'costos: el sandbox no cuesta');
  perform test.eq(public.hmy_cost_gate('didit_kyc', 1, false) ->> 'reason', 'vendor_off',
                  'costos: sin activar el uso real, se frena');
  perform test.eq(public.hmy_cost_gate('veriff', 1, true) ->> 'reason', 'vendor_off', 'costos: Veriff apagado, ni en pruebas');
end $$;

-- 3. Plan gratis: pasa hasta el límite y después se frena (no cobra).
update public.cost_vendors set status = 'free' where key = 'didit_kyc';
do $$
declare g jsonb;
begin
  g := public.hmy_cost_gate('didit_kyc', 29, false);
  perform test.eq((g ->> 'allowed')::boolean, true, 'costos: dentro del plan gratis pasa');
  perform test.eq((g ->> 'cost_usd')::numeric, 0::numeric, 'costos: sin costo');
  perform test.eq((public.hmy_cost_gate('didit_kyc', 1, false) ->> 'allowed')::boolean, true, 'costos: la última gratis pasa');
  g := public.hmy_cost_gate('didit_kyc', 1, false);
  perform test.eq(g ->> 'reason', 'free_tier_exhausted', 'costos: acabado el plan gratis, se frena');
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key like 'cost:didit_kyc:free_tier_exhausted:%'), 1,
                  'costos: avisa al dueño');
  perform public.hmy_cost_gate('didit_kyc', 1, false);
  perform test.eq((select count(*)::int from public.ai_items where dedupe_key like 'cost:didit_kyc:free_tier_exhausted:%'), 1,
                  'costos: un solo aviso por mes');
  perform test.eq((select coalesce(sum(cost_usd), 0) from public.cost_usage where vendor_key = 'didit_kyc'), 0::numeric,
                  'costos: no se cobró nada');
end $$;

-- 4. El dueño autoriza un tope: cobra hasta ahí y no más.
select test.login_pw('00000000-0000-0000-0000-00000000000a', null);
select test.expect_error($$select public.admin_set_vendor('didit_kyc', 'paid', 1, 'password')$$, 'HMY_CONFIRMATION_EXPIRED');
select test.login_pw('00000000-0000-0000-0000-00000000000a', 10);
select test.expect_error($$select public.admin_set_vendor('didit_kyc', 'paid', 0, 'password')$$, 'HMY_CAP_REQUIRED');
select public.admin_set_vendor('didit_kyc', 'paid', 1, 'password');
select test.logout();
do $$
declare g jsonb;
begin
  g := public.hmy_cost_gate('didit_kyc', 3, false);
  perform test.eq((g ->> 'allowed')::boolean, true, 'costos: con autorización, cobra');
  perform test.eq((g ->> 'cost_usd')::numeric, 0.99::numeric, 'costos: al precio por unidad');
  perform test.eq(public.hmy_cost_gate('didit_kyc', 1, false) ->> 'reason', 'monthly_cap', 'costos: nunca pasa el tope');
end $$;

-- 5. Tablero: uso, cargos, proyección y alertas.
select test.login('00000000-0000-0000-0000-00000000000a');
do $$
declare d jsonb := public.admin_cost_dashboard();
        v jsonb;
begin
  select x into v from jsonb_array_elements(d -> 'vendors') x where x ->> 'key' = 'didit_kyc';
  perform test.eq((v ->> 'used_units')::numeric, 33::numeric, 'tablero: cuenta el uso real');
  perform test.eq((v ->> 'sandbox_units')::numeric, 1::numeric, 'tablero: aparte, el uso del sandbox');
  perform test.eq((v ->> 'free_left')::numeric, 0::numeric, 'tablero: plan gratis agotado');
  perform test.eq((v ->> 'cost_so_far_usd')::numeric, 0.99::numeric, 'tablero: cargos del mes');
  perform test.eq((v ->> 'projected_usd')::numeric <= 1, true, 'tablero: la proyección no pasa el tope');
  perform test.eq(v ->> 'level', 'blocked', 'tablero: marca lo que se frenó');
  perform test.eq(jsonb_array_length(d -> 'alerts') >= 1, true, 'tablero: con alertas');
  perform test.eq(jsonb_array_length(d -> 'history'), 6, 'tablero: seis meses de historia');
  select x into v from jsonb_array_elements(d -> 'vendors') x where x ->> 'key' = 'apple_dev';
  perform test.eq((v ->> 'projected_usd')::numeric, 0::numeric, 'tablero: cuotas fijas solo si están contratadas');
end $$;
select test.expect_error('insert into public.cost_usage (vendor_key, allowed) values (''didit_kyc'', true)', 'permission denied');
select test.expect_error('update public.cost_vendors set status = ''paid''', 'permission denied');

-- 6. Frenar no pide confirmación; volver a activar sí.
select public.admin_set_vendor('didit_kyc', 'off');
select test.eq((select status from public.cost_vendors where key = 'didit_kyc'), 'off', 'costos: apagar es inmediato');
select test.eq((select paid_authorized from public.cost_vendors where key = 'didit_kyc'), false, 'costos: y quita la autorización');
select test.expect_error($$select public.admin_set_vendor('didit_kyc', 'sandbox')$$, 'HMY_CONFIRMATION');
select test.expect_error($$select public.admin_set_vendor('apple_dev', 'sandbox')$$, 'HMY_NO_SANDBOX');
select test.eq((select count(*)::int from public.admin_audit_log where action = 'costs.vendor'), 2,
               'costos: cada cambio queda en la auditoría');

-- 7. La IA: el presupuesto y el proveedor van juntos.
select test.login_pw('00000000-0000-0000-0000-00000000000a', 20);
select public.admin_set_vendor('ai_model', 'paid', 5, 'password');
select test.eq((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'), 5::numeric,
               'costos: el tope de IA es el presupuesto de IA');
select public.admin_set_vendor('ai_model', 'off');
select test.eq((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'), 0::numeric,
               'costos: apagar la IA deja el presupuesto en 0');

-- 8. Monitor de costos: avisa una vez.
select test.eq(public.admin_run_cost_monitors() >= 0, true, 'costos: el monitor corre');
select test.eq(public.admin_run_cost_monitors(), 0, 'costos: el monitor no repite avisos');
select test.logout();

-- Deja todo como estaba.
update public.cost_vendors set status = 'sandbox', paid_authorized = false, monthly_cap_usd = 0, authorized_by = null,
       authorized_at = null where key = 'didit_kyc';
delete from public.cost_usage where vendor_key = 'didit_kyc';
delete from public.ai_items where dedupe_key like 'cost:%';

\o
\echo 'PRUEBAS DE COSTOS OPERATIVOS PASARON'
