-- Cada número del panel abre la lista que lo explica (Build 13).
--
-- Las listas usan las mismas definiciones que owner_dashboard() (0037), para
-- que el número de la tarjeta y el total de la lista coincidan:
--   * ops_bookings: pedidos de hoy, activos, completados y cancelados (hora de
--     Bolivia). Propietario y gerente (bookings.monitor). Montos solo para el
--     propietario. Nunca la dirección ni el GPS: eso es del cliente y del
--     profesional.
--   * ops_booking_detail: un pedido con su historial, sus casos, reportes y
--     disputa.
--   * ops_open_booking_case: abrir un caso para revisar un pedido (queda en
--     Casos, se puede asignar y escalar; auditado).
--   * ops_cases_list: suma 'urgent' y 'escalated_owner'.
--   * ops_dashboard (gerente): pedidos con las mismas definiciones.
--   * admin_people: clientes, profesionales aprobados, disponibles, identidad
--     en revisión y suspendidos (users.view).
--   * ops_risk_items: incidentes de seguridad y alertas de fraude, de sus tres
--     fuentes (reportes, casos y, solo para el propietario, el Centro IA).
--   * owner_wallets: billeteras de los profesionales (solo propietario).
--     Los saldos son de los profesionales, no ingresos de la plataforma.
-- Todas devuelven {"items": [...], "total": n}: total es el conteo completo
-- aunque la lista muestre solo los primeros.

-- ---------------------------------------------------------------------------
-- Casos para revisar un pedido
-- ---------------------------------------------------------------------------
alter table public.ops_cases drop constraint ops_cases_kind_check;
alter table public.ops_cases add constraint ops_cases_kind_check
  check (kind in ('support', 'application', 'dispute', 'report', 'booking'));

create or replace function public.hmy_case_source(c public.ops_cases) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if c.kind = 'support' then
    select jsonb_build_object('user_name', p.full_name, 'subject', t.subject, 'body', t.body, 'status', t.status,
                              'last_reply', t.admin_note, 'booking_id', t.booking_id)
    into v from public.support_tickets t join public.profiles p on p.id = t.user_id where t.id = c.ref_id::bigint;
  elsif c.kind = 'report' then
    select jsonb_build_object('reporter_name', a.full_name, 'reported_name', b.full_name, 'reason', r.reason,
                              'details', r.details, 'status', r.status, 'booking_id', r.booking_id)
    into v from public.user_reports r join public.profiles a on a.id = r.reporter_id
    join public.profiles b on b.id = r.reported_id where r.id = c.ref_id::bigint;
  elsif c.kind = 'dispute' then
    select jsonb_build_object('reason', d.reason, 'status', d.status, 'opened_by_name', o.full_name,
                              'customer_name', cu.full_name, 'professional_name', pp.display_name,
                              'category_name', sc.name, 'booking_status', bk.status)
    into v from public.disputes d join public.bookings bk on bk.id = d.booking_id
    join public.profiles o on o.id = d.opened_by join public.profiles cu on cu.id = bk.customer_id
    left join public.professional_profiles pp on pp.user_id = bk.professional_id
    left join public.service_categories sc on sc.id = bk.category_id
    where d.booking_id = c.ref_id::uuid;
  elsif c.kind = 'application' then
    select jsonb_build_object('professional_id', pp.user_id, 'display_name', pp.display_name,
                              'city_name', ci.name, 'category_name', sc.name, 'status', pp.status,
                              'submitted_at', pp.submitted_at, 'years_experience', pp.years_experience,
                              'documents', coalesce((select jsonb_agg(jsonb_build_object(
                                  'id', d.id, 'doc_type', d.doc_type, 'status', d.status,
                                  'flagged', d.flagged_at is not null, 'flag_note', d.flag_note) order by d.uploaded_at)
                                from public.professional_documents d where d.professional_id = pp.user_id), '[]'))
    into v from public.professional_profiles pp
    left join public.cities ci on ci.id = pp.city_id
    left join public.service_categories sc on sc.id = pp.primary_category_id
    where pp.user_id = c.ref_id::uuid;
  elsif c.kind = 'booking' then
    -- Sin montos, sin dirección y sin teléfonos: lo necesario para revisar.
    select jsonb_build_object('booking_id', bk.id, 'code', bk.code, 'booking_status', bk.status,
                              'mode', bk.mode, 'customer_name', cu.full_name, 'professional_name', pp.display_name,
                              'category_name', sc.name, 'city_name', ci.name, 'created_at', bk.created_at)
    into v from public.bookings bk join public.profiles cu on cu.id = bk.customer_id
    left join public.professional_profiles pp on pp.user_id = bk.professional_id
    left join public.service_categories sc on sc.id = bk.category_id
    left join public.cities ci on ci.id = bk.city_id
    where bk.id = c.ref_id::uuid;
  end if;
  return coalesce(v, '{}'::jsonb);
