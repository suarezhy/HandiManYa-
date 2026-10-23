-- PLAN DE REVERSIÓN (no se aplica solo). Deshace las migraciones del 22 de
-- octubre de 2026 (0034 a 0037) en el proyecto de DESARROLLO, en una sola
-- transacción. Generado comparando una base con las migraciones hasta 0033 y
-- otra con 0034 a 0037. supabase/tests/check_rollback_20261022.sh lo prueba
-- en una base local: aplica todo, corre este script y compara el esquema y los
-- datos con los de 0033.
--
-- Qué se pierde al revertir (no existía antes de 0034):
--   - los roles de Gerente y Empleado (staff_members), los casos del equipo y
--     sus notas (ops_cases, ops_case_notes);
--   - las marcas de documentos (flagged_at, flagged_by, flag_note);
--   - el horario de los agentes (schedule, max_gap_minutes).
-- Lo que NO se deshace a propósito:
--   - la quita de TRUNCATE sobre admin_audit_log para anon y authenticated
--     (devolverla abriría una forma de vaciar la auditoría);
--   - las filas de ai_agent_runs y de admin_audit_log escritas mientras tanto
--     (son historial);
--   - last_run_at de los agentes queda con el valor real del historial.
-- Ninguna tabla que existía antes pierde filas.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_20261022.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if to_regclass('public.staff_members') is null or to_regprocedure('public.owner_dashboard()') is null then
    raise exception 'HMY: 0034 a 0037 no están aplicadas; no se revirtió nada.';
  end if;
end $$;

-- 0035: disparadores, política de archivos y tablas del equipo
drop trigger if exists support_tickets_case on public.support_tickets;
drop trigger if exists user_reports_case on public.user_reports;
drop trigger if exists disputes_case on public.disputes;
drop trigger if exists professional_profiles_case on public.professional_profiles;
drop policy if exists "hmy documents manager read" on storage.objects;

-- Funciones nuevas de 0034 a 0037
drop function if exists admin_ai_agents() cascade;
drop function if exists admin_ai_item_detail(bigint) cascade;
drop function if exists admin_run_all_checks() cascade;
drop function if exists hmy_agent_run_ok(text,timestamp with time zone,bigint,integer) cascade;
drop function if exists hmy_can(text) cascade;
drop function if exists hmy_can_see_case(bigint) cascade;
drop function if exists hmy_case_for_action(bigint,text,text) cascade;
drop function if exists hmy_case_json(ops_cases) cascade;
drop function if exists hmy_case_source(ops_cases) cascade;
drop function if exists hmy_log_agent_run(text,timestamp with time zone,text,text,text) cascade;
drop function if exists hmy_open_case() cascade;
drop function if exists hmy_report_category(text) cascade;
drop function if exists hmy_role_permissions(text) cascade;
drop function if exists hmy_staff_role(uuid) cascade;
drop function if exists my_staff_role() cascade;
drop function if exists ops_add_note(bigint,text) cascade;
drop function if exists ops_application_basic(uuid) cascade;
drop function if exists ops_assign_case(bigint,uuid) cascade;
drop function if exists ops_case_detail(bigint) cascade;
drop function if exists ops_cases_list(text,boolean) cascade;
drop function if exists ops_dashboard() cascade;
drop function if exists ops_escalate(bigint,text,text) cascade;
drop function if exists ops_flag_document(bigint,text) cascade;
drop function if exists ops_my_activity(integer) cascade;
drop function if exists ops_reply(bigint,text) cascade;
drop function if exists ops_set_case_status(bigint,text,text) cascade;
drop function if exists ops_staff_overview() cascade;
drop function if exists owner_dashboard() cascade;
drop function if exists owner_grant_staff(uuid,text) cascade;
drop function if exists owner_set_staff_status(uuid,text,text) cascade;
drop function if exists remove_my_email() cascade;

-- Funciones que 0034 a 0037 reemplazaron: vuelve la versión que estaba en dev (hasta 0033), con sus permisos.
CREATE OR REPLACE FUNCTION public.admin_ai_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'pending_approval', (select count(*) from public.ai_items where status = 'pending_approval'),
    'open', (select count(*) from public.ai_items where status in ('open', 'more_info')),
    'critical', (select count(*) from public.ai_items where status in ('open', 'more_info', 'pending_approval') and severity = 'critical'),
    'high', (select count(*) from public.ai_items where status in ('open', 'more_info', 'pending_approval') and severity = 'high'),
    'completed_7d', (select count(*) from public.ai_items where status = 'completed' and completed_at > now() - interval '7 days'),
    'failed_7d', (select count(*) from public.ai_items where status = 'failed' and updated_at > now() - interval '7 days'),
    'ai_recommendations_open', (select count(*) from public.ai_items where source = 'ai' and status in ('open', 'more_info')),
    'ai_cost_month_usd', (select coalesce(sum(cost_usd), 0) from public.ai_agent_runs where started_at >= date_trunc('month', now())),
    'ai_budget_month_usd', (select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'),
    'last_report_date', (select max(report_date) from public.daily_reports),
    'last_monitor_run', (select max(started_at) from public.ai_agent_runs where agent_key = 'boss' and status = 'ok')
  );
