-- Tres roles de gestión: Propietario, Gerente de Operaciones y Empleado.
--
-- * Propietario = el rol 'admin' que ya existe. is_admin() no cambia, así que
--   todo lo financiero (billetera, recargas, comisiones, costos, IA, ajustes,
--   auditoría completa) sigue siendo solo del propietario, también contra
--   llamadas directas a la API.
-- * Gerente y Empleado viven en staff_members, con estado propio (activo,
--   suspendido, revocado). Solo el propietario los da, suspende o quita, y
--   siempre por el id de una cuenta que ya entró con su celular confirmado.
-- * Cada permiso se decide en el servidor con hmy_can(). Un miembro
--   suspendido o revocado pierde todo en la siguiente llamada.
-- * Casos (ops_cases): cada solicitud de soporte, reporte, disputa y
--   postulación tiene un caso que el gerente asigna. El empleado ve solo los
--   suyos.
-- Nada de esta migración da un rol a ninguna cuenta.

-- ---------------------------------------------------------------------------
-- Miembros del equipo
-- ---------------------------------------------------------------------------
create table public.staff_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role text not null check (role in ('manager', 'employee')),
  status text not null default 'active' check (status in ('active', 'suspended', 'revoked')),
  status_reason text,
  granted_by uuid not null references auth.users (id),
  granted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Rol de gestión de una cuenta: 'owner', 'manager', 'employee' o null.
create function public.hmy_staff_role(p_user uuid default auth.uid()) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_user is null then null
    when public.has_role('admin', p_user) then 'owner'
    else (select s.role from public.staff_members s
          join public.profiles p on p.id = s.user_id
          where s.user_id = p_user and s.status = 'active' and p.suspended_at is null)
  end
$$;

-- Permisos por rol. El propietario tiene todos. Lo que no está acá, se niega.
create function public.hmy_role_permissions(p_role text) returns text[]
language sql immutable as $$
  select case p_role
    when 'manager' then array[
      'ops.dashboard', 'cases.view_all', 'cases.assign', 'cases.update', 'cases.note', 'cases.reply',
      'cases.escalate', 'applications.list', 'applications.decide', 'documents.view', 'documents.review',
      'documents.flag', 'reports.view', 'reports.decide', 'disputes.view', 'tickets.view', 'tickets.reply',
      'users.view', 'users.suspend', 'staff.view', 'bookings.monitor']
    when 'employee' then array[
      'ops.dashboard', 'cases.view_own', 'cases.update_own', 'cases.note', 'cases.reply', 'cases.escalate',
      'documents.flag']
    else array[]::text[]
  end
$$;

create function public.hmy_can(p_permission text) returns boolean
language sql stable security definer set search_path = public as $$
  with r as (select public.hmy_staff_role() as role)
  select case when r.role is null then false
              when r.role = 'owner' then true
              else p_permission = any (public.hmy_role_permissions(r.role)) end
  from r
$$;

create function public.my_staff_role() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'role', public.hmy_staff_role(),
    'status', (select status from public.staff_members where user_id = auth.uid()),
    'permissions', case when public.hmy_staff_role() = 'owner' then to_jsonb(array['*'])
                        else to_jsonb(public.hmy_role_permissions(public.hmy_staff_role())) end)
$$;