end $$;

-- p_scope: 'mine', 'unassigned', 'escalated', 'escalated_owner', 'urgent' o
-- 'all'. El empleado siempre recibe solo los suyos, pida lo que pida.
create or replace function public.ops_cases_list(p_scope text default 'mine', p_include_resolved boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_all boolean := public.hmy_can('cases.view_all');
begin
  if not v_all and not public.hmy_can('cases.view_own') then raise exception 'HMY_FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(public.hmy_case_json(c) order by
                     case c.priority when 'urgent' then 0 when 'high' then 1 else 2 end, c.created_at)
    from public.ops_cases c
    where (p_include_resolved or c.status <> 'resolved')
      and case when not v_all or p_scope = 'mine' then c.assigned_to = auth.uid()
               when p_scope = 'unassigned' then c.assigned_to is null
               when p_scope = 'escalated' then c.status = 'escalated'
               when p_scope = 'escalated_owner' then c.status = 'escalated' and c.escalated_to = 'owner'
               when p_scope = 'urgent' then c.priority = 'urgent'
               else true end
    limit 300), '[]'::jsonb);
end $$;

-- El panel del gerente cuenta los pedidos igual que el del propietario (hora
-- de Bolivia, sin borradores), para que su lista diga lo mismo.
create or replace function public.ops_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := public.hmy_staff_role();
  v_today timestamptz := date_trunc('day', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
begin
  if not public.hmy_can('ops.dashboard') then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'role', v_role,
    'my_open_cases', (select count(*) from public.ops_cases where assigned_to = auth.uid() and status <> 'resolved'),
    'my_escalated', (select count(*) from public.ops_cases where assigned_to = auth.uid() and status = 'escalated'),
    'my_resolved_7d', (select count(*) from public.ops_cases where assigned_to = auth.uid() and status = 'resolved'
                         and resolved_at > now() - interval '7 days')
  ) || case when public.hmy_can('cases.view_all') then jsonb_build_object(
    'unassigned_cases', (select count(*) from public.ops_cases where assigned_to is null and status <> 'resolved'),
    'escalated_cases', (select count(*) from public.ops_cases where status = 'escalated'),
    'urgent_cases', (select count(*) from public.ops_cases where priority = 'urgent' and status <> 'resolved'),
    'pending_applications', (select count(*) from public.professional_profiles where status in ('submitted', 'under_review')),
    'pending_documents', (select count(*) from public.professional_documents where status = 'pending'),
    'flagged_documents', (select count(*) from public.professional_documents where flagged_at is not null and status = 'pending'),
    'open_tickets', (select count(*) from public.support_tickets where status <> 'closed'),
    'open_reports', (select count(*) from public.user_reports where status in ('open', 'reviewing')),
    'open_disputes', (select count(*) from public.disputes where status = 'open'),
    'active_bookings', (select count(*) from public.bookings
                        where status not in ('draft', 'completed', 'cancelled')),
    'bookings_today', (select count(*) from public.bookings where created_at >= v_today and status <> 'draft'),
    'completed_today', (select count(*) from public.bookings where status = 'completed' and completed_at >= v_today),
    'cancelled_today', (select count(*) from public.bookings where status = 'cancelled' and cancelled_at >= v_today),
    'available_professionals', (select count(*) from public.professional_profiles
                                where status = 'approved' and is_available),
    'approved_professionals', (select count(*) from public.professional_profiles where status = 'approved')
  ) else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------------------
