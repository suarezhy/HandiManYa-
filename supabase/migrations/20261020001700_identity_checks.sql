-- HandiMan ¡Ya! — 0017 verificación de identidad con Didit (sandbox primero).
--
-- Decisión del dueño: Didit solo en su sandbox gratis; nada pagado, ningún
-- carnet real hasta que lo autorice.
-- - El resultado de Didit es una señal para el equipo, nunca una aprobación:
--   un profesional recibe pedidos solo cuando un administrador lo aprueba.
-- - Un resultado del sandbox es simulado y nunca cuenta como verificación real.
-- - Se guardan solo el estado, los puntajes y los avisos. Nunca imágenes,
--   nombres, fechas de nacimiento ni números de documento (eso queda en Didit,
--   y se borra allí después de la decisión).
-- - Los antecedentes (REJAP, policiales) siguen aparte, como documentos que
--   revisa una persona.

create table public.identity_checks (
  id bigint generated always as identity primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  vendor text not null default 'didit' check (vendor in ('didit')),
  sandbox boolean not null,
  session_id text unique,
  verification_url text,
  status text not null default 'created'
    check (status in ('created', 'in_progress', 'approved', 'declined', 'in_review', 'resubmitted', 'expired',
                      'abandoned', 'failed')),
  document_type text,
  id_document_status text,
  liveness_score numeric(5,2),
  face_match_score numeric(5,2),
  warnings text[] not null default '{}',
  last_event_id text,
  vendor_deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz
);
create index identity_checks_pro on public.identity_checks (professional_id, created_at desc);
create trigger identity_checks_touch before update on public.identity_checks
  for each row execute function public.touch_updated_at();

alter table public.identity_checks enable row level security;
revoke all on public.identity_checks from anon, authenticated;
create policy identity_checks_admin on public.identity_checks for select to authenticated using (public.is_admin());
grant select on public.identity_checks to authenticated;

-- Si se activa, aprobar a un profesional exige una verificación real aprobada
-- (nunca una del sandbox). Apagado mientras Didit está solo en pruebas.
insert into public.app_settings (key, value) values ('identity_check', '{"required": false}');

update public.ai_agents
set needs = 'Cuenta de Didit en modo sandbox (gratis) y sus claves en Supabase. El uso real necesita autorización del dueño.'
where key = 'identity';

-- ---------------------------------------------------------------------------
-- Funciones del servidor (las llama la función identity-check, nunca la app)
-- ---------------------------------------------------------------------------
create function public.hmy_identity_begin(p_user uuid, p_sandbox boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_status public.verification_status;
  v_open public.identity_checks;
  v_gate jsonb;
  v_id bigint;
begin
  select status into v_status from public.professional_profiles where user_id = p_user for update;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'no_application'); end if;
  if v_status not in ('draft', 'submitted', 'under_review', 'reverification_required') then
    return jsonb_build_object('allowed', false, 'reason', 'invalid_status');
  end if;
  if v_status <> 'reverification_required' and exists (select 1 from public.identity_checks
             where professional_id = p_user and sandbox = p_sandbox and status = 'approved'
               and created_at > now() - interval '30 days') then
    return jsonb_build_object('allowed', false, 'reason', 'already_approved');
  end if;
  -- Una sesión abierta reciente se retoma en vez de pagar otra.
  select * into v_open from public.identity_checks
  where professional_id = p_user and sandbox = p_sandbox and status in ('created', 'in_progress')
    and verification_url is not null and created_at > now() - interval '1 hour'
  order by created_at desc limit 1;
  if found then
    return jsonb_build_object('allowed', true, 'resume', true, 'id', v_open.id, 'verification_url', v_open.verification_url);
  end if;
  -- Cada intento real se cobra fuera del plan gratis: máximo 3 por mes.
  if not p_sandbox and (select count(*) from public.identity_checks
                        where professional_id = p_user and not sandbox
                          and created_at > now() - interval '30 days') >= 3 then
    return jsonb_build_object('allowed', false, 'reason', 'attempt_limit');
  end if;
  v_gate := public.hmy_cost_gate('didit_kyc', 1, p_sandbox, 'identity:' || p_user);
  if not (v_gate ->> 'allowed')::boolean then
    return jsonb_build_object('allowed', false, 'reason', v_gate ->> 'reason');
  end if;
  insert into public.identity_checks (professional_id, sandbox) values (p_user, p_sandbox) returning id into v_id;
  return jsonb_build_object('allowed', true, 'resume', false, 'id', v_id);
end $$;

