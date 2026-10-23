-- PLAN DE REVERSIÓN (no se aplica solo). Deshace las migraciones del 23 de
-- octubre de 2026 (0038 a 0040) en el proyecto de DESARROLLO, en una sola
-- transacción. Generado comparando una base con las migraciones hasta 0037 y
-- otra con 0038 a 0040. supabase/tests/check_rollback_20261023.sh lo prueba
-- en una base local: aplica todo, corre este script y compara el esquema y los
-- datos con los de 0037.
--
-- Qué se pierde al revertir (no existía antes de 0038):
--   - las cuentas de cobro (receiving_accounts) y sus QR registrados (los
--     archivos del bucket payment-qr no se borran);
--   - el estado bancario de las recargas (bank_status, bank_reference,
--     bank_account_id, bank_checked_by, bank_checked_at).
-- Lo que NO se deshace a propósito:
--   - las filas de admin_audit_log, security_confirmations y ai_items escritas
--     mientras tanto (son historial).
-- Ninguna tabla que existía antes pierde filas.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_20261023.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if to_regclass('public.receiving_accounts') is null or to_regprocedure('public.owner_staff_candidates(text)') is null then
    raise exception 'HMY: 0038 a 0040 no están aplicadas; no se revirtió nada.';
  end if;
end $$;

-- Funciones nuevas de 0038 a 0040 (incluye las versiones nuevas de owner_grant_staff y owner_set_staff_status)
drop function if exists hmy_mask_account(text) cascade;
drop function if exists hmy_mask_phone(text) cascade;
drop function if exists hmy_require_strong_confirmation(text,text) cascade;
drop function if exists owner_finance_audit(integer) cascade;
drop function if exists owner_finance_summary(date) cascade;
drop function if exists owner_finance_transactions(text,bigint,integer) cascade;
drop function if exists owner_grant_staff(uuid,text,text) cascade;
drop function if exists owner_receiving_accounts() cascade;
drop function if exists owner_reconcile_topup(bigint,text,text,integer,text) cascade;
drop function if exists owner_save_receiving_account(integer,text,text,text,text,text,text,text,text,text) cascade;
drop function if exists owner_set_receiving_account(integer,boolean,text,text) cascade;
drop function if exists owner_set_staff_status(uuid,text,text,text) cascade;
drop function if exists owner_staff_candidates(text) cascade;
drop function if exists owner_topups_reconciliation(text) cascade;

-- Funciones que 0038 a 0040 reemplazaron o quitaron: vuelve la versión de 0037, con sus permisos.
CREATE OR REPLACE FUNCTION public.generate_daily_report(p_date date, p_tz text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
          format('Resolve %s critical alert(s) in Centro de Control IA.', v_now ->> 'alerts_critical') end),
      (2, case when (v_now ->> 'security_alerts_open')::int > 0 then
          format('Review %s open security or fraud alert(s).', v_now ->> 'security_alerts_open') end),
      (3, case when (v_now ->> 'disputes_open')::int > 0 then format('Resolve %s open dispute(s).', v_now ->> 'disputes_open') end),
      (4, case when (v_now ->> 'recharges_pending')::int > 0 then
          format('Verify %s pending recharge(s) (Bs %s).', v_now ->> 'recharges_pending', v_now ->> 'recharges_pending_bs') end),
      (5, case when (v_now ->> 'verifications_pending')::int > 0 then
          format('Review %s professional application(s).', v_now ->> 'verifications_pending') end),
      (6, case when (v_now ->> 'decisions_pending')::int > 0 then
          format('Decide %s item(s) waiting for your approval.', v_now ->> 'decisions_pending') end),
      (7, case when (v_now ->> 'complaints_open')::int > 0 then
          format('Answer %s open complaint(s) or ticket(s).', v_now ->> 'complaints_open') end),
      (8, case when (v_now ->> 'bookings_pending')::int > 0 then
          format('Follow up %s booking(s) still waiting for a response.', v_now ->> 'bookings_pending') end)
    ) as t(ord, p) where p is not null order by ord limit 5
  ) x;

  v_data := jsonb_build_object(
    'date', p_date, 'timezone', p_tz, 'today', v_today, 'previous_day', v_prev, 'current', v_now,
    'priorities', v_priorities,
    -- Lo que todavía no se mide: se dice, no se inventa.
    'unavailable', jsonb_build_array(
      'Operating expenses (not recorded yet)',
      'Punctuality (measured with the arrival code, not in this report yet)',
      'App crashes (crash reporting not set up yet)',
      'Supabase uptime and API errors (monitoring not connected yet)')
  );
  insert into public.daily_reports (report_date, timezone, data) values (p_date, p_tz, v_data)
  on conflict (report_date) do update set timezone = excluded.timezone, data = excluded.data, generated_at = now();
  return v_data;