-- Pedidos
-- ---------------------------------------------------------------------------
create function public.hmy_booking_row(b public.bookings, p_money boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', b.id, 'code', b.code, 'status', b.status, 'mode', b.mode,
    'category_name', (select name from public.service_categories where id = b.category_id),
    'city_name', (select name from public.cities where id = b.city_id),
    'zone_name', (select name from public.service_zones where id = b.zone_id),
    'customer_id', b.customer_id,
    'customer_name', (select full_name from public.profiles where id = b.customer_id),
    'professional_id', b.professional_id,
    'professional_name', (select display_name from public.professional_profiles where user_id = b.professional_id),
    'scheduled_start', b.scheduled_start, 'accepted_at', b.accepted_at, 'started_at', b.started_at,
    'completed_at', b.completed_at, 'cancelled_at', b.cancelled_at, 'cancel_reason', b.cancel_reason,
    'payment_method', b.payment_method, 'created_at', b.created_at,
    'has_dispute', exists (select 1 from public.disputes d where d.booking_id = b.id and d.status = 'open'),
    'open_case_id', (select c.id from public.ops_cases c
                     where c.kind in ('booking', 'dispute') and c.ref_id = b.id::text and c.status <> 'resolved'
                     order by c.id limit 1))
  || case when p_money then jsonb_strip_nulls(jsonb_build_object(
       'final_amount', b.final_amount, 'quote_amount', b.quote_amount,
       'commission_reserved', b.commission_reserved, 'commission_captured', b.commission_captured))
     else '{}'::jsonb end
$$;

