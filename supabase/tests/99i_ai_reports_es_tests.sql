-- Centro de Control IA en español (0040). Corre después de 99h.
\set ON_ERROR_STOP 1
\o /dev/null

-- El reporte diario: en español, con su periodo y "Hora de Miami".
create temp table r as select public.generate_daily_report('2026-10-21', 'America/New_York') as d;
select test.eq((select d ->> 'timezone_label' from r), 'Hora de Miami', 'reporte: zona horaria en palabras');
select test.eq((select (d ->> 'period_from')::timestamptz from r), '2026-10-21 00:00:00-04'::timestamptz,
               'reporte: empieza a la medianoche de Miami');
select test.eq((select (d ->> 'period_to')::timestamptz from r), '2026-10-22 00:00:00-04'::timestamptz,
               'reporte: cubre un día completo');
select test.eq((select d ? 'snapshot_at' from r), true, 'reporte: dice cuándo se tomó el estado actual');
select test.eq((select count(*)::int from r, jsonb_array_elements_text(d -> 'unavailable') u
                where u ~ '(not |yet|Operating|crash|uptime)'), 0, 'reporte: lo que no se mide, en español');
select test.eq((select count(*)::int from r, jsonb_array_elements_text(d -> 'priorities') p
                where p ~ '^(Resolve|Review|Verify|Decide|Answer|Follow) '), 0, 'reporte: prioridades en español');
select test.eq((select jsonb_array_length(d -> 'unavailable') from r), 4, 'reporte: dice lo que todavía no se mide');
-- Una prioridad real aparece en español.
insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009c10001', '59170099601', now(), '{"full_name": "Profesional Reporte"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status)
values ('00000000-0000-0000-0000-000009c10001', 'Profesional Reporte', 1, 1, 'approved');
insert into public.topup_requests (professional_id, amount, reference, status)
values ('00000000-0000-0000-0000-000009c10001', 25, 'Prueba 99i', 'pending');
select test.eq((select count(*)::int from jsonb_array_elements_text(public.generate_daily_report('2026-10-21', 'America/New_York') -> 'priorities') p
                where p like 'Verificar % recarga(s) pendiente(s)%'), 1, 'reporte: prioridad de recargas en español');

-- Alerta de costos: el título no repite el mensaje y la evidencia trae los intentos reales.
update public.cost_vendors set status = 'off' where key = 'whatsapp_otp';
-- La alerta del mes con el formato viejo (título = "Costos: " + mensaje, sin
-- números). Si en dev ya existe, se usa esa; todo termina en ROLLBACK.
insert into public.ai_items (agent_key, kind, severity, status, source, title, body, evidence, dedupe_key)
values ('finance', 'alert', 'high', 'open', 'rule', 'Costos: mensaje viejo', 'mensaje viejo', '{}',
        'cost:whatsapp_otp:blocked:' || to_char(public.hmy_month_start(), 'YYYY-MM'))
on conflict (dedupe_key) do update set status = 'open', title = 'Costos: mensaje viejo', body = 'mensaje viejo', evidence = '{}';
insert into public.cost_usage (vendor_key, units, sandbox, allowed, reason, billable_units, cost_usd, ref)
select 'whatsapp_otp', 1, false, false, 'vendor_off', 0, 0, 'prueba-99i-' || g from generate_series(1, 3) g;
select public.run_cost_monitors();
create temp table a as
  select * from public.ai_items where dedupe_key = 'cost:whatsapp_otp:blocked:' || to_char(public.hmy_month_start(), 'YYYY-MM');
select test.eq((select count(*)::int from a), 1, 'costos: una sola alerta por servicio, nivel y mes');
select test.eq((select title from a) like 'Costos: % · usos frenados', true, 'costos: título corto (también la alerta vieja)');
select test.eq((select position(body in title) from a), 0, 'costos: el título no repite el detalle');
select test.eq((select (evidence ->> 'blocked_attempts')::int >= 3 from a), true,
               'costos: los intentos frenados salen de cost_usage');
select test.eq((select (evidence ->> 'blocked_attempts')::int from a),
               (select count(*)::int from public.cost_usage where vendor_key = 'whatsapp_otp' and not allowed and not sandbox
                  and reason in ('free_tier_exhausted', 'monthly_cap', 'vendor_off')
                  and occurred_at >= public.hmy_month_start()),
               'costos: el número coincide con los registros');
select test.eq((select (evidence ->> 'charged_usd')::numeric from a),
               (select coalesce(round(sum(cost_usd), 4), 0) from public.cost_usage where vendor_key = 'whatsapp_otp'
                  and allowed and not sandbox and occurred_at >= public.hmy_month_start()),
               'costos: lo cobrado sale de los registros');
-- Más intentos frenados: la misma alerta abierta muestra el número nuevo.
insert into public.cost_usage (vendor_key, units, sandbox, allowed, reason, billable_units, cost_usd, ref)
values ('whatsapp_otp', 1, false, false, 'vendor_off', 0, 0, 'prueba-99i-4');
select public.run_cost_monitors();
select test.eq((select (evidence ->> 'blocked_attempts')::int from public.ai_items where id = (select id from a)),
               (select (evidence ->> 'blocked_attempts')::int + 1 from a), 'costos: el conteo se actualiza en cada revisión');
-- Una alerta ya decidida no se reescribe.
update public.ai_items set status = 'dismissed' where id = (select id from a);
create temp table a2 as select evidence from public.ai_items where id = (select id from a);
insert into public.cost_usage (vendor_key, units, sandbox, allowed, reason, billable_units, cost_usd, ref)
values ('whatsapp_otp', 1, false, false, 'vendor_off', 0, 0, 'prueba-99i-5');
select public.run_cost_monitors();
select test.eq((select evidence from public.ai_items where id = (select id from a)), (select evidence from a2),
               'costos: una alerta decidida queda como estaba');