create function public.hmy_identity_session(p_check bigint, p_session_id text, p_url text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_session_id is null or p_url is null or p_url !~ '^https://' then raise exception 'HMY_INVALID_SESSION'; end if;
  update public.identity_checks set session_id = left(p_session_id, 80), verification_url = left(p_url, 500)
  where id = p_check and session_id is null;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
end $$;

-- Crear la sesión en Didit falló: queda registrado, sin sesión.
create function public.hmy_identity_failed(p_check bigint)
returns void
language sql security definer set search_path = public as $$
  update public.identity_checks set status = 'failed' where id = p_check and session_id is null
$$;

-- Resultado de Didit (webhook o consulta). p_details ya viene reducido por la
-- función: document_type, id_document_status, liveness_score,
-- face_match_score y warnings (códigos), nada más.
create function public.hmy_identity_decision(p_session_id text, p_status text, p_details jsonb, p_event_id text,
                                             p_sandbox boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.identity_checks;
  v_status text := case p_status
    when 'Not Started' then 'created' when 'In Progress' then 'in_progress' when 'Approved' then 'approved'
    when 'Declined' then 'declined' when 'In Review' then 'in_review' when 'Resubmitted' then 'resubmitted'
    when 'Expired' then 'expired' when 'Kyc Expired' then 'expired' when 'Abandoned' then 'abandoned' end;
  v_final boolean;
begin
  if v_status is null then raise exception 'HMY_INVALID_STATUS'; end if;
  select * into c from public.identity_checks where session_id = p_session_id for update;
  if not found then return jsonb_build_object('updated', false, 'reason', 'unknown_session'); end if;
  -- Una sesión del sandbox nunca puede marcar como verificada a una real (y al revés).
  if c.sandbox <> p_sandbox then raise exception 'HMY_ENVIRONMENT_MISMATCH'; end if;
  if p_event_id is not null and c.last_event_id = p_event_id then
    return jsonb_build_object('updated', false, 'reason', 'duplicate');
  end if;
  -- Un aviso atrasado no reemplaza un resultado final, salvo la revisión manual en Didit.
  v_final := c.status in ('approved', 'declined', 'expired', 'abandoned');
  if v_final and v_status in ('created', 'in_progress') then
    return jsonb_build_object('updated', false, 'reason', 'stale');
  end if;
  update public.identity_checks
  set status = v_status,
      document_type = coalesce(left(p_details ->> 'document_type', 60), document_type),
      id_document_status = coalesce(left(p_details ->> 'id_document_status', 30), id_document_status),
      liveness_score = coalesce((p_details ->> 'liveness_score')::numeric, liveness_score),
      face_match_score = coalesce((p_details ->> 'face_match_score')::numeric, face_match_score),
      warnings = coalesce((select array_agg(left(w, 80)) from jsonb_array_elements_text(
                            case when jsonb_typeof(p_details -> 'warnings') = 'array' then p_details -> 'warnings' end) w
                          ), warnings),
      last_event_id = coalesce(left(p_event_id, 80), last_event_id),
      decided_at = case when v_status in ('approved', 'declined', 'in_review') then now() else decided_at end
  where id = c.id;
  if v_status in ('declined', 'in_review') and not c.sandbox then
    perform public.hmy_raise_item('identity', 'alert', case v_status when 'declined' then 'high' else 'medium' end, 'rule',
      case v_status when 'declined' then 'Verificación de identidad rechazada por Didit'
                    else 'Verificación de identidad para revisar' end,
      'Revisa la postulación antes de decidir. El resultado de Didit no aprueba ni rechaza a nadie por sí solo.',
      jsonb_build_object('check', c.id, 'status', v_status), format('identity:%s:%s', c.id, v_status),
      'professional_profiles', c.professional_id::text);
  end if;
  return jsonb_build_object('updated', true, 'status', v_status, 'professional_id', c.professional_id,
                            'final', v_status in ('approved', 'declined', 'expired', 'abandoned'));
end $$;

-- Didit confirmó que borró la sesión (y con ella la plantilla facial).
create function public.hmy_identity_deleted(p_session_id text)
returns void
language sql security definer set search_path = public as $$
  update public.identity_checks set vendor_deleted_at = now() where session_id = p_session_id
$$;

-- Sesiones con decisión final aún no borradas en Didit, o sin respuesta: la
-- función las revisa (los webhooks de Didit se reintentan solo 2 veces).
create function public.hmy_identity_pending(p_limit int default 20)
returns table (id bigint, session_id text, sandbox boolean, status text)
language sql stable security definer set search_path = public as $$
  select c.id, c.session_id, c.sandbox, c.status from public.identity_checks c
  where c.session_id is not null
    and ((c.status in ('created', 'in_progress', 'in_review') and c.created_at < now() - interval '15 minutes'
          and c.created_at > now() - interval '7 days')
         or (c.status in ('approved', 'declined', 'expired', 'abandoned') and c.vendor_deleted_at is null))
  order by c.updated_at
  limit least(greatest(p_limit, 1), 100)
$$;

-- ---------------------------------------------------------------------------
-- Para la app
-- ---------------------------------------------------------------------------
-- El profesional ve solo el estado de su última verificación.
create function public.my_identity_check()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('status', c.status, 'sandbox', c.sandbox, 'created_at', c.created_at,
                                             'decided_at', c.decided_at)
                   from public.identity_checks c where c.professional_id = auth.uid()
                   order by c.created_at desc limit 1), jsonb_build_object('status', 'none'))