-- p_filter: 'hoy', 'activos', 'completados_hoy', 'cancelados_hoy',
-- 'completados_mes', 'cancelados_mes' o 'recientes' (30 días).
create function public.ops_bookings(p_filter text default 'hoy', p_query text default null, p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today timestamptz := date_trunc('day', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
  v_month timestamptz := date_trunc('month', now() at time zone 'America/La_Paz') at time zone 'America/La_Paz';
  v_money boolean := public.is_admin();
  q text := '%' || public.hmy_norm(coalesce(btrim(p_query), '')) || '%';
  v_items jsonb;
  v_total int;
begin
  if not public.hmy_can('bookings.monitor') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_filter not in ('hoy', 'activos', 'completados_hoy', 'cancelados_hoy', 'completados_mes', 'cancelados_mes',
                      'recientes') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  with m as (
    select b.* from public.bookings b
    left join public.profiles cu on cu.id = b.customer_id
    left join public.professional_profiles pp on pp.user_id = b.professional_id
    where case p_filter
            when 'hoy' then b.created_at >= v_today and b.status <> 'draft'
            when 'activos' then b.status not in ('draft', 'completed', 'cancelled')
            when 'completados_hoy' then b.status = 'completed' and b.completed_at >= v_today
            when 'cancelados_hoy' then b.status = 'cancelled' and b.cancelled_at >= v_today
            when 'completados_mes' then b.status = 'completed' and b.completed_at >= v_month
            when 'cancelados_mes' then b.status = 'cancelled' and b.cancelled_at >= v_month
            else b.created_at >= now() - interval '30 days' and b.status <> 'draft' end
      and (coalesce(btrim(p_query), '') = ''
           or upper(b.code) like upper('%' || btrim(p_query) || '%')
           or public.hmy_norm(coalesce(cu.full_name, '')) like q
           or public.hmy_norm(coalesce(pp.display_name, '')) like q)
  )
  select (select count(*)::int from m),
         coalesce((select jsonb_agg(public.hmy_booking_row(x, v_money) order by x.created_at desc)
                   from (select * from m order by created_at desc
                         limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb)
  into v_total, v_items;
  return jsonb_build_object('items', v_items, 'total', v_total, 'money', v_money);
end $$;

create function public.ops_booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.bookings; v_money boolean := public.is_admin();
begin
  if not public.hmy_can('bookings.monitor') then raise exception 'HMY_FORBIDDEN'; end if;
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  return public.hmy_booking_row(b, v_money) || jsonb_build_object(
    'description', b.description,
    'events', coalesce((select jsonb_agg(jsonb_build_object(
                          'from_status', e.from_status, 'to_status', e.to_status, 'note', e.note,
                          'actor', case when e.actor_id is null then 'sistema'
                                        when e.actor_id = b.customer_id then 'cliente'
                                        when e.actor_id = b.professional_id then 'profesional'
                                        else 'equipo' end,
                          'created_at', e.created_at) order by e.created_at, e.id)
                        from public.booking_events e where e.booking_id = b.id), '[]'::jsonb),
    'cases', coalesce((select jsonb_agg(public.hmy_case_json(c) order by c.created_at)
                       from public.ops_cases c
                       where (c.kind in ('booking', 'dispute') and c.ref_id = b.id::text)
                          or (c.kind = 'report' and c.ref_id in (select r.id::text from public.user_reports r
                                                                 where r.booking_id = b.id))
                          or (c.kind = 'support' and c.ref_id in (select t.id::text from public.support_tickets t
                                                                  where t.booking_id = b.id))), '[]'::jsonb),
    'dispute', (select jsonb_build_object('status', d.status, 'reason', d.reason, 'resolution', d.resolution,
                                          'created_at', d.created_at)
                from public.disputes d where d.booking_id = b.id));
end $$;

-- Abrir un caso para revisar un pedido. Si ya hay uno abierto, devuelve ese.
create function public.ops_open_booking_case(p_booking uuid, p_reason text, p_category text default 'routine')
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_code text; v_case bigint; v_status text;
begin
  if not (public.hmy_can('bookings.monitor') and public.hmy_can('cases.update')) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'HMY_REASON_REQUIRED'; end if;
  if p_category not in ('routine', 'safety', 'fraud') then raise exception 'HMY_INVALID_STATUS'; end if;
  select code into v_code from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  select id, status into v_case, v_status from public.ops_cases where kind = 'booking' and ref_id = p_booking::text;
  if v_case is not null and v_status <> 'resolved' then return v_case; end if;
  if v_case is null then
    insert into public.ops_cases (kind, ref_id, title, category, priority)
    values ('booking', p_booking::text, 'Revisar el pedido ' || v_code, p_category,
            case when p_category = 'routine' then 'normal' else 'urgent' end)
    returning id into v_case;
  else
    update public.ops_cases
    set status = 'open', resolved_at = null, escalated_to = null, category = p_category,
        priority = case when p_category = 'routine' then 'normal' else 'urgent' end, updated_at = now()
    where id = v_case;
  end if;
  insert into public.ops_case_notes (case_id, author_id, kind, body)
  values (v_case, auth.uid(), 'note', 'Caso abierto desde el pedido: ' || btrim(p_reason));
  perform public.audit('case.open_booking', 'ops_cases', v_case::text,
                       jsonb_build_object('booking', p_booking, 'code', v_code, 'category', p_category,
                                          'reason', btrim(p_reason)));
  return v_case;
end $$;

-- ---------------------------------------------------------------------------
-- Personas
-- ---------------------------------------------------------------------------
-- p_filter: 'todos', 'clientes', 'profesionales', 'disponibles', 'identidad'
-- o 'suspendidos'.
create function public.admin_people(p_filter text default 'todos', p_query text default null, p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := '%' || public.hmy_norm(coalesce(btrim(p_query), '')) || '%';
  v_items jsonb;
  v_total int;
begin
  if not public.hmy_can('users.view') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_filter not in ('todos', 'clientes', 'profesionales', 'disponibles', 'identidad', 'suspendidos') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  with m as (
    select p.*, u.email::text as email, pp.status as pro_status, pp.is_available,
           (select ic.status from public.identity_checks ic where ic.professional_id = p.id
            order by ic.created_at desc limit 1) as identity_status
    from public.profiles p
    left join auth.users u on u.id = p.id
    left join public.professional_profiles pp on pp.user_id = p.id
    where case p_filter
            when 'clientes' then
              not exists (select 1 from public.user_roles r where r.user_id = p.id and r.role = 'admin')
              and coalesce(pp.status::text, '') <> 'approved'
            when 'profesionales' then pp.status = 'approved'
            when 'disponibles' then pp.status = 'approved' and pp.is_available
            when 'identidad' then exists (select 1 from public.identity_checks ic where ic.professional_id = p.id
                                          and ic.status in ('in_review', 'in_progress', 'created', 'resubmitted'))
            when 'suspendidos' then p.suspended_at is not null
            else true end
      and (coalesce(btrim(p_query), '') = ''
           or public.hmy_norm(p.full_name) like q or public.hmy_norm(coalesce(u.email::text, '')) like q
           or coalesce(p.phone, '') like '%' || btrim(p_query) || '%')
  )
  select (select count(*)::int from m),
         coalesce((select jsonb_agg(jsonb_build_object(
             'id', x.id, 'full_name', x.full_name, 'email', x.email, 'phone', x.phone,
             'city_name', (select name from public.cities where id = x.city_id),
             'roles', coalesce((select jsonb_agg(r.role::text order by r.role) from public.user_roles r
                                where r.user_id = x.id), '[]'::jsonb),
             'professional_status', x.pro_status, 'is_available', x.is_available,
             'identity_status', x.identity_status,
             'suspended_at', x.suspended_at, 'suspension_reason', x.suspension_reason,
             'reports_against', (select count(*)::int from public.user_reports r where r.reported_id = x.id),
             'created_at', x.created_at) order by x.suspended_at desc nulls last, x.created_at desc)
           from (select * from m order by suspended_at desc nulls last, created_at desc
                 limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb)
  into v_total, v_items;
  return jsonb_build_object('items', v_items, 'total', v_total);
end $$;

-- ---------------------------------------------------------------------------
-- Seguridad y fraude
-- ---------------------------------------------------------------------------
-- p_kind: 'safety' o 'fraud'. Las mismas tres fuentes que el panel.
create function public.ops_risk_items(p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ai boolean := public.is_admin(); v_items jsonb;
begin
  if not public.hmy_can('reports.view') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_kind not in ('safety', 'fraud') then raise exception 'HMY_INVALID_STATUS'; end if;
  select coalesce(jsonb_agg(x.j order by x.rank, x.at desc), '[]'::jsonb) into v_items from (
    select 0 as rank, r.created_at as at, jsonb_build_object(
             'source', 'report', 'id', r.id::text, 'title', 'Reporte por ' || r.reason, 'reason', r.reason,
             'detail', r.details, 'status', r.status, 'severity', 'high',
             'person', (select full_name from public.profiles where id = r.reported_id),
             'person_id', r.reported_id,
             'case_id', (select c.id from public.ops_cases c where c.kind = 'report' and c.ref_id = r.id::text),
             'created_at', r.created_at) as j
    from public.user_reports r
    where r.status in ('open', 'reviewing')
      and ((p_kind = 'safety' and r.reason = 'acoso')
           or (p_kind = 'fraud' and r.reason in ('fraude', 'cobro_indebido')))
    union all
    select case c.priority when 'urgent' then 0 else 1 end, c.created_at, jsonb_build_object(
             'source', 'case', 'id', c.id::text, 'title', c.title, 'status', c.status,
             'severity', case c.priority when 'urgent' then 'critical' when 'high' then 'high' else 'medium' end,
             'person', (select full_name from public.profiles where id = c.assigned_to),
             'case_id', c.id, 'created_at', c.created_at)
    from public.ops_cases c
    where c.status <> 'resolved' and c.category = p_kind and c.kind <> 'report'
    union all
    select case a.severity when 'critical' then 0 when 'high' then 0 else 1 end, a.created_at, jsonb_build_object(
             'source', 'ai', 'id', a.id::text, 'title', a.title, 'status', a.status, 'severity', a.severity,
             'created_at', a.created_at)
    from public.ai_items a
    where v_ai and p_kind = 'fraud' and a.agent_key = 'fraud' and a.status in ('open', 'pending_approval', 'more_info')
  ) x;
  return jsonb_build_object('items', v_items, 'total', jsonb_array_length(v_items), 'includes_ai', v_ai);
end $$;

-- ---------------------------------------------------------------------------
-- Billeteras de los profesionales (solo propietario)
-- ---------------------------------------------------------------------------
-- p_sort: 'disponible', 'reservado' o 'reciente'.
create function public.owner_wallets(p_query text default null, p_sort text default 'disponible',
                                     p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := '%' || public.hmy_norm(coalesce(btrim(p_query), '')) || '%';
  v_items jsonb;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_sort not in ('disponible', 'reservado', 'reciente') then raise exception 'HMY_INVALID_STATUS'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'professional_id', x.professional_id, 'name', x.name, 'city_name', x.city_name,
           'available', x.available, 'reserved', x.reserved, 'updated_at', x.updated_at,
           'last_movement_at', x.last_movement_at, 'pending_topups', x.pending_topups,
           'professional_status', x.status)
         order by case p_sort when 'disponible' then x.available when 'reservado' then x.reserved end desc nulls last,
                  x.last_movement_at desc nulls last), '[]'::jsonb)
  into v_items
  from (select w.professional_id, coalesce(nullif(pp.display_name, ''), p.full_name) as name, c.name as city_name,
               w.available, w.reserved, w.updated_at, pp.status,
               (select max(l.created_at) from public.wallet_ledger l where l.professional_id = w.professional_id)
                 as last_movement_at,
               (select count(*)::int from public.topup_requests t
                where t.professional_id = w.professional_id and t.status = 'pending') as pending_topups
        from public.wallets w
        join public.professional_profiles pp on pp.user_id = w.professional_id
        join public.profiles p on p.id = w.professional_id
        left join public.cities c on c.id = pp.city_id
        where coalesce(btrim(p_query), '') = ''
           or public.hmy_norm(coalesce(pp.display_name, '')) like q or public.hmy_norm(p.full_name) like q
        order by case p_sort when 'disponible' then w.available when 'reservado' then w.reserved end desc nulls last,
                 (select max(l.created_at) from public.wallet_ledger l where l.professional_id = w.professional_id)
                   desc nulls last
        limit least(greatest(coalesce(p_limit, 100), 1), 200)) x;
  return jsonb_build_object(
    'items', v_items,
    'total', (select count(*)::int from public.wallets),
    'available', (select coalesce(sum(available), 0) from public.wallets),
    'reserved', (select coalesce(sum(reserved), 0) from public.wallets));
end $$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_booking_row(public.bookings, boolean) from public, anon, authenticated;
revoke execute on function public.ops_bookings(text, text, int), public.ops_booking_detail(uuid),
  public.ops_open_booking_case(uuid, text, text), public.admin_people(text, text, int),
  public.ops_risk_items(text), public.owner_wallets(text, text, int) from public, anon;
grant execute on function public.ops_bookings(text, text, int), public.ops_booking_detail(uuid),
  public.ops_open_booking_case(uuid, text, text), public.admin_people(text, text, int),
  public.ops_risk_items(text), public.owner_wallets(text, text, int) to authenticated;
