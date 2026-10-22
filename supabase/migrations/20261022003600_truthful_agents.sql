-- HandiMan ¡Ya! — 0036 Centro de Control IA: estado veraz de los agentes.
--
-- Pedido del dueño: nunca mostrar "Activo" sin una ejecución demostrable.
-- - Cada revisión deja una fila en ai_agent_runs POR AGENTE que de verdad
--   revisó algo (monitores, agentes con reglas, costos y reporte diario).
--   last_run_at solo cambia para esos agentes; antes se marcaban once de una
--   vez y las reglas y los costos no dejaban ningún registro.
-- - La última ejecución correcta sale solo de ai_agent_runs (admin_ai_agents).
-- - Estado sembrado corregido: lo que no se construyó queda "planned"; lo que
--   corre con reglas queda "rules"; ningún agente usa IA (presupuesto 0).
-- - El Auditor de IA ahora ve las fallas de todas las revisiones, los agentes
--   que dejaron de ejecutarse y el gasto de IA por encima del presupuesto.
-- - "Revisar ahora" corre las tres revisiones (admin_run_all_checks).
-- - Abrir un aviso muestra su origen y su historial (admin_ai_item_detail);
--   descartar o resolver exige una nota y queda en la auditoría.
-- Los agentes siguen sin aprobar profesionales, suspender cuentas, cambiar
-- saldos ni gastar dinero.

do $$ begin
  if to_regclass('public.ai_agents') is null or to_regprocedure('public.run_rule_agents()') is null then
    raise exception 'HMY: faltan las migraciones 0012 y 0018; no se aplicó nada.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ai_agents'
             and column_name = 'schedule') then
    raise exception 'HMY: la migración 0036 ya está aplicada; no se aplicó nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Cuándo corre cada agente
-- ---------------------------------------------------------------------------
-- schedule: texto para el panel. max_gap_minutes: si un agente con reglas pasa
-- más de esto sin una ejecución correcta, el Auditor avisa (null = no tiene
-- horario: corre por evento o no está construido).
alter table public.ai_agents add column schedule text, add column max_gap_minutes int
  check (max_gap_minutes is null or max_gap_minutes > 0);

-- Desde cuándo existe este registro por agente (para no avisar "no se ejecutó"
-- de agentes que antes no dejaban registro).
insert into public.app_settings (key, value) values ('agent_run_log', jsonb_build_object('since', now()))
on conflict (key) do nothing;