end $function$;
revoke all on function generate_daily_report(date,text) from public, anon, authenticated, service_role;
grant execute on function generate_daily_report(date,text) to service_role;
CREATE OR REPLACE FUNCTION public.ops_staff_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.hmy_can('staff.view') then raise exception 'HMY_FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', s.user_id, 'full_name', p.full_name, 'role', s.role, 'status', s.status,
      'status_reason', s.status_reason, 'granted_at', s.granted_at,
      'open_cases', (select count(*) from public.ops_cases c where c.assigned_to = s.user_id and c.status <> 'resolved'),
      'resolved_7d', (select count(*) from public.ops_cases c where c.assigned_to = s.user_id and c.status = 'resolved'
                        and c.resolved_at > now() - interval '7 days'),
      'avg_first_response_min', (select round(avg(extract(epoch from (c.first_response_at
                                                   - coalesce(c.assigned_at, c.created_at))) / 60))
                                 from public.ops_cases c where c.assigned_to = s.user_id
                                   and c.first_response_at is not null
                                   and c.created_at > now() - interval '30 days'))
      order by s.status, s.role, p.full_name)
    from public.staff_members s join public.profiles p on p.id = s.user_id), '[]'::jsonb);
end $function$;
revoke all on function ops_staff_overview() from public, anon, authenticated, service_role;
grant execute on function ops_staff_overview() to authenticated;
grant execute on function ops_staff_overview() to service_role;
CREATE OR REPLACE FUNCTION public.run_cost_monitors()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'Costos: ' || left(a ->> 'message', 180), a ->> 'message', a,
        format('cost:%s:%s:%s', a ->> 'vendor', a ->> 'level', v_month), 'cost_vendors', a ->> 'vendor');
    end loop;
    return public.hmy_agent_run_ok('finance', v_t, v_after, 1);
  exception when others then
    perform public.hmy_log_agent_run('finance', v_t, 'failed', 'La revisión falló', sqlstate);
    return 0;
  end;
end $function$;
revoke all on function run_cost_monitors() from public, anon, authenticated, service_role;
grant execute on function run_cost_monitors() to service_role;
CREATE OR REPLACE FUNCTION public.owner_grant_staff(p_user uuid, p_role text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_role not in ('manager', 'employee') then raise exception 'HMY_INVALID_ROLE'; end if;
  if p_user is null or p_user = auth.uid() or public.has_role('admin', p_user) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                 where u.id = p_user and u.phone_confirmed_at is not null and p.suspended_at is null) then
    raise exception 'HMY_STAFF_ACCOUNT_REQUIRED';
  end if;
  insert into public.staff_members (user_id, role, status, granted_by)
  values (p_user, p_role, 'active', auth.uid())
  on conflict (user_id) do update
    set role = excluded.role, status = 'active', status_reason = null, granted_by = auth.uid(), updated_at = now();
  perform public.audit('staff.grant', 'staff_members', p_user::text, jsonb_build_object('role', p_role));
end $function$;
revoke all on function owner_grant_staff(uuid,text) from public, anon, authenticated, service_role;
grant execute on function owner_grant_staff(uuid,text) to authenticated;
grant execute on function owner_grant_staff(uuid,text) to service_role;
CREATE OR REPLACE FUNCTION public.owner_set_staff_status(p_user uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_released int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('active', 'suspended', 'revoked') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status <> 'active' and coalesce(btrim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.staff_members set status = p_status, status_reason = nullif(btrim(p_reason), ''), updated_at = now()
  where user_id = p_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  v_released := 0;
  if p_status <> 'active' then
    update public.ops_cases set assigned_to = null, assigned_by = auth.uid(), assigned_at = now(), updated_at = now()
    where assigned_to = p_user and status <> 'resolved';
    get diagnostics v_released = row_count;
  end if;
  perform public.audit('staff.' || p_status, 'staff_members', p_user::text,
                       jsonb_strip_nulls(jsonb_build_object('reason', nullif(btrim(p_reason), ''),
                                                            'released_cases', nullif(v_released, 0))));
end $function$;
revoke all on function owner_set_staff_status(uuid,text,text) from public, anon, authenticated, service_role;
grant execute on function owner_set_staff_status(uuid,text,text) to authenticated;
grant execute on function owner_set_staff_status(uuid,text,text) to service_role;

-- 0038: estado bancario de las recargas y cuentas de cobro
alter table public.topup_requests drop column bank_status, drop column bank_reference, drop column bank_account_id,
  drop column bank_checked_by, drop column bank_checked_at;
drop table public.receiving_accounts;

-- Anotación de migraciones de la CLI de Supabase
do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations
    where version in ('20261023003800', '20261023003900', '20261023004000');
  end if;
end $$;

commit;
\echo 'Reversión de 0038 a 0040 terminada.'