$$;

-- Ficha de la postulación: con las verificaciones de identidad.
create or replace function public.admin_application_detail(p_professional uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- Aprobar sigue siendo una decisión humana. Si se exige la verificación de
-- identidad, además tiene que haber una real (no del sandbox) aprobada.
create function public.hmy_identity_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved'
     and old.status <> 'suspended'
     and coalesce((select (value ->> 'required')::boolean from public.app_settings where key = 'identity_check'), false)
     and not exists (select 1 from public.identity_checks
                     where professional_id = new.user_id and not sandbox and status = 'approved') then
    raise exception 'HMY_IDENTITY_CHECK_REQUIRED';
  end if;
  return new;
end $$;

create trigger professional_profiles_identity_guard before update of status on public.professional_profiles
  for each row execute function public.hmy_identity_guard();

-- Exigir la verificación real se activa sin más; quitarla pide confirmar que es el dueño.
create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_auth_method text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_key = 'daily_report' then
    if p_value ->> 'timezone' is null or not exists (select 1 from pg_timezone_names where name = p_value ->> 'timezone')
       or coalesce((p_value ->> 'hour')::int, -1) not between 0 and 23 then
      raise exception 'HMY_INVALID_SETTING';
    end if;
  elsif p_key = 'ai_budget' then
    -- El presupuesto de IA es gasto: pide confirmar que es el dueño.
    if coalesce((p_value ->> 'monthly_usd')::numeric, -1) < 0 then raise exception 'HMY_INVALID_SETTING'; end if;
    perform public.hmy_require_confirmation(p_auth_method, 'settings.ai_budget');
    update public.cost_vendors
    set status = case when (p_value ->> 'monthly_usd')::numeric > 0 then 'paid' else 'off' end,
        paid_authorized = (p_value ->> 'monthly_usd')::numeric > 0,
        monthly_cap_usd = (p_value ->> 'monthly_usd')::numeric,
        authorized_by = auth.uid(), authorized_at = now()
    where key = 'ai_model';
  elsif p_key = 'identity_check' then
    if jsonb_typeof(p_value -> 'required') <> 'boolean' then raise exception 'HMY_INVALID_SETTING'; end if;
    if not (p_value ->> 'required')::boolean then
      perform public.hmy_require_confirmation(p_auth_method, 'settings.identity_check');
    end if;
    p_value := jsonb_build_object('required', (p_value ->> 'required')::boolean);
  else
    raise exception 'HMY_INVALID_SETTING';
  end if;
  update public.app_settings set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
  perform public.audit('settings.' || p_key, 'app_settings', p_key, p_value);
end $$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_identity_begin(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.hmy_identity_session(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.hmy_identity_failed(bigint) from public, anon, authenticated;
revoke execute on function public.hmy_identity_decision(text, text, jsonb, text, boolean) from public, anon, authenticated;
revoke execute on function public.hmy_identity_deleted(text) from public, anon, authenticated;
revoke execute on function public.hmy_identity_pending(int) from public, anon, authenticated;
revoke execute on function public.hmy_identity_guard() from public, anon, authenticated;
revoke execute on function public.my_identity_check() from public, anon;
revoke execute on function public.admin_application_detail(uuid) from public, anon;
grant execute on function public.hmy_identity_begin(uuid, boolean), public.hmy_identity_session(bigint, text, text),
  public.hmy_identity_failed(bigint), public.hmy_identity_decision(text, text, jsonb, text, boolean),
  public.hmy_identity_deleted(text), public.hmy_identity_pending(int) to service_role;
revoke execute on function public.admin_set_setting(text, jsonb, text) from public, anon;
grant execute on function public.my_identity_check(), public.admin_application_detail(uuid),
  public.admin_set_setting(text, jsonb, text) to authenticated;
