-- Panel del Propietario: números reales de la base, nada inventado.
--
-- owner_dashboard() es solo del propietario (is_admin). Devuelve conteos y
-- sumas calculados ahora; donde la base no tiene el dato, la clave no existe y
-- la app muestra "Sin datos". El gerente y el empleado usan ops_dashboard(),
-- que no tiene dinero.
--
-- Definiciones (para que el informe diga qué mide cada número):
--   * Hoy y este mes van en hora de Bolivia (America/La_Paz).
--   * Ingresos del mes = suma de final_amount de los trabajos completados este
--     mes (lo que pagaron los clientes al profesional; la plataforma no cobra
--     ese dinero). Comisión cobrada = suma de commission_captured de esos
--     trabajos.
--   * Saldos = suma de wallets.available y wallets.reserved.
--   * Seguridad = reportes abiertos por acoso y casos de seguridad abiertos.
--     Fraude = reportes abiertos por fraude o cobro indebido, casos de fraude
--     abiertos y alertas abiertas del agente de fraude.
--   * Brecha de cobertura = municipio con pedidos en los últimos 30 días y
--     ningún profesional aprobado con ese municipio como base. Es una
--     aproximación: no cuenta a quien atiende desde otro municipio por radio.
--   * Costos = cost_usd de este mes sin las pruebas (sandbox).