end $function$;
revoke all on function admin_ai_overview() from public, anon, authenticated, service_role;
grant execute on function admin_ai_overview() to authenticated;
grant execute on function admin_ai_overview() to service_role;
CREATE OR REPLACE FUNCTION public.admin_application_detail(p_professional uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select jsonb_build_object(
    'user_id', pp.user_id, 'display_name', pp.display_name, 'full_name', p.full_name, 'phone', p.phone,
    'email', u.email, 'city_name', c.name, 'category_name', sc.name, 'bio', pp.bio,
    'years_experience', pp.years_experience, 'status', pp.status, 'submitted_at', pp.submitted_at,
    'review_note', pp.review_note, 'suspended_at', p.suspended_at,
    'zones', coalesce((select jsonb_agg(z.name order by z.name) from public.professional_zones pz
                       join public.service_zones z on z.id = pz.zone_id where pz.professional_id = pp.user_id), '[]'),
    'categories', coalesce((select jsonb_agg(s2.name order by s2.name) from public.professional_services ps
                            join public.service_categories s2 on s2.id = ps.category_id
                            where ps.professional_id = pp.user_id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type,
                             'storage_path', d.storage_path, 'status', d.status, 'review_note', d.review_note,
                             'uploaded_at', d.uploaded_at) order by d.uploaded_at)
                           from public.professional_documents d where d.professional_id = pp.user_id), '[]'),
    'identity_checks', coalesce((select jsonb_agg(jsonb_build_object('id', ic.id, 'status', ic.status,
                                   'sandbox', ic.sandbox, 'document_type', ic.document_type,
                                   'id_document_status', ic.id_document_status, 'liveness_score', ic.liveness_score,
                                   'face_match_score', ic.face_match_score, 'warnings', to_jsonb(ic.warnings),
                                   'created_at', ic.created_at, 'decided_at', ic.decided_at,
                                   'vendor_deleted', ic.vendor_deleted_at is not null) order by ic.created_at desc)
                                 from public.identity_checks ic where ic.professional_id = pp.user_id), '[]'),
    'identity_check_required', coalesce((select (value ->> 'required')::boolean from public.app_settings
                                         where key = 'identity_check'), false),
    'history', coalesce((select jsonb_agg(jsonb_build_object('to_status', e.to_status, 'note', e.note,
                           'created_at', e.created_at) order by e.created_at desc)
                         from public.verification_events e where e.professional_id = pp.user_id), '[]')
  ) into v
  from public.professional_profiles pp
  join public.profiles p on p.id = pp.user_id
  left join auth.users u on u.id = pp.user_id
  left join public.cities c on c.id = pp.city_id
  left join public.service_categories sc on sc.id = pp.primary_category_id
  where pp.user_id = p_professional;
  if v is null then raise exception 'HMY_NOT_FOUND'; end if;
  return v;
