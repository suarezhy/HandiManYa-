-- HandiMan ¡Ya! — 0012 Centro de Control IA (base compartida de los agentes).
--
-- Un solo sistema: un "AI Boss" y agentes por responsabilidad, sobre las mismas
-- tablas. Los agentes OBSERVAN y RECOMIENDAN; nunca cambian saldos, aprueban
-- documentos, suspenden cuentas ni gastan dinero. Toda acción con consecuencias
-- pasa por la bandeja de aprobación del dueño, con confirmación y auditoría.
--
-- - ai_agents: los agentes, su fase y su estado (reglas, IA, falta configurar).
-- - ai_items: alertas, recomendaciones y pedidos de aprobación. `source` dice si
--   viene de una regla sobre datos reales ('rule') o de un modelo de IA ('ai'),
--   para no confundir recomendaciones con hechos.
-- - ai_agent_runs: cada ejecución, con costo y error si lo hubo.
-- - daily_reports: el reporte diario, solo con datos reales.
-- - app_settings: horario del reporte, presupuesto de IA, etc.
-- Todo es solo para administradores (RLS) y se escribe por funciones.

do $$ begin
  if to_regclass('public.security_settings') is null then
    raise exception 'HMY: falta la migración 0011; no se aplicó nada.';
  end if;
  if to_regclass('public.ai_agents') is not null then
    raise exception 'HMY: la migración 0012 ya está aplicada; no se aplicó nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------
create table public.ai_agents (
  key text primary key,
  number smallint not null unique,
  name text not null,
  purpose text not null,
  phase text not null check (phase in ('A', 'B', 'C')),
  -- rules: funciona con reglas sobre datos reales; ai: además usa un modelo;
  -- needs_setup: falta una cuenta o clave; planned: todavía no construido; off: apagado.
  status text not null default 'planned' check (status in ('rules', 'ai', 'needs_setup', 'planned', 'off')),
  needs text,
  added_by_claude boolean not null default false,
  last_run_at timestamptz,
  last_run_status text,
  updated_at timestamptz not null default now()
);

create table public.ai_agent_runs (
  id bigserial primary key,
  agent_key text not null references public.ai_agents(key),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'ok', 'failed', 'skipped')),
  summary text,
  error text,
  model text,
  tokens_in int not null default 0,
  tokens_out int not null default 0,
  cost_usd numeric(10,4) not null default 0
);
create index ai_agent_runs_agent_idx on public.ai_agent_runs (agent_key, started_at desc);

create table public.ai_items (
  id bigserial primary key,
  agent_key text not null references public.ai_agents(key),
  kind text not null check (kind in ('alert', 'recommendation', 'approval_request')),
  severity text not null default 'info' check (severity in ('info', 'low', 'medium', 'high', 'critical')),
  status text not null default 'open'
    check (status in ('open', 'pending_approval', 'more_info', 'approved', 'rejected', 'completed', 'failed', 'dismissed')),
  source text not null check (source in ('rule', 'ai')),
  title text not null check (char_length(title) between 3 and 200),
  body text check (body is null or char_length(body) <= 4000),
  evidence jsonb not null default '{}'::jsonb,
  -- Acción propuesta (solo si requiere aprobación): {"type": ..., "params": {...}}
  proposed_action jsonb,
  target_table text,
  target_id text,
  dedupe_key text unique,
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 1000),
  completed_at timestamptz,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'approval_request' or proposed_action is not null)
);
create index ai_items_status_idx on public.ai_items (status, severity, created_at desc);
create trigger ai_items_touch before update on public.ai_items
  for each row execute function public.touch_updated_at();

create table public.daily_reports (
  report_date date primary key,
  timezone text not null,
  generated_at timestamptz not null default now(),
  data jsonb not null
);

create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value) values
  -- Confirmado por el dueño: 6:00 AM hora de Miami.
  ('daily_report', '{"enabled": true, "timezone": "America/New_York", "hour": 6}'),
  -- Sin presupuesto, ningún agente puede llamar a un modelo de IA (lo fija el dueño).
  ('ai_budget', '{"monthly_usd": 0, "per_user_daily_requests": 30}');