-- Dar un rol: solo el propietario, solo a una cuenta real que ya entró con
-- su celular confirmado, nunca a sí mismo ni a otro propietario.
create function public.owner_grant_staff(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
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
end $$;

-- Suspender, reactivar o quitar el acceso. Los casos abiertos de quien deja
-- de estar activo vuelven a la bandeja sin asignar.
create function public.owner_set_staff_status(p_user uuid, p_status text, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------
create table public.ops_cases (
  id bigserial primary key,
  kind text not null check (kind in ('support', 'application', 'dispute', 'report')),
  ref_id text not null,
  title text not null,
  -- 'safety' y 'fraud' se tratan como sensibles: el empleado solo los escala.
  category text not null default 'routine' check (category in ('routine', 'safety', 'fraud', 'dispute')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'waiting', 'escalated', 'resolved')),
  priority text not null default 'normal' check (priority in ('normal', 'high', 'urgent')),
  assigned_to uuid references auth.users (id),
  assigned_by uuid references auth.users (id),
  assigned_at timestamptz,
  escalated_to text check (escalated_to in ('manager', 'owner')),
  first_response_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (kind, ref_id)
);
create index ops_cases_assigned_idx on public.ops_cases (assigned_to, status);
create index ops_cases_status_idx on public.ops_cases (status, created_at);

create table public.ops_case_notes (
  id bigserial primary key,
  case_id bigint not null references public.ops_cases (id) on delete cascade,
  author_id uuid not null references auth.users (id),
  kind text not null check (kind in ('note', 'reply', 'flag', 'status', 'assign', 'escalate')),
  body text not null check (char_length(body) between 1 and 3000),
  created_at timestamptz not null default now()
);
create index ops_case_notes_case_idx on public.ops_case_notes (case_id, created_at);

alter table public.professional_documents
  add column flagged_at timestamptz,
  add column flagged_by uuid references auth.users (id),
  add column flag_note text;

-- Quién puede ver un caso: el propietario y el gerente, todos; el empleado,
-- solo los que tiene asignados.
create function public.hmy_can_see_case(p_case bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.hmy_can('cases.view_all')
      or (public.hmy_can('cases.view_own')
          and exists (select 1 from public.ops_cases c where c.id = p_case and c.assigned_to = auth.uid()))
$$;

create function public.hmy_report_category(p_reason text) returns text
language sql immutable as $$
  select case when p_reason in ('acoso') then 'safety'
              when p_reason in ('fraude', 'cobro_indebido') then 'fraud'
              else 'routine' end
$$;

-- Cada solicitud nueva abre su caso.
create function public.hmy_open_case() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'support_tickets' then
    insert into public.ops_cases (kind, ref_id, title) values ('support', new.id::text, left(new.subject, 120))
    on conflict do nothing;
  elsif tg_table_name = 'user_reports' then
    insert into public.ops_cases (kind, ref_id, title, category, priority)
    values ('report', new.id::text, 'Reporte: ' || new.reason, public.hmy_report_category(new.reason),
            case when public.hmy_report_category(new.reason) = 'routine' then 'normal' else 'high' end)
    on conflict do nothing;
  elsif tg_table_name = 'disputes' then
    insert into public.ops_cases (kind, ref_id, title, category, priority)
    values ('dispute', new.booking_id::text, 'Disputa de un servicio', 'dispute', 'high')
    on conflict do nothing;
  elsif tg_table_name = 'professional_profiles' then
    if new.status in ('submitted', 'under_review') then
      insert into public.ops_cases (kind, ref_id, title)
      values ('application', new.user_id::text, 'Postulación: ' || left(coalesce(new.display_name, ''), 100))
      on conflict (kind, ref_id) do update
        set status = case when public.ops_cases.status = 'resolved' then 'open' else public.ops_cases.status end,
            resolved_at = null, updated_at = now();
    elsif new.status in ('approved', 'rejected') then
      update public.ops_cases set status = 'resolved', resolved_at = now(), updated_at = now()
      where kind = 'application' and ref_id = new.user_id::text and status <> 'resolved';
    end if;
  end if;
  return new;
end $$;

create trigger support_tickets_case after insert on public.support_tickets
  for each row execute function public.hmy_open_case();
create trigger user_reports_case after insert on public.user_reports
  for each row execute function public.hmy_open_case();
create trigger disputes_case after insert on public.disputes
  for each row execute function public.hmy_open_case();
create trigger professional_profiles_case after insert or update of status on public.professional_profiles
  for each row execute function public.hmy_open_case();

-- Lo que ya estaba abierto también tiene su caso.
insert into public.ops_cases (kind, ref_id, title, created_at)
select 'support', t.id::text, left(t.subject, 120), t.created_at from public.support_tickets t where t.status <> 'closed'
on conflict do nothing;
insert into public.ops_cases (kind, ref_id, title, category, priority, created_at)
select 'report', r.id::text, 'Reporte: ' || r.reason, public.hmy_report_category(r.reason),
       case when public.hmy_report_category(r.reason) = 'routine' then 'normal' else 'high' end, r.created_at
from public.user_reports r where r.status in ('open', 'reviewing')
on conflict do nothing;
insert into public.ops_cases (kind, ref_id, title, category, priority, created_at)
select 'dispute', d.booking_id::text, 'Disputa de un servicio', 'dispute', 'high', d.created_at
from public.disputes d where d.status = 'open'
on conflict do nothing;
insert into public.ops_cases (kind, ref_id, title, created_at)
select 'application', pp.user_id::text, 'Postulación: ' || left(coalesce(pp.display_name, ''), 100),
       coalesce(pp.submitted_at, now())
from public.professional_profiles pp where pp.status in ('submitted', 'under_review')
on conflict do nothing;

-- Resumen de un caso para el panel: sin dinero, sin teléfonos y sin
-- documentos de identidad (el empleado ve el tipo y el estado, no el archivo).
create function public.hmy_case_source(c public.ops_cases) returns jsonb
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
  end if;
  return coalesce(v, '{}'::jsonb);
end $$;

create function public.hmy_case_json(c public.ops_cases) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'ref_id', c.ref_id, 'title', c.title, 'category', c.category, 'status', c.status,
    'priority', c.priority, 'assigned_to', c.assigned_to,
    'assigned_name', (select full_name from public.profiles where id = c.assigned_to),
    'escalated_to', c.escalated_to, 'first_response_at', c.first_response_at, 'resolved_at', c.resolved_at,
    'created_at', c.created_at, 'updated_at', c.updated_at)
$$;

-- p_scope: 'mine' (los míos), 'unassigned', 'escalated' o 'all'. El empleado
-- siempre recibe solo los suyos, pida lo que pida.
create function public.ops_cases_list(p_scope text default 'mine', p_include_resolved boolean default false)
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
               else true end
    limit 300), '[]'::jsonb);