end $function$;
revoke all on function admin_application_detail(uuid) from public, anon, authenticated, service_role;
grant execute on function admin_application_detail(uuid) to authenticated;
grant execute on function admin_application_detail(uuid) to service_role;
CREATE OR REPLACE FUNCTION public.admin_applications(p_status text DEFAULT 'pending'::text)
 RETURNS TABLE(user_id uuid, display_name text, full_name text, phone text, email text, city_name text, category_name text, status verification_status, submitted_at timestamp with time zone, documents integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select pp.user_id, pp.display_name, p.full_name, p.phone, u.email::text, c.name, sc.name, pp.status, pp.submitted_at,
         (select count(*)::int from public.professional_documents d where d.professional_id = pp.user_id)
  from public.professional_profiles pp
  join public.profiles p on p.id = pp.user_id
  left join auth.users u on u.id = pp.user_id
  left join public.cities c on c.id = pp.city_id
  left join public.service_categories sc on sc.id = pp.primary_category_id
  where case p_status
          when 'pending' then pp.status in ('submitted', 'under_review')
          when 'all' then true
          else pp.status::text = p_status
        end
  order by pp.submitted_at asc nulls last
  limit 200;
end $function$;
revoke all on function admin_applications(text) from public, anon, authenticated, service_role;
grant execute on function admin_applications(text) to authenticated;
grant execute on function admin_applications(text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_decide_ai_item(p_item bigint, p_decision text, p_note text DEFAULT NULL::text, p_auth_method text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i public.ai_items;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into i from public.ai_items where id = p_item for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if i.status in ('approved', 'rejected', 'completed', 'failed', 'dismissed') and p_decision not in ('completed', 'failed') then
    raise exception 'HMY_ALREADY_REVIEWED';
  end if;
  if p_decision = 'approve' then
    if i.status <> 'pending_approval' then raise exception 'HMY_INVALID_STATUS'; end if;
    perform public.hmy_require_confirmation(p_auth_method, 'ai.approve');
    update public.ai_items set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
    where id = p_item;
  elsif p_decision in ('reject', 'more_info', 'dismiss') then
    if p_decision = 'dismiss' and i.kind = 'approval_request' then raise exception 'HMY_INVALID_STATUS'; end if;
    update public.ai_items
    set status = case p_decision when 'reject' then 'rejected' when 'more_info' then 'more_info' else 'dismissed' end,
        decided_by = auth.uid(), decided_at = now(), decision_note = p_note
    where id = p_item;
  elsif p_decision in ('completed', 'failed') then
    -- Marcar el resultado de algo ya hecho a mano (o aprobado y ejecutado).
    if i.kind = 'approval_request' and i.status <> 'approved' then raise exception 'HMY_INVALID_STATUS'; end if;
    if i.status in ('completed', 'failed', 'rejected', 'dismissed') then raise exception 'HMY_ALREADY_REVIEWED'; end if;
    update public.ai_items set status = p_decision, completed_at = case when p_decision = 'completed' then now() end,
      result = jsonb_build_object('note', p_note, 'by', auth.uid())
    where id = p_item;
  else
    raise exception 'HMY_INVALID_STATUS';
  end if;
  perform public.audit('ai_item.' || p_decision, 'ai_items', p_item::text,
                       jsonb_build_object('note', p_note, 'auth_method', p_auth_method, 'title', i.title));
end $function$;
revoke all on function admin_decide_ai_item(bigint,text,text,text) from public, anon, authenticated, service_role;
grant execute on function admin_decide_ai_item(bigint,text,text,text) to authenticated;
grant execute on function admin_decide_ai_item(bigint,text,text,text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_disputes(p_status text DEFAULT 'open'::text)
 RETURNS TABLE(booking_id uuid, reason text, status text, resolution text, created_at timestamp with time zone, opened_by_name text, customer_name text, professional_name text, category_name text, booking_status booking_status)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select d.booking_id, d.reason, d.status, d.resolution, d.created_at, o.full_name, c.full_name,
         pp.display_name, sc.name, bk.status
  from public.disputes d
  join public.bookings bk on bk.id = d.booking_id
  join public.profiles o on o.id = d.opened_by
  join public.profiles c on c.id = bk.customer_id
  left join public.professional_profiles pp on pp.user_id = bk.professional_id
  left join public.service_categories sc on sc.id = bk.category_id
  where p_status = 'all' or d.status = p_status
  order by d.created_at asc
  limit 200;
end $function$;
revoke all on function admin_disputes(text) from public, anon, authenticated, service_role;
grant execute on function admin_disputes(text) to authenticated;
grant execute on function admin_disputes(text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_generate_daily_report(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text := coalesce((select value ->> 'timezone' from public.app_settings where key = 'daily_report'),
                              'America/New_York');
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.generate_daily_report(coalesce(p_date, (now() at time zone v_tz)::date - 1), v_tz);
end $function$;
revoke all on function admin_generate_daily_report(date) from public, anon, authenticated, service_role;
grant execute on function admin_generate_daily_report(date) to authenticated;
grant execute on function admin_generate_daily_report(date) to service_role;
CREATE OR REPLACE FUNCTION public.admin_reports(p_status text DEFAULT 'open'::text)
 RETURNS TABLE(id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text, booking_id uuid, reason text, details text, status text, resolution text, created_at timestamp with time zone, reports_against integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select r.id, r.reporter_id, a.full_name, r.reported_id, b.full_name, r.booking_id, r.reason, r.details,
         r.status, r.resolution, r.created_at,
         (select count(*)::int from public.user_reports x where x.reported_id = r.reported_id)
  from public.user_reports r
  join public.profiles a on a.id = r.reporter_id
  join public.profiles b on b.id = r.reported_id
  where case p_status when 'open' then r.status in ('open', 'reviewing') when 'all' then true
                      else r.status = p_status end
  order by r.created_at asc
  limit 200;
end $function$;
revoke all on function admin_reports(text) from public, anon, authenticated, service_role;
grant execute on function admin_reports(text) to authenticated;
grant execute on function admin_reports(text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_review_document(p_document bigint, p_status text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pro uuid;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('pending', 'accepted', 'rejected') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status = 'rejected' and coalesce(trim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.professional_documents set status = p_status, review_note = nullif(trim(p_note), '')
  where id = p_document returning professional_id into v_pro;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.audit('document.' || p_status, 'professional_documents', p_document::text,
                       jsonb_strip_nulls(jsonb_build_object('professional', v_pro, 'note', p_note)));
end $function$;
revoke all on function admin_review_document(bigint,text,text) from public, anon, authenticated, service_role;
grant execute on function admin_review_document(bigint,text,text) to authenticated;
grant execute on function admin_review_document(bigint,text,text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_review_report(p_report bigint, p_status text, p_resolution text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('reviewing', 'resolved', 'dismissed') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status in ('resolved', 'dismissed') and coalesce(trim(p_resolution), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  update public.user_reports
  set status = p_status, resolution = nullif(trim(p_resolution), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_report;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.audit('report.' || p_status, 'user_reports', p_report::text,
                       jsonb_strip_nulls(jsonb_build_object('resolution', p_resolution)));
end $function$;
revoke all on function admin_review_report(bigint,text,text) from public, anon, authenticated, service_role;
grant execute on function admin_review_report(bigint,text,text) to authenticated;
grant execute on function admin_review_report(bigint,text,text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_set_suspension(p_user uuid, p_suspend boolean, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pro public.verification_status;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_user = auth.uid() or public.has_role('admin', p_user) then raise exception 'HMY_FORBIDDEN'; end if;
  if p_suspend and coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.profiles
  set suspended_at = case when p_suspend then coalesce(suspended_at, now()) end,
      suspension_reason = case when p_suspend then trim(p_reason) end,
      active_role = case when p_suspend then 'customer'::public.app_role else active_role end
  where id = p_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;

  select status into v_pro from public.professional_profiles where user_id = p_user;
  if p_suspend and v_pro = 'approved' then
    perform public.review_professional_application(p_user, 'suspended', p_reason);
  elsif not p_suspend and v_pro = 'suspended' then
    perform public.review_professional_application(p_user, 'approved', 'Suspensión levantada');
  end if;

  perform public.notify(p_user, 'account',
    case when p_suspend then 'Tu cuenta fue suspendida' else 'Tu cuenta está activa otra vez' end,
    case when p_suspend then 'Motivo: ' || trim(p_reason) || '. Si crees que es un error, escríbenos desde Ayuda.'
         else 'Ya puedes volver a usar HandiMan ¡Ya!.' end, null);
  perform public.audit(case when p_suspend then 'account.suspend' else 'account.reactivate' end,
                       'profiles', p_user::text, jsonb_strip_nulls(jsonb_build_object('reason', p_reason)));
end $function$;
revoke all on function admin_set_suspension(uuid,boolean,text) from public, anon, authenticated, service_role;
grant execute on function admin_set_suspension(uuid,boolean,text) to authenticated;
grant execute on function admin_set_suspension(uuid,boolean,text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_tickets(p_status text DEFAULT 'open'::text)
 RETURNS TABLE(id bigint, user_id uuid, user_name text, booking_id uuid, subject text, body text, status text, admin_note text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select t.id, t.user_id, p.full_name, t.booking_id, t.subject, t.body, t.status, t.admin_note, t.created_at
  from public.support_tickets t join public.profiles p on p.id = t.user_id
  where case p_status when 'open' then t.status <> 'closed' when 'all' then true else t.status = p_status end
  order by t.created_at asc
  limit 200;
end $function$;
revoke all on function admin_tickets(text) from public, anon, authenticated, service_role;
grant execute on function admin_tickets(text) to authenticated;
grant execute on function admin_tickets(text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_update_ticket(p_ticket bigint, p_status text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_user uuid;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('open', 'in_progress', 'closed') then raise exception 'HMY_INVALID_STATUS'; end if;
  update public.support_tickets set status = p_status, admin_note = coalesce(nullif(trim(p_note), ''), admin_note)
  where id = p_ticket returning user_id into v_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if nullif(trim(p_note), '') is not null then
    perform public.notify(v_user, 'support', 'Respuesta de soporte', trim(p_note), null);
  end if;
  perform public.audit('ticket.' || p_status, 'support_tickets', p_ticket::text,
                       jsonb_strip_nulls(jsonb_build_object('note', p_note)));
end $function$;
revoke all on function admin_update_ticket(bigint,text,text) from public, anon, authenticated, service_role;
grant execute on function admin_update_ticket(bigint,text,text) to authenticated;
grant execute on function admin_update_ticket(bigint,text,text) to service_role;
CREATE OR REPLACE FUNCTION public.admin_users(p_query text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, full_name text, email text, phone text, city_name text, roles text[], professional_status verification_status, suspended_at timestamp with time zone, suspension_reason text, reports_against integer, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q text := '%' || public.hmy_norm(coalesce(trim(p_query), '')) || '%';
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select p.id, p.full_name, u.email::text, p.phone, c.name,
         coalesce((select array_agg(r.role::text order by r.role) from public.user_roles r where r.user_id = p.id), '{}'),
         pp.status, p.suspended_at, p.suspension_reason,
         (select count(*)::int from public.user_reports x where x.reported_id = p.id), p.created_at
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join public.cities c on c.id = p.city_id
  left join public.professional_profiles pp on pp.user_id = p.id
  where public.hmy_norm(p.full_name) like q or public.hmy_norm(coalesce(u.email::text, '')) like q
     or coalesce(p.phone, '') like q
  order by p.suspended_at desc nulls last, p.created_at desc
  limit 50;
end $function$;
revoke all on function admin_users(text) from public, anon, authenticated, service_role;
grant execute on function admin_users(text) to authenticated;
grant execute on function admin_users(text) to service_role;
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
                               and agent_key in ('fraud', 'wallet', 'sos') and severity in ('high', 'critical')),
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
      'Punctuality (arrival tracking not built yet)',
      'App crashes (crash reporting not set up yet)',
      'Supabase uptime and API errors (monitoring not connected yet)')
  );
  insert into public.daily_reports (report_date, timezone, data) values (p_date, p_tz, v_data)
  on conflict (report_date) do update set timezone = excluded.timezone, data = excluded.data, generated_at = now();
  return v_data;
end $function$;
revoke all on function generate_daily_report(date,text) from public, anon, authenticated, service_role;
grant execute on function generate_daily_report(date,text) to service_role;
CREATE OR REPLACE FUNCTION public.my_account()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'id', p.id, 'email', u.email, 'email_confirmed', u.email_confirmed_at is not null,
    'full_name', p.full_name, 'phone', p.phone, 'phone_verified', p.phone_verified_at is not null,
    'city_id', p.city_id, 'active_role', p.active_role,
    'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = p.id), '[]'::jsonb),
    'professional_status', coalesce((select status::text from public.professional_profiles where user_id = p.id), 'not_started'),
    'onboarding_completed', p.onboarding_completed_at is not null,
    'deletion_requested', p.deletion_requested_at is not null,
    'profile_complete', char_length(btrim(p.full_name)) >= 3 and p.city_id is not null and p.terms_accepted_at is not null
  )
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid()
$function$;
revoke all on function my_account() from public, anon, authenticated, service_role;
grant execute on function my_account() to authenticated;
grant execute on function my_account() to service_role;
CREATE OR REPLACE FUNCTION public.review_professional_application(p_professional uuid, p_decision verification_status, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from public.verification_status;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_decision not in ('under_review', 'approved', 'rejected', 'suspended', 'reverification_required') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  if p_decision in ('rejected', 'reverification_required') and coalesce(trim(p_note), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  select status into v_from from public.professional_profiles where user_id = p_professional for update;
  if not found then raise exception 'HMY_NO_APPLICATION'; end if;

  update public.professional_profiles
  set status = p_decision, reviewed_at = now(), reviewed_by = auth.uid(), review_note = p_note,
      is_available = case when p_decision = 'approved' then is_available else false end
  where user_id = p_professional;

  insert into public.verification_events (professional_id, from_status, to_status, actor_id, note)
  values (p_professional, v_from, p_decision, auth.uid(), p_note);

  if p_decision = 'approved' then
    insert into public.user_roles (user_id, role, granted_by)
    values (p_professional, 'professional', auth.uid())
    on conflict do nothing;
  elsif p_decision in ('rejected', 'suspended') then
    update public.profiles set active_role = 'customer'
    where id = p_professional and active_role = 'professional';
  end if;
end $function$;
revoke all on function review_professional_application(uuid,verification_status,text) from public, anon, authenticated, service_role;
grant execute on function review_professional_application(uuid,verification_status,text) to authenticated;
grant execute on function review_professional_application(uuid,verification_status,text) to service_role;
CREATE OR REPLACE FUNCTION public.run_cost_monitors()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a jsonb;
  n int := 0;
  v_month text := to_char(public.hmy_month_start(), 'YYYY-MM');
begin
  for a in select * from jsonb_array_elements(public.hmy_cost_month((now() at time zone 'UTC')::date) -> 'alerts') loop
    if public.hmy_raise_item('finance', 'alert',
         case a ->> 'level' when 'blocked' then 'high' when 'near_cap' then 'high' else 'medium' end, 'rule',
         'Costos: ' || left(a ->> 'message', 180), a ->> 'message', a,
         format('cost:%s:%s:%s', a ->> 'vendor', a ->> 'level', v_month), 'cost_vendors', a ->> 'vendor') is not null then
      n := n + 1;
    end if;
  end loop;
  update public.ai_agents set last_run_at = now(), last_run_status = 'ok' where key = 'finance';
  return n;
end $function$;
revoke all on function run_cost_monitors() from public, anon, authenticated, service_role;
grant execute on function run_cost_monitors() to service_role;
CREATE OR REPLACE FUNCTION public.run_daily_report_if_due()
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s jsonb := (select value from public.app_settings where key = 'daily_report');
  v_tz text := coalesce(s ->> 'timezone', 'America/New_York');
  v_local timestamp := now() at time zone v_tz;
  v_run bigint;
begin
  if not coalesce((s ->> 'enabled')::boolean, false) then return false; end if;
  if extract(hour from v_local) <> coalesce((s ->> 'hour')::int, 6) then return false; end if;
  if exists (select 1 from public.daily_reports where report_date = v_local::date - 1
             and generated_at > now() - interval '20 hours') then
    return false;
  end if;
  insert into public.ai_agent_runs (agent_key, status) values ('daily_report', 'running') returning id into v_run;
  begin
    perform public.generate_daily_report(v_local::date - 1, v_tz);
    update public.ai_agent_runs set status = 'ok', finished_at = now(), summary = 'Reporte del ' || (v_local::date - 1)
    where id = v_run;
  exception when others then
    update public.ai_agent_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
  end;
  update public.ai_agents set last_run_at = now(),
    last_run_status = (select status from public.ai_agent_runs where id = v_run) where key = 'daily_report';
  return true;
end $function$;
revoke all on function run_daily_report_if_due() from public, anon, authenticated, service_role;
grant execute on function run_daily_report_if_due() to service_role;
CREATE OR REPLACE FUNCTION public.run_marketplace_monitors()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_run bigint;
  v_new int := 0;
  r record;
begin
  insert into public.ai_agent_runs (agent_key, status) values ('boss', 'running') returning id into v_run;

  -- Billetera: saldo que no cuadra con el libro mayor (crítico).
  for r in
    select w.professional_id, w.available, coalesce(sum(l.available_delta), 0) as ledger_sum
    from public.wallets w left join public.wallet_ledger l on l.professional_id = w.professional_id
    group by w.professional_id, w.available
    having w.available <> coalesce(sum(l.available_delta), 0)
  loop
    if public.hmy_raise_item('wallet', 'alert', 'critical', 'rule', 'Saldo que no cuadra con el libro mayor',
         format('La billetera muestra %s Bs disponibles, pero el libro mayor suma %s Bs.', r.available, r.ledger_sum),
         jsonb_build_object('professional_id', r.professional_id, 'available', r.available, 'ledger_sum', r.ledger_sum),
         'wallet-mismatch:' || r.professional_id || ':' || r.available, 'wallets', r.professional_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Billetera: recargas pendientes hace más de 24 horas.
  for r in select id, amount, created_at from public.topup_requests
           where status = 'pending' and created_at < now() - interval '24 hours' loop
    if public.hmy_raise_item('wallet', 'alert', 'medium', 'rule', 'Recarga esperando verificación hace más de 24 horas',
         format('Recarga N.º %s de %s Bs, pedida el %s.', r.id, r.amount, to_char(r.created_at, 'YYYY-MM-DD HH24:MI')),
         jsonb_build_object('topup_id', r.id, 'amount', r.amount), 'topup-late:' || r.id, 'topup_requests', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Billetera: el mismo número de comprobante en más de una recarga.
  for r in select lower(trim(reference)) as ref, array_agg(id order by id) as ids, count(distinct professional_id) as pros
           from public.topup_requests where reference is not null and trim(reference) <> '' and status <> 'rejected'
           group by lower(trim(reference)) having count(*) > 1 loop
    if public.hmy_raise_item('wallet', 'alert', 'high', 'rule', 'Comprobante repetido en varias recargas',
         format('El comprobante "%s" aparece en las recargas %s (%s profesional(es)). Revisa antes de aprobar.',
                r.ref, array_to_string(r.ids, ', '), r.pros),
         jsonb_build_object('reference', r.ref, 'topup_ids', r.ids), 'topup-dup:' || r.ref || ':' || array_to_string(r.ids, ','),
         'topup_requests', r.ids[1]::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Asignación: pedidos ¡Ya! sin aceptar hace más de 15 minutos.
  for r in select b.id, b.code, c.name as city, sc.name as category, b.created_at
           from public.bookings b join public.cities c on c.id = b.city_id
           join public.service_categories sc on sc.id = b.category_id
           where b.mode = 'now' and b.professional_id is null and b.status in ('requested', 'awaiting_response')
             and b.created_at < now() - interval '15 minutes' loop
    if public.hmy_raise_item('dispatch', 'recommendation', 'medium', 'rule', 'Pedido ¡Ya! sin profesional',
         format('Pedido %s de %s en %s, sin aceptar desde %s. Sugerencia: ampliar el radio o avisar a más profesionales.',
                r.code, r.category, r.city, to_char(r.created_at, 'HH24:MI')),
         jsonb_build_object('booking_id', r.id), 'ya-unaccepted:' || r.id, 'bookings', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Verificación: postulaciones esperando revisión más de 48 horas.
  for r in select user_id, display_name, submitted_at from public.professional_profiles
           where status in ('submitted', 'under_review') and submitted_at < now() - interval '48 hours' loop
    if public.hmy_raise_item('background', 'alert', 'medium', 'rule', 'Postulación esperando revisión más de 48 horas',
         format('%s envió su postulación el %s.', coalesce(nullif(r.display_name, ''), 'Un profesional'),
                to_char(r.submitted_at, 'YYYY-MM-DD')),
         jsonb_build_object('professional_id', r.user_id), 'application-late:' || r.user_id || ':' || r.submitted_at::date,
         'professional_profiles', r.user_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Calidad: dos o más calificaciones de 1–2 estrellas en 30 días.
  for r in select professional_id, count(*) as n from public.reviews
           where rating <= 2 and created_at > now() - interval '30 days' group by professional_id having count(*) >= 2 loop
    if public.hmy_raise_item('quality', 'alert', 'medium', 'rule', 'Calificaciones bajas repetidas',
         format('%s calificaciones de 1 o 2 estrellas en los últimos 30 días.', r.n),
         jsonb_build_object('professional_id', r.professional_id, 'low_reviews_30d', r.n),
         'low-reviews:' || r.professional_id || ':' || r.n, 'professional_profiles', r.professional_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Fraude y seguridad: acoso o fraude reportados, o 3+ personas reportan a la misma cuenta.
  for r in select id, reported_id, reason from public.user_reports
           where status = 'open' and reason in ('acoso', 'fraude') loop
    if public.hmy_raise_item('fraud', 'alert', 'high', 'rule',
         case when r.reason = 'acoso' then 'Reporte de acoso sin revisar' else 'Reporte de fraude sin revisar' end,
         'Es una denuncia, todavía no un hecho comprobado. Revísala en Reportes.',
         jsonb_build_object('report_id', r.id, 'reported_id', r.reported_id), 'report-serious:' || r.id,
         'user_reports', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;
  for r in select reported_id, count(distinct reporter_id) as n from public.user_reports
           where created_at > now() - interval '30 days' group by reported_id having count(distinct reporter_id) >= 3 loop
    if public.hmy_raise_item('fraud', 'alert', 'high', 'rule', 'Cuenta reportada por varias personas',
         format('%s personas distintas reportaron esta cuenta en 30 días.', r.n),
         jsonb_build_object('reported_id', r.reported_id, 'reporters_30d', r.n), 'many-reports:' || r.reported_id || ':' || r.n,
         'profiles', r.reported_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Disputas abiertas más de 48 horas.
  for r in select d.id, b.code, d.created_at from public.disputes d join public.bookings b on b.id = d.booking_id
           where d.status = 'open' and d.created_at < now() - interval '48 hours' loop
    if public.hmy_raise_item('disputes', 'alert', 'high', 'rule', 'Disputa abierta hace más de 48 horas',
         format('Pedido %s, disputa abierta el %s.', r.code, to_char(r.created_at, 'YYYY-MM-DD')),
         jsonb_build_object('dispute_id', r.id), 'dispute-late:' || r.id, 'disputes', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Soporte: tickets abiertos más de 24 horas.
  for r in select id, subject from public.support_tickets where status = 'open' and created_at < now() - interval '24 hours' loop
    if public.hmy_raise_item('support', 'alert', 'medium', 'rule', 'Ticket de soporte sin respuesta hace más de 24 horas',
         r.subject, jsonb_build_object('ticket_id', r.id), 'ticket-late:' || r.id, 'support_tickets', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Privacidad: pedidos de eliminación de cuenta con más de 7 días.
  for r in select id, deletion_requested_at from public.profiles
           where deletion_requested_at is not null and deletion_requested_at < now() - interval '7 days' loop
    if public.hmy_raise_item('privacy', 'alert', 'medium', 'rule', 'Pedido de eliminación de cuenta pendiente',
         format('Pedido el %s. Hay que atenderlo y responder al usuario.', to_char(r.deletion_requested_at, 'YYYY-MM-DD')),
         jsonb_build_object('user_id', r.id), 'deletion-late:' || r.id, 'profiles', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Moderación: contenido inapropiado reportado.
  for r in select id, reported_id from public.user_reports where status = 'open' and reason = 'contenido_inapropiado' loop
    if public.hmy_raise_item('moderation', 'alert', 'medium', 'rule', 'Contenido inapropiado reportado',
         'Revisa el contenido y decide si se oculta.', jsonb_build_object('report_id', r.id, 'reported_id', r.reported_id),
         'report-content:' || r.id, 'user_reports', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Auditor de IA: ejecuciones fallidas en las últimas 24 horas.
  for r in select agent_key, count(*) as n from public.ai_agent_runs
           where status = 'failed' and started_at > now() - interval '24 hours' group by agent_key loop
    if public.hmy_raise_item('ai_auditor', 'alert', 'medium', 'rule', 'Un agente falló en las últimas 24 horas',
         format('El agente "%s" falló %s vez/veces.', r.agent_key, r.n),
         jsonb_build_object('agent_key', r.agent_key, 'failures_24h', r.n),
         'agent-failed:' || r.agent_key || ':' || current_date) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  update public.ai_agent_runs set status = 'ok', finished_at = now(),
    summary = format('%s aviso(s) nuevo(s)', v_new) where id = v_run;
  update public.ai_agents set last_run_at = now(), last_run_status = 'ok'
  where key in ('boss', 'wallet', 'dispatch', 'background', 'quality', 'fraud', 'disputes', 'support', 'privacy',
                'moderation', 'ai_auditor');
  return v_new;
end $function$;
revoke all on function run_marketplace_monitors() from public, anon, authenticated, service_role;
grant execute on function run_marketplace_monitors() to service_role;
CREATE OR REPLACE FUNCTION public.run_rule_agents()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_new int := 0;
  r record;
begin
  -- Seguridad en el servicio: "en camino" hace más de 3 horas sin llegada verificada.
  for r in
    select b.id, b.code, b.professional_id, max(e.created_at) as since
    from public.bookings b
    join public.booking_events e on e.booking_id = b.id and e.to_status = 'on_the_way'
    where b.status = 'on_the_way'
    group by b.id
    having max(e.created_at) < now() - interval '3 hours'
  loop
    if public.hmy_raise_item('service_safety', 'alert', 'high', 'rule',
         format('Pedido %s: "en camino" hace más de 3 horas sin llegada verificada', r.code),
         'Llama al cliente y al profesional para confirmar que todo está bien.',
         jsonb_build_object('booking_id', r.id, 'since', r.since), 'trip-stuck:' || r.id,
         'bookings', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Seguridad en el servicio: llegada verificada por el equipo (excepción), para revisar.
  for r in
    select a.booking_id, b.code, a.admin_reason
    from public.booking_arrivals a join public.bookings b on b.id = a.booking_id
    where a.method = 'admin' and a.verified_at > now() - interval '7 days'
  loop
    if public.hmy_raise_item('service_safety', 'alert', 'low', 'rule',
         format('Pedido %s: llegada verificada por el equipo, sin código', r.code),
         format('Motivo registrado: %s', r.admin_reason),
         jsonb_build_object('booking_id', r.booking_id), 'arrival-admin:' || r.booking_id,
         'bookings', r.booking_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Puntualidad: 3 o más llegadas con más de 15 minutos de atraso en 30 días.
  for r in
    select b.professional_id, count(*) as late, round(avg(a.delay_minutes)) as avg_delay
    from public.booking_arrivals a join public.bookings b on b.id = a.booking_id
    where a.delay_minutes > 15 and a.verified_at > now() - interval '30 days'
    group by b.professional_id
    having count(*) >= 3
  loop
    if public.hmy_raise_item('punctuality', 'alert', 'medium', 'rule', 'Atrasos repetidos',
         format('%s llegadas con más de 15 minutos de atraso en 30 días (promedio %s min).', r.late, r.avg_delay),
         jsonb_build_object('professional_id', r.professional_id, 'late', r.late),
         format('late:%s:%s', r.professional_id, to_char(now(), 'IYYY-IW')),
         'professional_profiles', r.professional_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Antecedentes y documentos: profesional aprobado sin carnet aceptado (grave).
  for r in
    select pp.user_id, pp.display_name
    from public.professional_profiles pp
    where pp.status = 'approved'
      and not exists (select 1 from public.professional_documents d
                      where d.professional_id = pp.user_id and d.doc_type = 'ci_anverso' and d.status = 'accepted')
  loop
    if public.hmy_raise_item('background', 'alert', 'high', 'rule', 'Profesional aprobado sin carnet aceptado',
         format('%s está aprobado, pero su carnet no figura como aceptado. Revisa los documentos.', r.display_name),
         jsonb_build_object('professional_id', r.user_id), 'no-ci:' || r.user_id,
         'professional_profiles', r.user_id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Antecedentes y documentos: vencidos o por vencer en 30 días.
  for r in
    select d.id, d.professional_id, d.doc_type, d.expires_on, pp.display_name
    from public.professional_documents d
    join public.professional_profiles pp on pp.user_id = d.professional_id and pp.status = 'approved'
    where d.status = 'accepted' and d.expires_on is not null and d.expires_on < current_date + 30
  loop
    if public.hmy_raise_item('background', 'alert', case when r.expires_on < current_date then 'high' else 'medium' end,
         'rule',
         format('%s: documento %s %s', r.display_name, r.doc_type,
                case when r.expires_on < current_date then 'vencido' else 'por vencer' end),
         format('Vence el %s. Pide el documento actualizado.', to_char(r.expires_on, 'DD/MM/YYYY')),
         jsonb_build_object('document_id', r.id, 'expires_on', r.expires_on),
         format('doc-expiry:%s:%s', r.id, case when r.expires_on < current_date then 'expired' else 'soon' end),
         'professional_documents', r.id::text) is not null then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Asistente para profesionales: postulación en borrador hace más de 2 días
  -- sin documentos. Se le avisa una sola vez qué falta.
  for r in
    select pp.user_id, pp.display_name, pp.primary_category_id is null as no_category
    from public.professional_profiles pp
    where pp.status = 'draft' and pp.created_at < now() - interval '2 days'
      and not exists (select 1 from public.professional_documents d where d.professional_id = pp.user_id)
  loop
    if public.hmy_raise_item('pro_assistant', 'recommendation', 'info', 'rule', 'Postulación sin documentos',
         'Se le avisó al profesional qué le falta para enviarla.',
         jsonb_build_object('professional_id', r.user_id), 'pro-missing:' || r.user_id,
         'professional_profiles', r.user_id::text) is not null then
      perform public.notify(r.user_id, 'verification', 'Te falta poco para postular',
        case when r.no_category then 'Elige tu oficio y sube tu carnet (anverso y reverso) para enviar tu postulación.'
             else 'Sube tu carnet (anverso y reverso) para enviar tu postulación.' end);
      v_new := v_new + 1;
    end if;
  end loop;

  update public.ai_agents set last_run_at = now(), last_run_status = 'ok'
  where key in ('service_safety', 'punctuality', 'background', 'pro_assistant');
  return v_new;
end $function$;
revoke all on function run_rule_agents() from public, anon, authenticated, service_role;
grant execute on function run_rule_agents() to service_role;

drop table public.ops_case_notes;
drop table public.ops_cases;
drop table public.staff_members;
alter table public.professional_documents drop column flagged_at, drop column flagged_by, drop column flag_note;

-- 0036: agentes (estado, propósito y necesidades como estaban hasta 0033)
alter table public.ai_agents drop column schedule, drop column max_gap_minutes;
delete from public.app_settings where key = 'agent_run_log';
update public.ai_agents set status = 'rules', purpose = 'Coordina a los agentes, prioriza problemas, resume y pide decisiones al dueño.', needs = NULL where key = 'boss';
update public.ai_agents set status = 'needs_setup', purpose = 'Carnet (anverso y reverso), selfie con prueba de vida y comparación facial con un proveedor especializado. Resultado preliminar; decide una persona.', needs = 'Cuenta de Didit en modo sandbox (gratis) y sus claves en Supabase. El uso real necesita autorización del dueño.' where key = 'identity';
update public.ai_agents set status = 'rules', purpose = 'Documentos vencidos o por vencer y profesionales aprobados sin carnet aceptado. Los antecedentes se revisan aparte de la verificación de identidad.', needs = 'La lectura de certificados (REJAP, antecedentes) la hace una persona; leerlos solo necesitaría IA pagada.' where key = 'background';
update public.ai_agents set status = 'needs_setup', purpose = 'Entiende el problema en español boliviano, sugiere categoría y opciones y prepara el pedido. Nunca lo envía sin el cliente.', needs = 'Necesita IA para entender texto libre: solo con presupuesto autorizado. Mientras tanto, el cliente elige la categoría.' where key = 'customer_assistant';
update public.ai_agents set status = 'rules', purpose = 'Vigila pedidos ¡Ya! sin aceptar y sugiere ampliar la búsqueda. La base sigue decidiendo quién puede aceptar.', needs = NULL where key = 'dispatch';
update public.ai_agents set status = 'rules', purpose = 'Avisa al profesional qué le falta para postular (oficio, carnet). No inventa credenciales ni precios.', needs = 'Redactar textos necesitaría IA pagada.' where key = 'pro_assistant';
update public.ai_agents set status = 'needs_setup', purpose = 'Responde preguntas con datos reales de la cuenta, crea tickets y pasa a una persona cuando hace falta.', needs = 'Necesita IA para responder texto libre: solo con presupuesto autorizado. Mientras tanto, responde una persona.' where key = 'support';
update public.ai_agents set status = 'rules', purpose = 'Vigila recargas, comprobantes repetidos, saldos que no cuadran con el libro mayor y recargas atrasadas.', needs = NULL where key = 'wallet';
update public.ai_agents set status = 'rules', purpose = 'Comisiones cobradas (ingreso real), separadas de las recargas; uso de los planes gratis, cargos proyectados y alertas de gasto. Frena cualquier gasto no autorizado.', needs = NULL where key = 'finance';
update public.ai_agents set status = 'needs_setup', purpose = 'Errores de la app, pruebas fallidas y problemas tras cada versión. Prepara correcciones solo con autorización.', needs = 'Servicio de reporte de errores (por ejemplo, Sentry).' where key = 'qa';
update public.ai_agents set status = 'rules', purpose = 'Reportes repetidos, acoso, fraude y pagos por fuera de la app. Distingue denuncias de hechos comprobados.', needs = NULL where key = 'fraud';
update public.ai_agents set status = 'planned', purpose = 'Borradores de campañas y análisis de demanda. No publica ni gasta sin aprobación.', needs = NULL where key = 'marketing';
update public.ai_agents set status = 'rules', purpose = 'Faltantes por ciudad y categoría y postulaciones incompletas.', needs = NULL where key = 'recruitment';
update public.ai_agents set status = 'rules', purpose = 'Calificaciones bajas repetidas, reclamos y su resolución.', needs = NULL where key = 'quality';
update public.ai_agents set status = 'rules', purpose = 'Requisitos de Google Play y App Store, pruebas y bloqueos de publicación.', needs = NULL where key = 'launch';
update public.ai_agents set status = 'rules', purpose = 'Atrasos repetidos según la llegada verificada con código (más de 15 minutos, 3 veces en 30 días). Solo avisa; no castiga.', needs = NULL where key = 'punctuality';
update public.ai_agents set status = 'rules', purpose = 'Reporte de las 6:00 AM (hora de Miami) solo con datos reales.', needs = NULL where key = 'daily_report';
update public.ai_agents set status = 'planned', purpose = 'Historial verificable de cada profesional, con aviso, evidencia y apelación.', needs = NULL where key = 'performance';
update public.ai_agents set status = 'rules', purpose = 'Ordena la evidencia de cada disputa, propone soluciones y vigila plazos. Decide una persona.', needs = NULL where key = 'disputes';
update public.ai_agents set status = 'planned', purpose = 'Rangos de precio reales por categoría y ciudad para orientar y detectar cobros excesivos.', needs = 'Suficientes trabajos completados.' where key = 'pricing';
update public.ai_agents set status = 'rules', purpose = 'Revisa fotos, reseñas y mensajes reportados (Apple lo exige a apps con contenido de usuarios).', needs = NULL where key = 'moderation';
update public.ai_agents set status = 'rules', purpose = 'Pedidos de eliminación de cuenta, retención de documentos y que la IA no reciba datos sensibles de más.', needs = NULL where key = 'privacy';
update public.ai_agents set status = 'planned', purpose = 'Prepara la facturación de comisiones según Impuestos Nacionales. No emite nada sin aprobación.', needs = 'Revisión con un contador y acceso al sistema de facturación.' where key = 'invoicing';
update public.ai_agents set status = 'rules', purpose = 'Vigila trabajos "en camino" por horas sin llegada verificada, llegadas verificadas por el equipo y reportes de seguridad; pasa los casos graves al equipo.', needs = 'Notificaciones push para avisar al instante.' where key = 'service_safety';
update public.ai_agents set status = 'needs_setup', purpose = 'Un solo canal para todos los avisos, con horarios, límites y sin spam.', needs = 'iPhone: Apple (APNs). Android: WhatsApp o SMS enviados desde Supabase (servicio pagado; se activa con aprobación del dueño).' where key = 'notifications';
update public.ai_agents set status = 'rules', purpose = 'Vigila a los demás agentes: costos, fallas, intentos de manipulación y que lo "completado" sea real.', needs = NULL where key = 'ai_auditor';

-- Anotación de migraciones de la CLI de Supabase
do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations
    where version in ('20261022003400', '20261022003500', '20261022003600', '20261022003700');
  end if;
end $$;

commit;
\echo 'Reversión de 0034 a 0037 terminada.'