-- Los agentes: los 18 del plan del dueño y los que agregó Claude.
insert into public.ai_agents (key, number, name, purpose, phase, status, needs, added_by_claude) values
  ('boss', 1, 'AI Boss / Director General', 'Coordina a los agentes, prioriza problemas, resume y pide decisiones al dueño.', 'A', 'rules', null, false),
  ('identity', 2, 'Identidad y verificación facial', 'Carnet (anverso y reverso), selfie con prueba de vida y comparación facial con un proveedor especializado. Resultado preliminar; decide una persona.', 'A', 'needs_setup', 'Elegir y contratar un proveedor de verificación de identidad.', false),
  ('background', 3, 'Antecedentes y documentos (Bolivia)', 'Lee REJAP, antecedentes policiales y certificados; revisa datos, fechas y códigos. Si no hay verificación oficial, queda "sin verificar" para revisión humana.', 'A', 'needs_setup', 'Clave del modelo de IA en Supabase y revisión legal de requisitos.', false),
  ('customer_assistant', 4, 'Asistente para clientes', 'Entiende el problema en español boliviano, sugiere categoría y opciones y prepara el pedido. Nunca lo envía sin el cliente.', 'A', 'needs_setup', 'Clave del modelo de IA en Supabase.', false),
  ('dispatch', 5, 'Asignación inteligente', 'Vigila pedidos ¡Ya! sin aceptar y sugiere ampliar la búsqueda. La base sigue decidiendo quién puede aceptar.', 'A', 'rules', null, false),
  ('pro_assistant', 6, 'Asistente para profesionales', 'Ayuda con el perfil, descripciones, cotizaciones y documentos faltantes, sin inventar credenciales ni precios.', 'B', 'planned', 'Clave del modelo de IA en Supabase.', false),
  ('support', 7, 'Soporte 24/7', 'Responde preguntas con datos reales de la cuenta, crea tickets y pasa a una persona cuando hace falta.', 'A', 'needs_setup', 'Clave del modelo de IA en Supabase.', false),
  ('wallet', 8, 'Billetera y pagos', 'Vigila recargas, comprobantes repetidos, saldos que no cuadran con el libro mayor y recargas atrasadas.', 'A', 'rules', null, false),
  ('finance', 9, 'Presupuesto y finanzas', 'Comisiones cobradas (ingreso real), separadas de las recargas; gastos y presupuesto cuando se registren.', 'B', 'rules', 'Registrar los gastos mensuales (Supabase, IA, tiendas, etc.).', false),
  ('qa', 10, 'Bug Hunter y calidad técnica', 'Errores de la app, pruebas fallidas y problemas tras cada versión. Prepara correcciones solo con autorización.', 'A', 'needs_setup', 'Servicio de reporte de errores (por ejemplo, Sentry).', false),
  ('fraud', 11, 'Fraude y seguridad', 'Reportes repetidos, acoso, fraude y pagos por fuera de la app. Distingue denuncias de hechos comprobados.', 'A', 'rules', null, false),
  ('marketing', 12, 'Marketing y crecimiento', 'Borradores de campañas y análisis de demanda. No publica ni gasta sin aprobación.', 'C', 'planned', null, false),
  ('recruitment', 13, 'Reclutamiento de profesionales', 'Faltantes por ciudad y categoría y postulaciones incompletas.', 'B', 'rules', null, false),
  ('quality', 14, 'Reseñas y calidad', 'Calificaciones bajas repetidas, reclamos y su resolución.', 'A', 'rules', null, false),
  ('launch', 15, 'Lanzamiento y cumplimiento', 'Requisitos de Google Play y App Store, pruebas y bloqueos de publicación.', 'A', 'rules', null, false),
  ('punctuality', 16, 'Puntualidad', 'Recordatorios del servidor, "Voy en camino", tiempo estimado y puntaje 0–100 con apelación.', 'B', 'planned', 'Notificaciones push.', false),
  ('daily_report', 17, 'Reporte diario', 'Reporte de las 6:00 AM (hora de Miami) solo con datos reales.', 'A', 'rules', null, false),
  ('performance', 18, 'Desempeño profesional', 'Historial verificable de cada profesional, con aviso, evidencia y apelación.', 'B', 'planned', null, false),
  ('disputes', 19, 'Mediación de disputas', 'Ordena la evidencia de cada disputa, propone soluciones y vigila plazos. Decide una persona.', 'A', 'rules', null, true),
  ('pricing', 20, 'Precios justos', 'Rangos de precio reales por categoría y ciudad para orientar y detectar cobros excesivos.', 'B', 'planned', 'Suficientes trabajos completados.', true),
  ('moderation', 21, 'Moderación de contenido', 'Revisa fotos, reseñas y mensajes reportados (Apple lo exige a apps con contenido de usuarios).', 'A', 'rules', null, true),
  ('privacy', 22, 'Privacidad y datos', 'Pedidos de eliminación de cuenta, retención de documentos y que la IA no reciba datos sensibles de más.', 'A', 'rules', null, true),
  ('invoicing', 23, 'Facturación e impuestos', 'Prepara la facturación de comisiones según Impuestos Nacionales. No emite nada sin aprobación.', 'B', 'planned', 'Revisión con un contador y acceso al sistema de facturación.', true),
  ('sos', 24, 'Seguridad en el servicio (SOS)', 'Botón de emergencia durante un trabajo y alertas inmediatas al equipo.', 'A', 'planned', 'Notificaciones push.', true),
  ('notifications', 25, 'Mensajería y avisos', 'Un solo canal para todos los avisos, con horarios, límites y sin spam.', 'A', 'needs_setup', 'iPhone: Apple (APNs). Android: WhatsApp o SMS enviados desde Supabase (servicio pagado; se activa con aprobación del dueño).', true),
  ('ai_auditor', 26, 'Auditor de IA', 'Vigila a los demás agentes: costos, fallas, intentos de manipulación y que lo "completado" sea real.', 'A', 'rules', null, true);