update public.ai_agents a
set status = v.status, purpose = v.purpose, needs = v.needs, schedule = v.schedule, max_gap_minutes = v.gap
from (values
  ('boss', 'rules',
   'Coordina la revisión de cada hora: la registra en el historial de ejecuciones, junta los avisos de los demás agentes en la bandeja y resume el resultado. No usa IA ni decide nada.',
   'Resúmenes redactados y priorización con IA: solo con presupuesto de IA autorizado.',
   'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('identity', 'needs_setup',
   'Verificación de identidad con Didit (carnet, prueba de vida y rostro) cuando el profesional la inicia. Resultado preliminar; decide una persona.',
   'Didit está solo en modo de pruebas (sandbox). El uso real necesita la autorización del dueño.',
   'Cuando el profesional inicia la verificación (sin horario)', null),
  ('background', 'rules',
   'Postulaciones esperando revisión más de 48 horas, profesionales aprobados sin carnet aceptado y documentos vencidos o por vencer en 30 días.',
   'La lectura de certificados (REJAP, antecedentes) la hace una persona; leerlos solo necesitaría IA pagada.',
   'Cada hora (minutos 7 y 17) y con "Revisar ahora"', 180),
  ('customer_assistant', 'planned',
   'Ayudaría al cliente a describir su problema y elegir la categoría. No está construido: hoy el cliente elige la categoría y el problema de una lista.',
   'Necesita IA para entender texto libre: solo con presupuesto autorizado.',
   null, null),
  ('dispatch', 'rules',
   'Avisa de pedidos ¡Ya! sin aceptar hace más de 15 minutos y sugiere ampliar la búsqueda. La base sigue decidiendo quién puede aceptar.',
   null, 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('pro_assistant', 'rules',
   'Le avisa una sola vez al profesional qué le falta para postular (oficio, carnet) cuando su borrador lleva 2 días sin documentos. No inventa credenciales ni precios.',
   'Redactar textos necesitaría IA pagada.', 'Cada hora (minuto 17) y con "Revisar ahora"', 180),
  ('support', 'rules',
   'Avisa de tickets de soporte sin respuesta hace más de 24 horas. Responde una persona.',
   'Responder solo (texto libre) necesitaría IA pagada: solo con presupuesto autorizado.',
   'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('wallet', 'rules',
   'Saldos que no cuadran con el libro mayor, recargas pendientes hace más de 24 horas y comprobantes repetidos. No cambia saldos ni aprueba recargas.',
   null, 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('finance', 'rules',
   'Uso de los planes gratis y cargos proyectados de cada proveedor; avisa antes de llegar a un tope y frena cualquier gasto no autorizado. Las comisiones cobradas salen en el reporte diario.',
   null, 'Cada hora (minuto 12) y con "Revisar ahora"', 180),
  ('qa', 'planned',
   'Vigilaría errores de la app y problemas tras cada versión. No está construido: las pruebas corren en GitHub, fuera de la app.',
   'Servicio de reporte de errores (por ejemplo, Sentry), con aprobación del dueño.', null, null),
  ('fraud', 'rules',
   'Reportes de acoso o fraude sin revisar y cuentas reportadas por 3 o más personas en 30 días. Son denuncias, no hechos comprobados; no suspende a nadie.',
   null, 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('marketing', 'planned',
   'Borradores de campañas y análisis de demanda. No está construido; no publicaría ni gastaría sin aprobación.',
   'Necesita IA: solo con presupuesto autorizado.', null, null),
  ('recruitment', 'planned',
   'Faltantes de profesionales por ciudad y categoría. No está construido: hoy no corre ninguna revisión.',
   'Definir las metas por ciudad y categoría.', null, null),
  ('quality', 'rules',
   'Dos o más calificaciones de 1 o 2 estrellas en 30 días para el mismo profesional. No castiga; avisa al equipo.',
   null, 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('launch', 'planned',
   'Requisitos de Google Play y App Store y bloqueos de publicación. No está construido: hoy no corre ninguna revisión.',
   'Las cuentas de las tiendas (pagadas, con aprobación del dueño).', null, null),
  ('punctuality', 'rules',
   'Atrasos repetidos según la llegada verificada con código (más de 15 minutos, 3 veces en 30 días). Solo avisa; no castiga.',
   null, 'Cada hora (minuto 17) y con "Revisar ahora"', 180),
  ('daily_report', 'rules',
   'Reporte diario solo con datos reales, a la hora que elige el dueño (hoy 6:00 de Miami). Lo que no se mide se dice.',
   null, 'Una vez al día a la hora elegida, o con "Generate now"', 1560),
  ('performance', 'planned',
   'Historial verificable de cada profesional, con aviso, evidencia y apelación. No está construido.', null, null, null),
  ('disputes', 'rules',
   'Avisa de disputas abiertas hace más de 48 horas. Ordenar la evidencia y proponer soluciones necesitaría IA; decide una persona.',
   null, 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('pricing', 'planned',
   'Rangos de precio reales por categoría y ciudad. No está construido.', 'Suficientes trabajos completados.', null, null),
  ('moderation', 'rules',
   'Avisa de contenido reportado como inapropiado para que el equipo decida si se oculta. No oculta nada por sí solo.',
   'Revisar fotos o textos sin reporte necesitaría IA pagada.', 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('privacy', 'rules',
   'Avisa de pedidos de eliminación de cuenta con más de 7 días sin atender.',
   'La retención de documentos todavía no se revisa sola.', 'Cada hora (minuto 7) y con "Revisar ahora"', 180),
  ('invoicing', 'planned',
   'Facturación de comisiones según Impuestos Nacionales. No está construido; no emitiría nada sin aprobación.',
   'Revisión con un contador y acceso al sistema de facturación.', null, null),
  ('service_safety', 'rules',
   'Trabajos "en camino" hace más de 3 horas sin llegada verificada y llegadas verificadas por el equipo. Pasa los casos al equipo; no es un servicio de emergencia.',
   'Notificaciones push para avisar al instante.', 'Cada hora (minuto 17) y con "Revisar ahora"', 180),
  ('notifications', 'planned',
   'Un solo canal para todos los avisos, con horarios y límites. No está construido: hoy los avisos quedan dentro de la app.',
   'iPhone: Apple (APNs). Android: push, WhatsApp o SMS (servicios con aprobación del dueño).', null, null),
  ('ai_auditor', 'rules',
   'Vigila a los demás agentes: ejecuciones fallidas en 24 horas (monitores, reglas, costos y reporte), agentes con reglas que dejaron de ejecutarse y gasto de IA por encima del presupuesto.',
   'Detectar manipulación de una IA solo hará falta cuando un agente use IA.', 'Cada hora (minuto 7) y con "Revisar ahora"', 180)
) as v(key, status, purpose, needs, schedule, gap)
where a.key = v.key;

-- ---------------------------------------------------------------------------
-- Registro de ejecuciones (interno)
-- ---------------------------------------------------------------------------
create function public.hmy_log_agent_run(p_agent text, p_started timestamptz, p_status text, p_summary text,
                                         p_error text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ai_agent_runs (agent_key, started_at, finished_at, status, summary, error)
  values (p_agent, p_started, clock_timestamp(), p_status, left(p_summary, 300), left(p_error, 40));
  update public.ai_agents set last_run_at = clock_timestamp(), last_run_status = p_status where key = p_agent;
end $$;

-- Una revisión correcta: cuenta los avisos nuevos del agente desde p_after.
create function public.hmy_agent_run_ok(p_agent text, p_started timestamptz, p_after bigint, p_rules int)
returns int
language plpgsql security definer set search_path = public as $$
declare n int := (select count(*) from public.ai_items where agent_key = p_agent and id > p_after);
begin
  perform public.hmy_log_agent_run(p_agent, p_started, 'ok',
    format('%s regla(s) revisada(s); %s aviso(s) nuevo(s)', p_rules, n));
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Monitores de cada hora: una fila por agente; si una regla falla, se
-- registra la falla (solo el código) y los demás agentes siguen.
-- ---------------------------------------------------------------------------
create or replace function public.run_marketplace_monitors()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_run bigint;
  v_after bigint := (select coalesce(max(id), 0) from public.ai_items);
  v_t timestamptz;
  v_failed text[] := '{}';
  v_since timestamptz := coalesce((select (value ->> 'since')::timestamptz from public.app_settings
                                   where key = 'agent_run_log'), now());
  v_new int;
  r record;
begin
  insert into public.ai_agent_runs (agent_key, started_at, status) values ('boss', clock_timestamp(), 'running')
  returning id into v_run;

  -- Billetera y pagos (3 reglas).
  v_t := clock_timestamp();
  begin
    for r in
      select w.professional_id, w.available, coalesce(sum(l.available_delta), 0) as ledger_sum
      from public.wallets w left join public.wallet_ledger l on l.professional_id = w.professional_id
      group by w.professional_id, w.available
      having w.available <> coalesce(sum(l.available_delta), 0)
    loop
      perform public.hmy_raise_item('wallet', 'alert', 'critical', 'rule', 'Saldo que no cuadra con el libro mayor',
        format('La billetera muestra %s Bs disponibles, pero el libro mayor suma %s Bs.', r.available, r.ledger_sum),
        jsonb_build_object('professional_id', r.professional_id, 'available', r.available, 'ledger_sum', r.ledger_sum),
        'wallet-mismatch:' || r.professional_id || ':' || r.available, 'wallets', r.professional_id::text);
    end loop;
    for r in select id, amount, created_at from public.topup_requests
             where status = 'pending' and created_at < now() - interval '24 hours' loop
      perform public.hmy_raise_item('wallet', 'alert', 'medium', 'rule', 'Recarga esperando verificación hace más de 24 horas',
        format('Recarga N.º %s de %s Bs, pedida el %s.', r.id, r.amount, to_char(r.created_at, 'YYYY-MM-DD HH24:MI')),
        jsonb_build_object('topup_id', r.id, 'amount', r.amount), 'topup-late:' || r.id, 'topup_requests', r.id::text);
    end loop;
    for r in select lower(trim(reference)) as ref, array_agg(id order by id) as ids, count(distinct professional_id) as pros
             from public.topup_requests where reference is not null and trim(reference) <> '' and status <> 'rejected'
             group by lower(trim(reference)) having count(*) > 1 loop
      perform public.hmy_raise_item('wallet', 'alert', 'high', 'rule', 'Comprobante repetido en varias recargas',
        format('El comprobante "%s" aparece en las recargas %s (%s profesional(es)). Revisa antes de aprobar.',
               r.ref, array_to_string(r.ids, ', '), r.pros),
        jsonb_build_object('reference', r.ref, 'topup_ids', r.ids), 'topup-dup:' || r.ref || ':' || array_to_string(r.ids, ','),
        'topup_requests', r.ids[1]::text);
    end loop;
    perform public.hmy_agent_run_ok('wallet', v_t, v_after, 3);
  exception when others then
    v_failed := v_failed || 'wallet'::text;
    perform public.hmy_log_agent_run('wallet', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Asignación inteligente (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select b.id, b.code, c.name as city, sc.name as category, b.created_at
             from public.bookings b join public.cities c on c.id = b.city_id
             join public.service_categories sc on sc.id = b.category_id
             where b.mode = 'now' and b.professional_id is null and b.status in ('requested', 'awaiting_response')
               and b.created_at < now() - interval '15 minutes' loop
      perform public.hmy_raise_item('dispatch', 'recommendation', 'medium', 'rule', 'Pedido ¡Ya! sin profesional',
        format('Pedido %s de %s en %s, sin aceptar desde %s. Sugerencia: ampliar el radio o avisar a más profesionales.',
               r.code, r.category, r.city, to_char(r.created_at, 'HH24:MI')),
        jsonb_build_object('booking_id', r.id), 'ya-unaccepted:' || r.id, 'bookings', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('dispatch', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'dispatch'::text;
    perform public.hmy_log_agent_run('dispatch', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Antecedentes y documentos: postulaciones atrasadas (1 regla; las demás en run_rule_agents).
  v_t := clock_timestamp();
  begin
    for r in select user_id, display_name, submitted_at from public.professional_profiles
             where status in ('submitted', 'under_review') and submitted_at < now() - interval '48 hours' loop
      perform public.hmy_raise_item('background', 'alert', 'medium', 'rule', 'Postulación esperando revisión más de 48 horas',
        format('%s envió su postulación el %s.', coalesce(nullif(r.display_name, ''), 'Un profesional'),
               to_char(r.submitted_at, 'YYYY-MM-DD')),
        jsonb_build_object('professional_id', r.user_id), 'application-late:' || r.user_id || ':' || r.submitted_at::date,
        'professional_profiles', r.user_id::text);
    end loop;
    perform public.hmy_agent_run_ok('background', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'background'::text;
    perform public.hmy_log_agent_run('background', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Reseñas y calidad (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select professional_id, count(*) as n from public.reviews
             where rating <= 2 and created_at > now() - interval '30 days' group by professional_id having count(*) >= 2 loop
      perform public.hmy_raise_item('quality', 'alert', 'medium', 'rule', 'Calificaciones bajas repetidas',
        format('%s calificaciones de 1 o 2 estrellas en los últimos 30 días.', r.n),
        jsonb_build_object('professional_id', r.professional_id, 'low_reviews_30d', r.n),
        'low-reviews:' || r.professional_id || ':' || r.n, 'professional_profiles', r.professional_id::text);
    end loop;
    perform public.hmy_agent_run_ok('quality', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'quality'::text;
    perform public.hmy_log_agent_run('quality', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Fraude y seguridad (2 reglas).
  v_t := clock_timestamp();
  begin
    for r in select id, reported_id, reason from public.user_reports
             where status = 'open' and reason in ('acoso', 'fraude') loop
      perform public.hmy_raise_item('fraud', 'alert', 'high', 'rule',
        case when r.reason = 'acoso' then 'Reporte de acoso sin revisar' else 'Reporte de fraude sin revisar' end,
        'Es una denuncia, todavía no un hecho comprobado. Revísala en Reportes.',
        jsonb_build_object('report_id', r.id, 'reported_id', r.reported_id), 'report-serious:' || r.id,
        'user_reports', r.id::text);
    end loop;
    for r in select reported_id, count(distinct reporter_id) as n from public.user_reports
             where created_at > now() - interval '30 days' group by reported_id having count(distinct reporter_id) >= 3 loop
      perform public.hmy_raise_item('fraud', 'alert', 'high', 'rule', 'Cuenta reportada por varias personas',
        format('%s personas distintas reportaron esta cuenta en 30 días.', r.n),
        jsonb_build_object('reported_id', r.reported_id, 'reporters_30d', r.n), 'many-reports:' || r.reported_id || ':' || r.n,
        'profiles', r.reported_id::text);
    end loop;
    perform public.hmy_agent_run_ok('fraud', v_t, v_after, 2);
  exception when others then
    v_failed := v_failed || 'fraud'::text;
    perform public.hmy_log_agent_run('fraud', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Mediación de disputas (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select d.id, b.code, d.created_at from public.disputes d join public.bookings b on b.id = d.booking_id
             where d.status = 'open' and d.created_at < now() - interval '48 hours' loop
      perform public.hmy_raise_item('disputes', 'alert', 'high', 'rule', 'Disputa abierta hace más de 48 horas',
        format('Pedido %s, disputa abierta el %s.', r.code, to_char(r.created_at, 'YYYY-MM-DD')),
        jsonb_build_object('dispute_id', r.id), 'dispute-late:' || r.id, 'disputes', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('disputes', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'disputes'::text;
    perform public.hmy_log_agent_run('disputes', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Soporte (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select id, subject from public.support_tickets where status = 'open' and created_at < now() - interval '24 hours' loop
      perform public.hmy_raise_item('support', 'alert', 'medium', 'rule', 'Ticket de soporte sin respuesta hace más de 24 horas',
        r.subject, jsonb_build_object('ticket_id', r.id), 'ticket-late:' || r.id, 'support_tickets', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('support', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'support'::text;
    perform public.hmy_log_agent_run('support', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Privacidad (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select id, deletion_requested_at from public.profiles
             where deletion_requested_at is not null and deletion_requested_at < now() - interval '7 days' loop
      perform public.hmy_raise_item('privacy', 'alert', 'medium', 'rule', 'Pedido de eliminación de cuenta pendiente',
        format('Pedido el %s. Hay que atenderlo y responder al usuario.', to_char(r.deletion_requested_at, 'YYYY-MM-DD')),
        jsonb_build_object('user_id', r.id), 'deletion-late:' || r.id, 'profiles', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('privacy', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'privacy'::text;
    perform public.hmy_log_agent_run('privacy', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Moderación (1 regla).
  v_t := clock_timestamp();
  begin
    for r in select id, reported_id from public.user_reports where status = 'open' and reason = 'contenido_inapropiado' loop
      perform public.hmy_raise_item('moderation', 'alert', 'medium', 'rule', 'Contenido inapropiado reportado',
        'Revisa el contenido y decide si se oculta.', jsonb_build_object('report_id', r.id, 'reported_id', r.reported_id),
        'report-content:' || r.id, 'user_reports', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('moderation', v_t, v_after, 1);
  exception when others then
    v_failed := v_failed || 'moderation'::text;
    perform public.hmy_log_agent_run('moderation', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Auditor de IA (3 reglas), al final para ver las fallas de esta misma revisión.
  v_t := clock_timestamp();
  begin
    -- Ejecuciones fallidas en 24 horas, de cualquier revisión (monitores, reglas, costos, reporte).
    for r in select agent_key, count(*) as n from public.ai_agent_runs
             where status = 'failed' and started_at > now() - interval '24 hours' group by agent_key loop
      perform public.hmy_raise_item('ai_auditor', 'alert', 'medium', 'rule', 'Un agente falló en las últimas 24 horas',
        format('El agente "%s" falló %s vez/veces.', r.agent_key, r.n),
        jsonb_build_object('agent_key', r.agent_key, 'failures_24h', r.n),
        'agent-failed:' || r.agent_key || ':' || current_date, 'ai_agents', r.agent_key);
    end loop;
    -- Agentes con reglas y horario que dejaron de ejecutarse (por ejemplo, si se apagó la programación).
    for r in select a.key, a.name, a.max_gap_minutes,
                    (select max(finished_at) from public.ai_agent_runs x where x.agent_key = a.key and x.status = 'ok') as last_ok
             from public.ai_agents a
             where a.status in ('rules', 'ai') and a.max_gap_minutes is not null and a.key not in ('boss', 'ai_auditor')
               and not (a.key = 'daily_report' and not coalesce((select (value ->> 'enabled')::boolean
                                                                  from public.app_settings where key = 'daily_report'), false)) loop
      if coalesce(r.last_ok, v_since) < now() - make_interval(mins => r.max_gap_minutes) then
        perform public.hmy_raise_item('ai_auditor', 'alert', 'medium', 'rule', 'Un agente dejó de ejecutarse',
          format('"%s" no tiene una ejecución correcta desde %s. Revisa la programación de las revisiones.', r.name,
                 coalesce(to_char(r.last_ok, 'YYYY-MM-DD HH24:MI'), 'que existe este registro')),
          jsonb_build_object('agent_key', r.key, 'last_ok_run', r.last_ok, 'max_gap_minutes', r.max_gap_minutes),
          'agent-stale:' || r.key || ':' || current_date, 'ai_agents', r.key);
      end if;
    end loop;
    -- Gasto de IA del mes por encima del presupuesto aprobado.
    for r in select coalesce(sum(cost_usd), 0) as spent,
                    coalesce((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget'), 0) as budget
             from public.ai_agent_runs where started_at >= date_trunc('month', now()) loop
      if r.spent > r.budget then
        perform public.hmy_raise_item('ai_auditor', 'alert', 'high', 'rule', 'Gasto de IA por encima del presupuesto',
          format('Este mes se registraron US$ %s de IA con un presupuesto de US$ %s.', r.spent, r.budget),
          jsonb_build_object('spent_usd', r.spent, 'budget_usd', r.budget),
          'ai-over-budget:' || to_char(now(), 'YYYY-MM'), 'app_settings', 'ai_budget');
      end if;
    end loop;
    perform public.hmy_agent_run_ok('ai_auditor', v_t, v_after, 3);
  exception when others then
    v_failed := v_failed || 'ai_auditor'::text;
    perform public.hmy_log_agent_run('ai_auditor', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- El AI Boss registra la revisión completa.
  v_new := (select count(*) from public.ai_items where id > v_after);
  update public.ai_agent_runs set status = 'ok', finished_at = clock_timestamp(),
    summary = format('Revisión de 10 agentes; %s aviso(s) nuevo(s)%s', v_new,
                     case when cardinality(v_failed) > 0 then '; fallaron: ' || array_to_string(v_failed, ', ') else '' end)
  where id = v_run;
  update public.ai_agents set last_run_at = clock_timestamp(), last_run_status = 'ok' where key = 'boss';
  return v_new;
end $$;

-- ---------------------------------------------------------------------------
-- Agentes con reglas (0018): mismas reglas, una fila por agente.
-- ---------------------------------------------------------------------------
create or replace function public.run_rule_agents()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_after bigint := (select coalesce(max(id), 0) from public.ai_items);
  v_t timestamptz;
  r record;
begin
  -- Seguridad en el servicio (2 reglas).
  v_t := clock_timestamp();
  begin
    for r in
      select b.id, b.code, b.professional_id, max(e.created_at) as since
      from public.bookings b
      join public.booking_events e on e.booking_id = b.id and e.to_status = 'on_the_way'
      where b.status = 'on_the_way'
      group by b.id
      having max(e.created_at) < now() - interval '3 hours'
    loop
      perform public.hmy_raise_item('service_safety', 'alert', 'high', 'rule',
        format('Pedido %s: "en camino" hace más de 3 horas sin llegada verificada', r.code),
        'Llama al cliente y al profesional para confirmar que todo está bien.',
        jsonb_build_object('booking_id', r.id, 'since', r.since), 'trip-stuck:' || r.id,
        'bookings', r.id::text);
    end loop;
    for r in
      select a.booking_id, b.code, a.admin_reason
      from public.booking_arrivals a join public.bookings b on b.id = a.booking_id
      where a.method = 'admin' and a.verified_at > now() - interval '7 days'
    loop
      perform public.hmy_raise_item('service_safety', 'alert', 'low', 'rule',
        format('Pedido %s: llegada verificada por el equipo, sin código', r.code),
        format('Motivo registrado: %s', r.admin_reason),
        jsonb_build_object('booking_id', r.booking_id), 'arrival-admin:' || r.booking_id,
        'bookings', r.booking_id::text);
    end loop;
    perform public.hmy_agent_run_ok('service_safety', v_t, v_after, 2);
  exception when others then
    perform public.hmy_log_agent_run('service_safety', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Puntualidad (1 regla).
  v_t := clock_timestamp();
  begin
    for r in
      select b.professional_id, count(*) as late, round(avg(a.delay_minutes)) as avg_delay
      from public.booking_arrivals a join public.bookings b on b.id = a.booking_id
      where a.delay_minutes > 15 and a.verified_at > now() - interval '30 days'
      group by b.professional_id
      having count(*) >= 3
    loop
      perform public.hmy_raise_item('punctuality', 'alert', 'medium', 'rule', 'Atrasos repetidos',
        format('%s llegadas con más de 15 minutos de atraso en 30 días (promedio %s min).', r.late, r.avg_delay),
        jsonb_build_object('professional_id', r.professional_id, 'late', r.late),
        format('late:%s:%s', r.professional_id, to_char(now(), 'IYYY-IW')),
        'professional_profiles', r.professional_id::text);
    end loop;
    perform public.hmy_agent_run_ok('punctuality', v_t, v_after, 1);
  exception when others then
    perform public.hmy_log_agent_run('punctuality', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Antecedentes y documentos (2 reglas).
  v_t := clock_timestamp();
  begin
    for r in
      select pp.user_id, pp.display_name
      from public.professional_profiles pp
      where pp.status = 'approved'
        and not exists (select 1 from public.professional_documents d
                        where d.professional_id = pp.user_id and d.doc_type = 'ci_anverso' and d.status = 'accepted')
    loop
      perform public.hmy_raise_item('background', 'alert', 'high', 'rule', 'Profesional aprobado sin carnet aceptado',
        format('%s está aprobado, pero su carnet no figura como aceptado. Revisa los documentos.', r.display_name),
        jsonb_build_object('professional_id', r.user_id), 'no-ci:' || r.user_id,
        'professional_profiles', r.user_id::text);
    end loop;
    for r in
      select d.id, d.professional_id, d.doc_type, d.expires_on, pp.display_name
      from public.professional_documents d
      join public.professional_profiles pp on pp.user_id = d.professional_id and pp.status = 'approved'
      where d.status = 'accepted' and d.expires_on is not null and d.expires_on < current_date + 30
    loop
      perform public.hmy_raise_item('background', 'alert', case when r.expires_on < current_date then 'high' else 'medium' end,
        'rule',
        format('%s: documento %s %s', r.display_name, r.doc_type,
               case when r.expires_on < current_date then 'vencido' else 'por vencer' end),
        format('Vence el %s. Pide el documento actualizado.', to_char(r.expires_on, 'DD/MM/YYYY')),
        jsonb_build_object('document_id', r.id, 'expires_on', r.expires_on),
        format('doc-expiry:%s:%s', r.id, case when r.expires_on < current_date then 'expired' else 'soon' end),
        'professional_documents', r.id::text);
    end loop;
    perform public.hmy_agent_run_ok('background', v_t, v_after, 2);
  exception when others then
    perform public.hmy_log_agent_run('background', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  -- Asistente para profesionales (1 regla): se le avisa una sola vez qué falta.
  v_t := clock_timestamp();
  begin
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
      end if;
    end loop;
    perform public.hmy_agent_run_ok('pro_assistant', v_t, v_after, 1);
  exception when others then
    perform public.hmy_log_agent_run('pro_assistant', v_t, 'failed', 'La revisión falló', sqlstate);
  end;

  return (select count(*) from public.ai_items where id > v_after);
end $$;

-- ---------------------------------------------------------------------------
-- Monitor de costos (0016): ahora deja su fila de ejecución.
-- ---------------------------------------------------------------------------
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
        'Costos: ' || left(a ->> 'message', 180), a ->> 'message', a,
        format('cost:%s:%s:%s', a ->> 'vendor', a ->> 'level', v_month), 'cost_vendors', a ->> 'vendor');
    end loop;
    return public.hmy_agent_run_ok('finance', v_t, v_after, 1);
  exception when others then
    perform public.hmy_log_agent_run('finance', v_t, 'failed', 'La revisión falló', sqlstate);
    return 0;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Reporte diario: contaba un agente 'sos' que no existe; la seguridad en el
-- servicio es 'service_safety'. La puntualidad ya se mide (llegada con código)
-- pero todavía no sale en el reporte.
-- ---------------------------------------------------------------------------
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
end $$;

create or replace function public.run_daily_report_if_due()
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  s jsonb := (select value from public.app_settings where key = 'daily_report');
  v_tz text := coalesce(s ->> 'timezone', 'America/New_York');
  v_local timestamp := now() at time zone v_tz;
  v_t timestamptz := clock_timestamp();
begin
  if not coalesce((s ->> 'enabled')::boolean, false) then return false; end if;
  if extract(hour from v_local) <> coalesce((s ->> 'hour')::int, 6) then return false; end if;
  if exists (select 1 from public.daily_reports where report_date = v_local::date - 1
             and generated_at > now() - interval '20 hours') then
    return false;
  end if;
  begin
    perform public.generate_daily_report(v_local::date - 1, v_tz);
    perform public.hmy_log_agent_run('daily_report', v_t, 'ok', 'Reporte del ' || (v_local::date - 1));
  exception when others then
    perform public.hmy_log_agent_run('daily_report', v_t, 'failed', 'El reporte falló', sqlstate);
  end;
  return true;
end $$;

-- Generarlo a pedido también es una ejecución y queda registrada.
create or replace function public.admin_generate_daily_report(p_date date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tz text := coalesce((select value ->> 'timezone' from public.app_settings where key = 'daily_report'),
                        'America/New_York');
  v_date date;
  v_t timestamptz := clock_timestamp();
  v_data jsonb;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  v_date := coalesce(p_date, (now() at time zone v_tz)::date - 1);
  v_data := public.generate_daily_report(v_date, v_tz);
  perform public.hmy_log_agent_run('daily_report', v_t, 'ok', 'Reporte del ' || v_date || ' (a pedido)');
  return v_data;
end $$;

-- ---------------------------------------------------------------------------
-- "Revisar ahora": las tres revisiones, en orden (el Auditor va al final).
-- ---------------------------------------------------------------------------
create function public.admin_run_all_checks()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rules int;
  v_costs int;
  v_monitors int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  v_rules := public.run_rule_agents();
  v_costs := public.run_cost_monitors();
  v_monitors := public.run_marketplace_monitors();
  perform public.audit('ai.run_checks', 'ai_agent_runs', null,
                       jsonb_build_object('rules', v_rules, 'costs', v_costs, 'monitors', v_monitors));
  return jsonb_build_object('rules', v_rules, 'costs', v_costs, 'monitors', v_monitors,
                            'total', v_rules + v_costs + v_monitors,
                            'failed', (select count(*) from public.ai_agent_runs
                                       where status = 'failed' and started_at >= now()));
end $$;

-- ---------------------------------------------------------------------------
-- Lo que ve el panel
-- ---------------------------------------------------------------------------
-- Agentes con su última ejecución, tomada SOLO del historial (ai_agent_runs).
-- execution: active (ejecución correcta dentro de su horario), stale (la
-- última correcta es vieja), failed (la última falló), never (sin
-- ejecuciones), event (corre por evento, sin horario), needs_setup,
-- not_built, off.
create function public.admin_ai_agents()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.number), '[]'::jsonb) from (
      select a.key, a.number, a.name, a.purpose, a.phase, a.status, a.needs, a.added_by_claude, a.schedule,
             a.max_gap_minutes, l.started_at as last_run_at, l.status as last_run_status, l.summary as last_summary,
             l.error as last_error, k.finished_at as last_ok_run_at,
             (select count(*) from public.ai_agent_runs x where x.agent_key = a.key and x.status = 'ok'
                and x.started_at > now() - interval '24 hours') as runs_ok_24h,
             (select count(*) from public.ai_agent_runs x where x.agent_key = a.key and x.status = 'failed'
                and x.started_at > now() - interval '24 hours') as runs_failed_24h,
             (select count(*) from public.ai_items i where i.agent_key = a.key
                and i.status in ('open', 'more_info', 'pending_approval')) as open_items,
             case
               when a.status = 'off' then 'off'
               when a.status = 'planned' then 'not_built'
               when a.status = 'needs_setup' then 'needs_setup'
               when l.status = 'failed' then 'failed'
               when k.finished_at is null then case when a.max_gap_minutes is null then 'event' else 'never' end
               when a.max_gap_minutes is not null and k.finished_at < now() - make_interval(mins => a.max_gap_minutes) then 'stale'
               else 'active'
             end as execution
      from public.ai_agents a
      left join lateral (select started_at, status, summary, error from public.ai_agent_runs r
                         where r.agent_key = a.key and r.status <> 'running' order by r.id desc limit 1) l on true
      left join lateral (select finished_at from public.ai_agent_runs r
                         where r.agent_key = a.key and r.status = 'ok' order by r.id desc limit 1) k on true
    ) x);
end $$;

-- Un aviso con su origen (agente, regla, registro, hora) y su historial.
create function public.admin_ai_item_detail(p_item bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  i public.ai_items;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into i from public.ai_items where id = p_item;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  return to_jsonb(i) || jsonb_build_object(
    'rule', split_part(i.dedupe_key, ':', 1),
    'agent_name', (select name from public.ai_agents where key = i.agent_key),
    'agent_number', (select number from public.ai_agents where key = i.agent_key),
    'decided_by_name', (select full_name from public.profiles where id = i.decided_by),
    'history', (select coalesce(jsonb_agg(jsonb_build_object(
                  'action', l.action, 'actor_name', coalesce(p.full_name, 'Sistema'),
                  'note', l.details ->> 'note', 'created_at', l.created_at) order by l.created_at, l.id), '[]'::jsonb)
                from public.admin_audit_log l left join public.profiles p on p.id = l.actor_id
                where l.target_table = 'ai_items' and l.target_id = p_item::text));
end $$;

create or replace function public.admin_ai_overview()
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
    'last_monitor_run', (select max(finished_at) from public.ai_agent_runs where agent_key = 'boss' and status = 'ok'),
    'runs_ok_24h', (select count(*) from public.ai_agent_runs where status = 'ok' and started_at > now() - interval '24 hours'),
    'runs_failed_24h', (select count(*) from public.ai_agent_runs where status = 'failed' and started_at > now() - interval '24 hours')
  );
end $$;

-- Decidir sobre un aviso. Rechazar, descartar o marcar el resultado exige una
-- nota (queda en la auditoría). Aprobar algo con consecuencias pide confirmar
-- que es el dueño; aprobar no ejecuta nada por sí solo.
create or replace function public.admin_decide_ai_item(p_item bigint, p_decision text, p_note text default null,
                                                       p_auth_method text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  i public.ai_items;
  v_note text := nullif(trim(p_note), '');
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into i from public.ai_items where id = p_item for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if i.status in ('approved', 'rejected', 'completed', 'failed', 'dismissed') and p_decision not in ('completed', 'failed') then
    raise exception 'HMY_ALREADY_REVIEWED';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then raise exception 'HMY_INVALID_SETTING'; end if;
  if p_decision = 'approve' then
    if i.status <> 'pending_approval' then raise exception 'HMY_INVALID_STATUS'; end if;
    perform public.hmy_require_confirmation(p_auth_method, 'ai.approve');
    update public.ai_items set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_note = v_note
    where id = p_item;
  elsif p_decision in ('reject', 'more_info', 'dismiss') then
    if p_decision = 'dismiss' and i.kind = 'approval_request' then raise exception 'HMY_INVALID_STATUS'; end if;
    if p_decision <> 'more_info' and coalesce(char_length(v_note), 0) < 3 then raise exception 'HMY_NOTE_REQUIRED'; end if;
    update public.ai_items
    set status = case p_decision when 'reject' then 'rejected' when 'more_info' then 'more_info' else 'dismissed' end,
        decided_by = auth.uid(), decided_at = now(), decision_note = coalesce(v_note, decision_note)
    where id = p_item;
  elsif p_decision in ('completed', 'failed') then
    -- Marcar el resultado de algo ya hecho a mano (o aprobado y ejecutado).
    if i.kind = 'approval_request' and i.status <> 'approved' then raise exception 'HMY_INVALID_STATUS'; end if;
    if i.status in ('completed', 'failed', 'rejected', 'dismissed') then raise exception 'HMY_ALREADY_REVIEWED'; end if;
    if coalesce(char_length(v_note), 0) < 3 then raise exception 'HMY_NOTE_REQUIRED'; end if;
    update public.ai_items set status = p_decision, completed_at = case when p_decision = 'completed' then now() end,
      decided_by = coalesce(decided_by, auth.uid()), decided_at = coalesce(decided_at, now()),
      decision_note = coalesce(decision_note, v_note),
      result = jsonb_build_object('note', v_note, 'by', auth.uid())
    where id = p_item;
  else
    raise exception 'HMY_INVALID_STATUS';
  end if;
  perform public.audit('ai_item.' || p_decision, 'ai_items', p_item::text,
                       jsonb_build_object('note', v_note, 'auth_method', p_auth_method, 'title', i.title));
end $$;

-- ---------------------------------------------------------------------------
-- last_run_at veraz: solo lo que figura en el historial de ejecuciones.
-- ---------------------------------------------------------------------------
update public.ai_agents a
set last_run_at = (select max(coalesce(finished_at, started_at)) from public.ai_agent_runs r
                   where r.agent_key = a.key and r.status <> 'running'),
    last_run_status = (select status from public.ai_agent_runs r where r.agent_key = a.key and r.status <> 'running'
                       order by r.id desc limit 1);

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_log_agent_run(text, timestamptz, text, text, text) from public, anon, authenticated;
revoke execute on function public.hmy_agent_run_ok(text, timestamptz, bigint, int) from public, anon, authenticated;
revoke execute on function public.run_marketplace_monitors() from public, anon, authenticated;
revoke execute on function public.run_rule_agents() from public, anon, authenticated;
revoke execute on function public.run_cost_monitors() from public, anon, authenticated;
revoke execute on function public.generate_daily_report(date, text) from public, anon, authenticated;
revoke execute on function public.run_daily_report_if_due() from public, anon, authenticated;
grant execute on function public.hmy_log_agent_run(text, timestamptz, text, text, text),
  public.hmy_agent_run_ok(text, timestamptz, bigint, int), public.run_marketplace_monitors(), public.run_rule_agents(),
  public.run_cost_monitors(), public.run_daily_report_if_due() to service_role;
revoke execute on function public.admin_run_all_checks() from public, anon;
revoke execute on function public.admin_ai_agents() from public, anon;
revoke execute on function public.admin_ai_item_detail(bigint) from public, anon;
revoke execute on function public.admin_ai_overview() from public, anon;
revoke execute on function public.admin_decide_ai_item(bigint, text, text, text) from public, anon;
revoke execute on function public.admin_generate_daily_report(date) from public, anon;
grant execute on function public.admin_run_all_checks(), public.admin_ai_agents(), public.admin_ai_item_detail(bigint),
  public.admin_ai_overview(), public.admin_decide_ai_item(bigint, text, text, text), public.admin_generate_daily_report(date)
  to authenticated;