end $$;

create function public.ops_case_detail(p_case bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.ops_cases;
begin
  if not public.hmy_can_see_case(p_case) then raise exception 'HMY_FORBIDDEN'; end if;
  select * into c from public.ops_cases where id = p_case;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  return public.hmy_case_json(c) || jsonb_build_object(
    'source', public.hmy_case_source(c),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body,
                                                           'author_name', p.full_name, 'created_at', n.created_at)
                                        order by n.created_at)
                       from public.ops_case_notes n join public.profiles p on p.id = n.author_id
                       where n.case_id = p_case), '[]'));
end $$;

-- Asignar o reasignar: gerente o propietario, solo a un miembro activo. No
-- cambia permisos de nadie.
create function public.ops_assign_case(p_case bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.hmy_can('cases.assign') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_user is not null and coalesce(public.hmy_staff_role(p_user), '') not in ('manager', 'employee') then
    raise exception 'HMY_STAFF_NOT_ACTIVE';
  end if;
  update public.ops_cases set assigned_to = p_user, assigned_by = auth.uid(), assigned_at = now(), updated_at = now()
  where id = p_case;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  insert into public.ops_case_notes (case_id, author_id, kind, body)
  values (p_case, auth.uid(), 'assign',
          coalesce('Asignado a ' || (select full_name from public.profiles where id = p_user), 'Sin asignar'));
  if p_user is not null then
    perform public.notify(p_user, 'staff', 'Tienes un caso nuevo',
                          (select title from public.ops_cases where id = p_case), jsonb_build_object('case', p_case));
  end if;
  perform public.audit('case.assign', 'ops_cases', p_case::text, jsonb_build_object('to', p_user));
end $$;

create function public.hmy_case_for_action(p_case bigint, p_perm_all text, p_perm_own text)
returns public.ops_cases
language plpgsql security definer set search_path = public as $$
declare c public.ops_cases;
begin
  select * into c from public.ops_cases where id = p_case for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if not (public.hmy_can(p_perm_all) and public.hmy_can('cases.view_all'))
     and not (public.hmy_can(p_perm_own) and c.assigned_to = auth.uid()) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  return c;
end $$;

-- Cambiar el estado. El empleado: solo sus casos, y solo resuelve soporte y
-- reportes de rutina; disputas, fraude y seguridad los escala.
create function public.ops_set_case_status(p_case bigint, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  c public.ops_cases;
  v_manager boolean := public.hmy_can('cases.update');
begin
  if p_status not in ('open', 'in_progress', 'waiting', 'resolved') then raise exception 'HMY_INVALID_STATUS'; end if;
  c := public.hmy_case_for_action(p_case, 'cases.update', 'cases.update_own');
  if not v_manager then
    if p_status = 'resolved' and (c.kind not in ('support', 'report') or c.category <> 'routine') then
      raise exception 'HMY_ESCALATE_REQUIRED';
    end if;
    if c.status = 'escalated' then raise exception 'HMY_FORBIDDEN'; end if;
  end if;
  -- Una postulación se cierra solo con la decisión (aprobar o rechazar).
  if p_status = 'resolved' and c.kind = 'application' then raise exception 'HMY_DECISION_REQUIRED'; end if;
  if p_status = 'resolved' and coalesce(btrim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;

  update public.ops_cases
  set status = p_status, updated_at = now(),
      escalated_to = case when p_status = 'resolved' then escalated_to else null end,
      resolved_at = case when p_status = 'resolved' then now() end
  where id = p_case;
  if c.kind = 'support' then
    update public.support_tickets set status = case when p_status = 'resolved' then 'closed'
                                                     when p_status = 'open' then 'open' else 'in_progress' end
    where id = c.ref_id::bigint;
  elsif c.kind = 'report' and p_status = 'resolved' then
    update public.user_reports set status = 'resolved', resolution = btrim(p_note), reviewed_by = auth.uid(),
           reviewed_at = now()
    where id = c.ref_id::bigint;
  elsif c.kind = 'report' and p_status in ('in_progress', 'waiting') then
    update public.user_reports set status = 'reviewing' where id = c.ref_id::bigint and status = 'open';
  end if;
  insert into public.ops_case_notes (case_id, author_id, kind, body)
  values (p_case, auth.uid(), 'status', p_status || coalesce(': ' || nullif(btrim(p_note), ''), ''));
  perform public.audit('case.' || p_status, 'ops_cases', p_case::text,
                       jsonb_strip_nulls(jsonb_build_object('kind', c.kind, 'note', nullif(btrim(p_note), ''))));
end $$;

create function public.ops_add_note(p_case bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_case_for_action(p_case, 'cases.note', 'cases.note');
  if char_length(btrim(coalesce(p_body, ''))) < 2 then raise exception 'HMY_REASON_REQUIRED'; end if;
  insert into public.ops_case_notes (case_id, author_id, kind, body) values (p_case, auth.uid(), 'note', btrim(p_body));
  update public.ops_cases set updated_at = now() where id = p_case;
  perform public.audit('case.note', 'ops_cases', p_case::text);
end $$;

-- Responder a quien escribió a soporte. Llega como notificación.
create function public.ops_reply(p_case bigint, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare c public.ops_cases; v_user uuid;
begin
  c := public.hmy_case_for_action(p_case, 'cases.reply', 'cases.reply');
  if c.kind <> 'support' then raise exception 'HMY_INVALID_STATUS'; end if;
  if char_length(btrim(coalesce(p_message, ''))) < 2 then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.support_tickets set admin_note = btrim(p_message),
         status = case when status = 'open' then 'in_progress' else status end
  where id = c.ref_id::bigint returning user_id into v_user;
  perform public.notify(v_user, 'support', 'Respuesta de soporte', btrim(p_message), null);
  insert into public.ops_case_notes (case_id, author_id, kind, body) values (p_case, auth.uid(), 'reply', btrim(p_message));
  update public.ops_cases set first_response_at = coalesce(first_response_at, now()),
         status = case when status = 'open' then 'in_progress' else status end, updated_at = now()
  where id = p_case;
  perform public.audit('case.reply', 'ops_cases', p_case::text);
end $$;

-- Escalar: el empleado al gerente; el gerente al propietario.
create function public.ops_escalate(p_case bigint, p_reason text, p_category text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c public.ops_cases; v_to text;
begin
  c := public.hmy_case_for_action(p_case, 'cases.escalate', 'cases.escalate');
  if coalesce(btrim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  if p_category is not null and p_category not in ('safety', 'fraud', 'dispute') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  v_to := case when public.hmy_staff_role() = 'employee' then 'manager' else 'owner' end;
  update public.ops_cases
  set status = 'escalated', escalated_to = v_to, category = coalesce(p_category, category),
      priority = case when coalesce(p_category, category) in ('safety', 'fraud') then 'urgent' else 'high' end,
      updated_at = now()
  where id = p_case;
  insert into public.ops_case_notes (case_id, author_id, kind, body)
  values (p_case, auth.uid(), 'escalate', 'Escalado a ' || case v_to when 'owner' then 'propietario' else 'gerente' end
                                           || ': ' || btrim(p_reason));
  perform public.audit('case.escalate', 'ops_cases', p_case::text,
                       jsonb_strip_nulls(jsonb_build_object('to', v_to, 'category', p_category, 'reason', btrim(p_reason))));
end $$;

-- Marcar un documento como faltante o dudoso. No lo acepta ni lo rechaza: eso
-- lo decide el gerente o el propietario.
create function public.ops_flag_document(p_document bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare v_pro uuid; v_case bigint;
begin
  if not public.hmy_can('documents.flag') then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'HMY_REASON_REQUIRED'; end if;
  select professional_id into v_pro from public.professional_documents where id = p_document;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  select id into v_case from public.ops_cases where kind = 'application' and ref_id = v_pro::text;
  if not public.hmy_can('cases.view_all')
     and not exists (select 1 from public.ops_cases where id = v_case and assigned_to = auth.uid()) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  update public.professional_documents set flagged_at = now(), flagged_by = auth.uid(), flag_note = btrim(p_note)
  where id = p_document;
  if v_case is not null then
    insert into public.ops_case_notes (case_id, author_id, kind, body) values (v_case, auth.uid(), 'flag', btrim(p_note));
  end if;
  perform public.audit('document.flag', 'professional_documents', p_document::text,
                       jsonb_build_object('professional', v_pro, 'note', btrim(p_note)));
end $$;

-- Panel de operaciones: conteos sin dinero.
create function public.ops_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := public.hmy_staff_role();
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
                        where status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished')),
    'bookings_today', (select count(*) from public.bookings where created_at >= date_trunc('day', now())),
    'completed_today', (select count(*) from public.bookings where completed_at >= date_trunc('day', now())),
    'cancelled_today', (select count(*) from public.bookings where cancelled_at >= date_trunc('day', now())),
    'available_professionals', (select count(*) from public.professional_profiles
                                where status = 'approved' and is_available),
    'approved_professionals', (select count(*) from public.professional_profiles where status = 'approved')
  ) else '{}'::jsonb end;
end $$;

-- Equipo: tiempos de respuesta y carga (gerente y propietario). Sin datos
-- de dinero.
create function public.ops_staff_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- Mi actividad (cada miembro ve la suya; el propietario ve todo en Auditoría).
create function public.ops_my_activity(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.hmy_staff_role() is null then raise exception 'HMY_FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'target_table', a.target_table,
                                                       'target_id', a.target_id, 'created_at', a.created_at)
                                    order by a.created_at desc)
                   from (select * from public.admin_audit_log where actor_id = auth.uid()
                         order by created_at desc limit least(greatest(p_limit, 1), 200)) a), '[]'::jsonb);
end $$;

-- Detalle de una postulación para el empleado asignado: lo básico, sin
-- teléfono, correo, archivos ni puntajes de identidad.
create function public.ops_application_basic(p_professional uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.ops_cases;
begin
  select * into c from public.ops_cases where kind = 'application' and ref_id = p_professional::text;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if not public.hmy_can_see_case(c.id) then raise exception 'HMY_FORBIDDEN'; end if;
  return public.hmy_case_source(c);
end $$;

-- ---------------------------------------------------------------------------
-- Funciones que ya existían: el gerente entra a las operativas
-- ---------------------------------------------------------------------------
-- Aprobar o rechazar: gerente o propietario. Las mismas reglas de siempre
-- siguen en el servidor (carnet aceptado, documentos de la categoría,
-- verificación de identidad si se exige). Además, el gerente no puede
-- aprobar a quien tiene una verificación de identidad real rechazada.
create or replace function public.review_professional_application(
  p_professional uuid, p_decision public.verification_status, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_from public.verification_status;
begin
  if not public.hmy_can('applications.decide') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_decision not in ('under_review', 'approved', 'rejected', 'suspended', 'reverification_required') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  if p_decision in ('rejected', 'reverification_required') and coalesce(trim(p_note), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  if p_decision = 'approved' and not public.is_admin() and exists (
       select 1 from public.identity_checks ic
       where ic.professional_id = p_professional and not ic.sandbox
         and ic.id = (select max(id) from public.identity_checks x where x.professional_id = p_professional and not x.sandbox)
         and ic.status = 'declined') then
    raise exception 'HMY_IDENTITY_DECLINED';
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
  perform public.audit('application.' || p_decision, 'professional_profiles', p_professional::text,
                       jsonb_strip_nulls(jsonb_build_object('from', v_from, 'note', p_note,
                                                            'by_role', public.hmy_staff_role())));
end $$;

create or replace function public.admin_review_document(p_document bigint, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_pro uuid;
begin
  if not public.hmy_can('documents.review') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('pending', 'accepted', 'rejected') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status = 'rejected' and coalesce(trim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.professional_documents set status = p_status, review_note = nullif(trim(p_note), ''),
         flagged_at = case when p_status = 'pending' then flagged_at end,
         flagged_by = case when p_status = 'pending' then flagged_by end,
         flag_note = case when p_status = 'pending' then flag_note end
  where id = p_document returning professional_id into v_pro;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.audit('document.' || p_status, 'professional_documents', p_document::text,
                       jsonb_strip_nulls(jsonb_build_object('professional', v_pro, 'note', p_note,
                                                            'by_role', public.hmy_staff_role())));
end $$;

-- Suspender cuentas de clientes o profesionales: gerente o propietario.
-- Nadie del equipo puede suspender al propietario ni a otro miembro (eso es
-- owner_set_staff_status).
create or replace function public.admin_set_suspension(p_user uuid, p_suspend boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_pro public.verification_status;
begin
  if not public.hmy_can('users.suspend') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_user = auth.uid() or public.has_role('admin', p_user) then raise exception 'HMY_FORBIDDEN'; end if;
  if not public.is_admin() and exists (select 1 from public.staff_members where user_id = p_user) then
    raise exception 'HMY_FORBIDDEN';
  end if;
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
end $$;

create or replace function public.admin_review_report(p_report bigint, p_status text, p_resolution text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.hmy_can('reports.decide') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('reviewing', 'resolved', 'dismissed') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status in ('resolved', 'dismissed') and coalesce(trim(p_resolution), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  update public.user_reports
  set status = p_status, resolution = nullif(trim(p_resolution), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_report;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if p_status in ('resolved', 'dismissed') then
    update public.ops_cases set status = 'resolved', resolved_at = now(), updated_at = now()
    where kind = 'report' and ref_id = p_report::text and status <> 'resolved';
  end if;
  perform public.audit('report.' || p_status, 'user_reports', p_report::text,
                       jsonb_strip_nulls(jsonb_build_object('resolution', p_resolution)));
end $$;

create or replace function public.admin_update_ticket(p_ticket bigint, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not public.hmy_can('tickets.reply') then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('open', 'in_progress', 'closed') then raise exception 'HMY_INVALID_STATUS'; end if;
  update public.support_tickets set status = p_status, admin_note = coalesce(nullif(trim(p_note), ''), admin_note)
  where id = p_ticket returning user_id into v_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if nullif(trim(p_note), '') is not null then
    perform public.notify(v_user, 'support', 'Respuesta de soporte', trim(p_note), null);
  end if;
  update public.ops_cases
  set status = case p_status when 'closed' then 'resolved' when 'open' then 'open' else 'in_progress' end,
      resolved_at = case when p_status = 'closed' then now() end,
      first_response_at = case when nullif(trim(p_note), '') is not null then coalesce(first_response_at, now())
                               else first_response_at end,
      updated_at = now()
  where kind = 'support' and ref_id = p_ticket::text;
  perform public.audit('ticket.' || p_status, 'support_tickets', p_ticket::text,
                       jsonb_strip_nulls(jsonb_build_object('note', p_note)));
end $$;

create or replace function public.admin_applications(p_status text default 'pending')
returns table (user_id uuid, display_name text, full_name text, phone text, email text, city_name text,
               category_name text, status public.verification_status, submitted_at timestamptz, documents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hmy_can('applications.list') then raise exception 'HMY_FORBIDDEN'; end if;
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
end $$;

-- Igual que en 0017, con el permiso del gerente y la marca de documento dudoso.
create or replace function public.admin_application_detail(p_professional uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.hmy_can('applications.list') then raise exception 'HMY_FORBIDDEN'; end if;
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
                             'uploaded_at', d.uploaded_at, 'flag_note', d.flag_note) order by d.uploaded_at)
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
end $$;

create or replace function public.admin_reports(p_status text default 'open')
returns table (id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text,
               booking_id uuid, reason text, details text, status text, resolution text, created_at timestamptz,
               reports_against int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hmy_can('reports.view') then raise exception 'HMY_FORBIDDEN'; end if;
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
end $$;

-- Ver disputas: gerente o propietario. Resolverlas (resolve_dispute) mueve
-- la reserva y con ella la comisión: sigue siendo solo del propietario.
create or replace function public.admin_disputes(p_status text default 'open')
returns table (booking_id uuid, reason text, status text, resolution text, created_at timestamptz,
               opened_by_name text, customer_name text, professional_name text, category_name text,
               booking_status public.booking_status)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hmy_can('disputes.view') then raise exception 'HMY_FORBIDDEN'; end if;
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
end $$;

create or replace function public.admin_tickets(p_status text default 'open')
returns table (id bigint, user_id uuid, user_name text, booking_id uuid, subject text, body text, status text,
               admin_note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hmy_can('tickets.view') then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select t.id, t.user_id, p.full_name, t.booking_id, t.subject, t.body, t.status, t.admin_note, t.created_at
  from public.support_tickets t join public.profiles p on p.id = t.user_id
  where case p_status when 'open' then t.status <> 'closed' when 'all' then true else t.status = p_status end
  order by t.created_at asc
  limit 200;
end $$;

create or replace function public.admin_users(p_query text default null)
returns table (id uuid, full_name text, email text, phone text, city_name text, roles text[],
               professional_status public.verification_status, suspended_at timestamptz,
               suspension_reason text, reports_against int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare q text := '%' || public.hmy_norm(coalesce(trim(p_query), '')) || '%';
begin
  if not public.hmy_can('users.view') then raise exception 'HMY_FORBIDDEN'; end if;
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
end $$;

-- Archivos de documentos: el gerente puede abrirlos para revisarlos; el
-- empleado no. Comprobantes de recarga y QR siguen solo para el dueño y el
-- propietario.
create policy "hmy documents manager read" on storage.objects for select to authenticated
  using (bucket_id = 'professional-documents' and public.hmy_can('documents.view'));

-- ---------------------------------------------------------------------------
-- Acceso directo a las tablas
-- ---------------------------------------------------------------------------
alter table public.staff_members enable row level security;
alter table public.ops_cases enable row level security;
alter table public.ops_case_notes enable row level security;

create policy staff_members_read on public.staff_members for select
  using (user_id = auth.uid() or public.hmy_can('staff.view'));
create policy ops_cases_read on public.ops_cases for select using (public.hmy_can_see_case(id));
create policy ops_case_notes_read on public.ops_case_notes for select using (public.hmy_can_see_case(case_id));

-- Todo cambio pasa por las funciones de arriba.
revoke insert, update, delete on public.staff_members, public.ops_cases, public.ops_case_notes from anon, authenticated;
revoke usage, select on sequence public.ops_cases_id_seq, public.ops_case_notes_id_seq from anon, authenticated;
-- La auditoría no se borra ni se cambia desde la app (tampoco el propietario).
revoke insert, update, delete, truncate on public.admin_audit_log from anon, authenticated;

revoke execute on function public.hmy_open_case() from public, anon, authenticated;
revoke execute on function public.hmy_case_source(public.ops_cases), public.hmy_case_json(public.ops_cases),
  public.hmy_case_for_action(bigint, text, text), public.hmy_report_category(text),
  public.hmy_role_permissions(text) from public, anon, authenticated;
revoke execute on function public.hmy_staff_role(uuid), public.hmy_can(text), public.hmy_can_see_case(bigint),
  public.my_staff_role(), public.owner_grant_staff(uuid, text), public.owner_set_staff_status(uuid, text, text),
  public.ops_cases_list(text, boolean), public.ops_case_detail(bigint), public.ops_assign_case(bigint, uuid),
  public.ops_set_case_status(bigint, text, text), public.ops_add_note(bigint, text), public.ops_reply(bigint, text),
  public.ops_escalate(bigint, text, text), public.ops_flag_document(bigint, text), public.ops_dashboard(),
  public.ops_staff_overview(), public.ops_my_activity(int), public.ops_application_basic(uuid) from public, anon;
grant execute on function public.hmy_staff_role(uuid), public.hmy_can(text), public.hmy_can_see_case(bigint),
  public.my_staff_role(), public.owner_grant_staff(uuid, text), public.owner_set_staff_status(uuid, text, text),
  public.ops_cases_list(text, boolean), public.ops_case_detail(bigint), public.ops_assign_case(bigint, uuid),
  public.ops_set_case_status(bigint, text, text), public.ops_add_note(bigint, text), public.ops_reply(bigint, text),
  public.ops_escalate(bigint, text, text), public.ops_flag_document(bigint, text), public.ops_dashboard(),
  public.ops_staff_overview(), public.ops_my_activity(int), public.ops_application_basic(uuid) to authenticated;