create function public.owner_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today timestamptz := date_trunc('day', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
  v_month timestamptz := date_trunc('month', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
  v_30d timestamptz := now() - interval '30 days';
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    -- Pedidos
    'bookings_today', (select count(*) from public.bookings where created_at >= v_today and status <> 'draft'),
    'active_bookings', (select count(*) from public.bookings
                        where status not in ('draft', 'completed', 'cancelled')),
    'completed_today', (select count(*) from public.bookings where status = 'completed' and completed_at >= v_today),
    'cancelled_today', (select count(*) from public.bookings where status = 'cancelled' and cancelled_at >= v_today),
    'completed_month', (select count(*) from public.bookings where status = 'completed' and completed_at >= v_month),
    'cancelled_month', (select count(*) from public.bookings where status = 'cancelled' and cancelled_at >= v_month),
    -- Personas
    'users', (select count(*) from public.profiles),
    'customers', (select count(*) from public.profiles p
                  where not exists (select 1 from public.user_roles r where r.user_id = p.id and r.role = 'admin')
                    and not exists (select 1 from public.professional_profiles pp
                                    where pp.user_id = p.id and pp.status = 'approved')),
    'approved_professionals', (select count(*) from public.professional_profiles where status = 'approved'),
    'available_professionals', (select count(*) from public.professional_profiles
                                where status = 'approved' and is_available),
    'pending_applications', (select count(*) from public.professional_profiles
                             where status in ('submitted', 'under_review')),
    'pending_documents', (select count(*) from public.professional_documents d
                          join public.professional_profiles pp on pp.user_id = d.professional_id
                          where d.status = 'pending' and pp.status in ('submitted', 'under_review')),
    'flagged_documents', (select count(*) from public.professional_documents
                          where status = 'pending' and flagged_at is not null),
    'identity_in_review', (select count(*) from public.identity_checks
                           where status in ('in_review', 'in_progress', 'created', 'resubmitted')),
    'identity_sandbox_only', (select not exists (select 1 from public.identity_checks where not sandbox)),
    'identity_required', coalesce((select (value ->> 'required')::boolean from public.app_settings
                                   where key = 'identity_check'), false),
    -- Dinero (solo propietario)
    'revenue_month', (select coalesce(sum(final_amount), 0) from public.bookings
                      where status = 'completed' and completed_at >= v_month),
    'commission_month', (select coalesce(sum(commission_captured), 0) from public.bookings
                         where status = 'completed' and completed_at >= v_month),
    'wallet_available', (select coalesce(sum(available), 0) from public.wallets),
    'wallet_reserved', (select coalesce(sum(reserved), 0) from public.wallets),
    'pending_topups', (select count(*) from public.topup_requests where status = 'pending'),
    'pending_topups_amount', (select coalesce(sum(amount), 0) from public.topup_requests where status = 'pending'),
    'active_commission_rules', (select count(*) from public.commission_rules where is_active),
    -- Casos
    'open_disputes', (select count(*) from public.disputes where status = 'open'),
    'open_reports', (select count(*) from public.user_reports where status in ('open', 'reviewing')),
    'open_tickets', (select count(*) from public.support_tickets where status <> 'closed'),
    'safety_incidents', (select count(*) from public.user_reports
                         where status in ('open', 'reviewing') and reason = 'acoso')
                        + (select count(*) from public.ops_cases
                           where status <> 'resolved' and category = 'safety' and kind <> 'report'),
    'fraud_alerts', (select count(*) from public.user_reports
                     where status in ('open', 'reviewing') and reason in ('fraude', 'cobro_indebido'))
                    + (select count(*) from public.ops_cases
                       where status <> 'resolved' and category = 'fraud' and kind <> 'report')
                    + (select count(*) from public.ai_items
                       where agent_key = 'fraud' and status in ('open', 'pending_approval', 'more_info')),
    'urgent_cases', (select count(*) from public.ops_cases where status <> 'resolved' and priority = 'urgent'),
    'escalated_to_owner', (select count(*) from public.ops_cases
                           where status = 'escalated' and escalated_to = 'owner'),
    'unassigned_cases', (select count(*) from public.ops_cases where status <> 'resolved' and assigned_to is null),
    -- Equipo
    'active_managers', (select count(*) from public.staff_members where role = 'manager' and status = 'active'),
    'active_employees', (select count(*) from public.staff_members where role = 'employee' and status = 'active'),
    -- Centro IA, costos, avisos y auditoría
    'ai_pending', (select count(*) from public.ai_items where status in ('open', 'pending_approval', 'more_info')),
    'ai_critical', (select count(*) from public.ai_items
                    where status in ('open', 'pending_approval', 'more_info') and severity in ('high', 'critical')),
    'costs_month_usd', (select coalesce(sum(cost_usd), 0) from public.cost_usage
                        where occurred_at >= v_month and not sandbox),
    'paid_vendors', (select count(*) from public.cost_vendors where status = 'paid'),
    'unread_notifications', (select count(*) from public.notifications
                             where user_id = auth.uid() and read_at is null),
    'audit_24h', (select count(*) from public.admin_audit_log where created_at >= now() - interval '24 hours'),
    -- Demanda de los últimos 30 días
    'demand_municipality', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'department', x.department, 'count', x.n,
                                          'professionals', x.pros) order by x.n desc, x.name)
      from (select c.name, d.name as department, count(*)::int as n,
                   (select count(*)::int from public.professional_profiles pp
                     where pp.city_id = c.id and pp.status = 'approved') as pros
            from public.bookings b
            join public.cities c on c.id = b.city_id
            join public.departments d on d.id = c.department_id
            where b.created_at >= v_30d and b.status <> 'draft'
            group by c.id, c.name, d.name
            order by count(*) desc, c.name
            limit 10) x), '[]'::jsonb),
    'demand_department', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'count', x.n) order by x.n desc, x.name)
      from (select d.name, count(*)::int as n
            from public.bookings b
            join public.cities c on c.id = b.city_id
            join public.departments d on d.id = c.department_id
            where b.created_at >= v_30d and b.status <> 'draft'
            group by d.name) x), '[]'::jsonb),
    'demand_category', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'count', x.n) order by x.n desc, x.name)
      from (select sc.name, count(*)::int as n
            from public.bookings b
            join public.service_categories sc on sc.id = b.category_id
            where b.created_at >= v_30d and b.status <> 'draft'
            group by sc.name
            order by count(*) desc, sc.name
            limit 10) x), '[]'::jsonb),
    'coverage_gaps', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'department', x.department, 'count', x.n)
                       order by x.n desc, x.name)
      from (select c.name, d.name as department, count(*)::int as n
            from public.bookings b
            join public.cities c on c.id = b.city_id
            join public.departments d on d.id = c.department_id
            where b.created_at >= v_30d and b.status <> 'draft'
              and not exists (select 1 from public.professional_profiles pp
                              where pp.city_id = c.id and pp.status = 'approved')
            group by c.id, c.name, d.name
            order by count(*) desc, c.name
            limit 10) x), '[]'::jsonb)
  );
end $$;

revoke execute on function public.owner_dashboard() from public, anon;
grant execute on function public.owner_dashboard() to authenticated;