-- ---------------------------------------------------------------------------
-- RLS: solo administradores leen; nadie escribe directo desde la app
-- ---------------------------------------------------------------------------
alter table public.ai_agents enable row level security;
alter table public.ai_agent_runs enable row level security;
alter table public.ai_items enable row level security;
alter table public.daily_reports enable row level security;
alter table public.app_settings enable row level security;
create policy ai_agents_admin on public.ai_agents for select to authenticated using (public.is_admin());
create policy ai_agent_runs_admin on public.ai_agent_runs for select to authenticated using (public.is_admin());
create policy ai_items_admin on public.ai_items for select to authenticated using (public.is_admin());
create policy daily_reports_admin on public.daily_reports for select to authenticated using (public.is_admin());
create policy app_settings_admin on public.app_settings for select to authenticated using (public.is_admin());
revoke all on public.ai_agents, public.ai_agent_runs, public.ai_items, public.daily_reports, public.app_settings
  from anon, authenticated;
grant select on public.ai_agents, public.ai_agent_runs, public.ai_items, public.daily_reports, public.app_settings
  to authenticated;

-- ---------------------------------------------------------------------------
-- Funciones internas (las usan los monitores; la app no las llama)
-- ---------------------------------------------------------------------------
-- Crea un aviso una sola vez por dedupe_key (si ya existe abierto, no repite).
create function public.hmy_raise_item(p_agent text, p_kind text, p_severity text, p_source text, p_title text,
                                      p_body text, p_evidence jsonb, p_dedupe text,
                                      p_target_table text default null, p_target_id text default null,
                                      p_action jsonb default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into public.ai_items (agent_key, kind, severity, status, source, title, body, evidence, proposed_action,
                               target_table, target_id, dedupe_key)
  values (p_agent, p_kind, p_severity, case when p_kind = 'approval_request' then 'pending_approval' else 'open' end,
          p_source, p_title, p_body, coalesce(p_evidence, '{}'::jsonb), p_action, p_target_table, p_target_id, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

-- Revisión con reglas sobre datos reales (sin IA y sin costo). Corre cada hora.
create function public.run_marketplace_monitors()
returns int
language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- Reporte diario (solo datos reales; lo que no existe se marca "no disponible")
-- ---------------------------------------------------------------------------
create function public.hmy_day_metrics(p_from timestamptz, p_to timestamptz)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'commission_revenue_bs', (select coalesce(-sum(available_delta), 0) + coalesce(-sum(reserved_delta), 0)
                              from public.wallet_ledger where entry_type = 'commission_capture'
                                and created_at >= p_from and created_at < p_to),
    'commissions_captured', (select count(*) from public.wallet_ledger where entry_type = 'commission_capture'
                               and created_at >= p_from and created_at < p_to),
    'recharges_requested', (select count(*) from public.topup_requests where created_at >= p_from and created_at < p_to),
    'recharges_requested_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                 where created_at >= p_from and created_at < p_to),
    'recharges_approved', (select count(*) from public.topup_requests where status = 'approved'
                             and reviewed_at >= p_from and reviewed_at < p_to),
    'recharges_approved_bs', (select coalesce(sum(amount), 0) from public.topup_requests where status = 'approved'
                                and reviewed_at >= p_from and reviewed_at < p_to),
    'bookings_created', (select count(*) from public.bookings where created_at >= p_from and created_at < p_to),
    'bookings_completed', (select count(*) from public.bookings where completed_at >= p_from and completed_at < p_to),
    'bookings_cancelled', (select count(*) from public.bookings where cancelled_at >= p_from and cancelled_at < p_to),
    'disputes_opened', (select count(*) from public.disputes where created_at >= p_from and created_at < p_to),
    'new_customers', (select count(*) from public.profiles where created_at >= p_from and created_at < p_to),
    'new_applications', (select count(*) from public.professional_profiles
                           where submitted_at >= p_from and submitted_at < p_to),
    'professionals_approved', (select count(*) from public.professional_profiles
                                 where status = 'approved' and reviewed_at >= p_from and reviewed_at < p_to),
    'complaints', (select count(*) from public.user_reports where created_at >= p_from and created_at < p_to)
                  + (select count(*) from public.support_tickets where created_at >= p_from and created_at < p_to),
    'poor_reviews', (select count(*) from public.reviews where rating <= 2 and created_at >= p_from and created_at < p_to)
  )
$$;

create function public.generate_daily_report(p_date date, p_tz text)
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
end $$;

-- La llama un cron cada hora: genera el reporte de AYER cuando son las 6 en la zona elegida.
create function public.run_daily_report_if_due()
returns boolean
language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- Funciones del administrador
-- ---------------------------------------------------------------------------
create function public.admin_ai_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- Decidir sobre un aviso. Aprobar algo con consecuencias pide confirmar que es el dueño.
create function public.admin_decide_ai_item(p_item bigint, p_decision text, p_note text default null,
                                            p_auth_method text default null)
returns void
language plpgsql security definer set search_path = public as $$
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
end $$;

create function public.admin_set_setting(p_key text, p_value jsonb, p_auth_method text default null)
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
  else
    raise exception 'HMY_INVALID_SETTING';
  end if;
  update public.app_settings set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
  perform public.audit('settings.' || p_key, 'app_settings', p_key, p_value);
end $$;

create function public.admin_generate_daily_report(p_date date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tz text := coalesce((select value ->> 'timezone' from public.app_settings where key = 'daily_report'),
                              'America/New_York');
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.generate_daily_report(coalesce(p_date, (now() at time zone v_tz)::date - 1), v_tz);
end $$;

create function public.admin_run_monitors()
returns int
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.run_marketplace_monitors();
end $$;

revoke execute on function public.hmy_raise_item(text, text, text, text, text, text, jsonb, text, text, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.run_marketplace_monitors() from public, anon, authenticated;
revoke execute on function public.hmy_day_metrics(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.generate_daily_report(date, text) from public, anon, authenticated;
revoke execute on function public.run_daily_report_if_due() from public, anon, authenticated;
revoke execute on function public.admin_ai_overview() from public, anon;
revoke execute on function public.admin_decide_ai_item(bigint, text, text, text) from public, anon;
revoke execute on function public.admin_set_setting(text, jsonb, text) from public, anon;
revoke execute on function public.admin_generate_daily_report(date) from public, anon;
revoke execute on function public.admin_run_monitors() from public, anon;
grant execute on function public.admin_ai_overview(), public.admin_decide_ai_item(bigint, text, text, text),
  public.admin_set_setting(text, jsonb, text), public.admin_generate_daily_report(date), public.admin_run_monitors()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Programación (pg_cron, si el proyecto lo tiene): monitores y reporte cada hora.
-- En la base local de pruebas no existe y se omite.
-- ---------------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('hmy-monitors', '7 * * * *', 'select public.run_marketplace_monitors()');
    perform cron.schedule('hmy-daily-report', '2 * * * *', 'select public.run_daily_report_if_due()');
    raise notice 'Programación activada: monitores cada hora y reporte diario a las 6:00 de Miami.';
  else
    raise notice 'pg_cron no está disponible: los monitores y el reporte se pueden correr a mano desde el panel.';
  end if;
end $$;
