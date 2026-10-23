-- HandiMan ¡Ya! — 0040 Centro de Control IA en español y sin texto repetido.
--
-- - Reporte diario: prioridades y "lo que no se mide" en español; guarda el
--   periodo que cubre (desde/hasta), la hora en que se tomó el estado actual y
--   el nombre de la zona horaria ("Hora de Miami"). Los reportes ya guardados
--   no se tocan; la app los muestra con su fecha y avisa si son viejos.
-- - Alertas de costos: el título ya no repite el mensaje. Título corto (servicio
--   y qué pasó); el detalle va en el cuerpo y en la evidencia, con el número de
--   intentos frenados tomado de cost_usage.

create or replace function public.generate_daily_report(p_date date, p_tz text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from timestamptz := (p_date::timestamp) at time zone p_tz;
  v_to timestamptz := ((p_date + 1)::timestamp) at time zone p_tz;
  v_today jsonb := public.hmy_day_metrics(v_from, v_to);
  v_prev jsonb := public.hmy_day_metrics(v_from - interval '1 day', v_from);
  v_now jsonb;
  v_priorities jsonb;
  v_data jsonb;
begin
  -- Estado actual (no del día): pendientes y totales.
  v_now := jsonb_build_object(
    'bookings_pending', (select count(*) from public.bookings
                         where status in ('requested', 'awaiting_response', 'quote_sent', 'awaiting_confirmation')),
    'bookings_in_progress', (select count(*) from public.bookings where status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished')),
    'disputes_open', (select count(*) from public.disputes where status = 'open'),
    'verifications_pending', (select count(*) from public.professional_profiles where status in ('submitted', 'under_review')),
    'recharges_pending', (select count(*) from public.topup_requests where status = 'pending'),
    'recharges_pending_bs', (select coalesce(sum(amount), 0) from public.topup_requests where status = 'pending'),
    'complaints_open', (select count(*) from public.user_reports where status in ('open', 'reviewing'))
                       + (select count(*) from public.support_tickets where status <> 'closed'),
    'active_professionals_by_city', (select coalesce(jsonb_object_agg(city, n), '{}'::jsonb) from (
        select c.name as city, count(*) as n from public.professional_profiles p join public.cities c on c.id = p.city_id
        where p.status = 'approved' group by c.name) x),
    'available_now_by_city', (select coalesce(jsonb_object_agg(city, n), '{}'::jsonb) from (
        select c.name as city, count(*) as n from public.professional_profiles p join public.cities c on c.id = p.city_id
        where p.status = 'approved' and p.is_available group by c.name) x),
    'alerts_open', (select count(*) from public.ai_items where status in ('open', 'more_info') and kind = 'alert'),
    'alerts_critical', (select count(*) from public.ai_items where status in ('open', 'more_info') and severity = 'critical'),
    'security_alerts_open', (select count(*) from public.ai_items where status in ('open', 'more_info')
                               and agent_key in ('fraud', 'wallet', 'service_safety') and severity in ('high', 'critical')),
    'quality_alerts_open', (select count(*) from public.ai_items where status in ('open', 'more_info') and agent_key = 'quality'),
    'decisions_pending', (select count(*) from public.ai_items where status = 'pending_approval'),
    'agent_runs_ok', (select count(*) from public.ai_agent_runs where status = 'ok' and started_at >= v_from and started_at < v_to),
    'agent_runs_failed', (select count(*) from public.ai_agent_runs where status = 'failed' and started_at >= v_from and started_at < v_to),
    'ai_cost_usd', (select coalesce(sum(cost_usd), 0) from public.ai_agent_runs where started_at >= v_from and started_at < v_to),
    'database_size_mb', round(pg_database_size(current_database()) / 1048576.0, 1)
  );

  -- Cinco prioridades por reglas fijas (no por IA), de más a menos urgente.
  select coalesce(jsonb_agg(p order by ord), '[]'::jsonb) into v_priorities from (
    select ord, p from (values
      (1, case when (v_now ->> 'alerts_critical')::int > 0 then
          format('Resolver %s alerta(s) crítica(s) en el Centro de Control IA.', v_now ->> 'alerts_critical') end),
      (2, case when (v_now ->> 'security_alerts_open')::int > 0 then
          format('Revisar %s alerta(s) abierta(s) de seguridad o fraude.', v_now ->> 'security_alerts_open') end),
      (3, case when (v_now ->> 'disputes_open')::int > 0 then format('Resolver %s disputa(s) abierta(s).', v_now ->> 'disputes_open') end),
      (4, case when (v_now ->> 'recharges_pending')::int > 0 then
          format('Verificar %s recarga(s) pendiente(s) (Bs %s).', v_now ->> 'recharges_pending', v_now ->> 'recharges_pending_bs') end),
      (5, case when (v_now ->> 'verifications_pending')::int > 0 then
          format('Revisar %s postulación(es) de profesionales.', v_now ->> 'verifications_pending') end),
      (6, case when (v_now ->> 'decisions_pending')::int > 0 then
          format('Decidir %s pedido(s) que esperan tu aprobación.', v_now ->> 'decisions_pending') end),
      (7, case when (v_now ->> 'complaints_open')::int > 0 then
          format('Responder %s reclamo(s) o consulta(s) abierta(s).', v_now ->> 'complaints_open') end),
      (8, case when (v_now ->> 'bookings_pending')::int > 0 then
          format('Dar seguimiento a %s pedido(s) que esperan respuesta.', v_now ->> 'bookings_pending') end)
    ) as t(ord, p) where p is not null order by ord limit 5
  ) x;

  v_data := jsonb_build_object(
    'date', p_date, 'timezone', p_tz,
    -- Periodo que cubre el reporte (un día completo en la hora del reporte) y
    -- cuándo se tomó el "estado actual".
    'period_from', v_from, 'period_to', v_to, 'snapshot_at', now(),
    'timezone_label', case p_tz when 'America/New_York' then 'Hora de Miami'
                                when 'America/La_Paz' then 'Hora de Bolivia' else p_tz end,
    'today', v_today, 'previous_day', v_prev, 'current', v_now,
    'priorities', v_priorities,
    -- Lo que todavía no se mide: se dice, no se inventa.
    'unavailable', jsonb_build_array(
      'Gastos operativos: todavía no se registran',
      'Puntualidad: se mide con el código de llegada, pero aún no sale en este reporte',
      'Cierres inesperados de la app: el reporte de fallas no está configurado',
      'Disponibilidad de Supabase y errores de la API: el monitoreo no está conectado')
  );
  insert into public.daily_reports (report_date, timezone, data) values (p_date, p_tz, v_data)
  on conflict (report_date) do update set timezone = excluded.timezone, data = excluded.data, generated_at = now();
  return v_data;
end $$;

create or replace function public.run_cost_monitors()
returns int
language plpgsql security definer set search_path = public as $$
declare
  a jsonb;
  v_after bigint := (select coalesce(max(id), 0) from public.ai_items);
  v_t timestamptz := clock_timestamp();
  v_month text := to_char(public.hmy_month_start(), 'YYYY-MM');
begin
  begin
    for a in select * from jsonb_array_elements(public.hmy_cost_month((now() at time zone 'UTC')::date) -> 'alerts') loop
      perform public.hmy_raise_item('finance', 'alert',
        case a ->> 'level' when 'blocked' then 'high' when 'near_cap' then 'high' else 'medium' end, 'rule',
        'Costos: ' || coalesce((select name from public.cost_vendors where key = a ->> 'vendor'), a ->> 'vendor')
          || ' · ' || case a ->> 'level' when 'blocked' then 'usos frenados'
                                         when 'near_cap' then 'cerca del tope mensual'
                                         when 'near_free_limit' then 'cerca del límite gratis'
                                         else 'aviso' end,
        a ->> 'message',
        -- Evidencia con los números reales del mes, contados en cost_usage.
        a || jsonb_build_object(
          'blocked_attempts', (select count(*) from public.cost_usage u
                               where u.vendor_key = a ->> 'vendor' and not u.allowed and not u.sandbox
                                 and u.reason in ('free_tier_exhausted', 'monthly_cap', 'vendor_off')
                                 and u.occurred_at >= public.hmy_month_start()),
          'charged_usd', (select coalesce(round(sum(u.cost_usd), 4), 0) from public.cost_usage u
                          where u.vendor_key = a ->> 'vendor' and u.allowed and not u.sandbox
                            and u.occurred_at >= public.hmy_month_start()),
          'counted_at', now()),
        format('cost:%s:%s:%s', a ->> 'vendor', a ->> 'level', v_month), 'cost_vendors', a ->> 'vendor');
    end loop;
    return public.hmy_agent_run_ok('finance', v_t, v_after, 1);
  exception when others then
    perform public.hmy_log_agent_run('finance', v_t, 'failed', 'La revisión falló', sqlstate);
    return 0;
  end;
end $$;
