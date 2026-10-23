-- HandiMan ¡Ya! — 0018 más agentes con reglas (sin IA pagada).
--
-- Decisión del dueño: usar reglas donde funcionan de forma confiable, sin
-- llamadas a modelos pagados. Estos cuatro pasan a funcionar con reglas sobre
-- datos reales; los que necesitan entender texto libre (asistente para
-- clientes, soporte 24/7, marketing) siguen esperando un presupuesto de IA.
-- Ninguna regla aprueba, rechaza ni suspende a nadie: avisan al equipo.

create function public.run_rule_agents()
returns int
language plpgsql security definer set search_path = public as $$
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
end $$;

create function public.admin_run_rule_agents()
returns int
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.run_rule_agents();
end $$;

update public.ai_agents set status = 'rules', needs = 'Notificaciones push para avisar al instante.',
  purpose = 'Vigila trabajos "en camino" por horas sin llegada verificada, llegadas verificadas por el equipo y reportes de seguridad; pasa los casos graves al equipo.'
where key = 'service_safety';
update public.ai_agents set status = 'rules', needs = null,
  purpose = 'Atrasos repetidos según la llegada verificada con código (más de 15 minutos, 3 veces en 30 días). Solo avisa; no castiga.'
where key = 'punctuality';
update public.ai_agents set status = 'rules',
  needs = 'La lectura de certificados (REJAP, antecedentes) la hace una persona; leerlos solo necesitaría IA pagada.',
  purpose = 'Documentos vencidos o por vencer y profesionales aprobados sin carnet aceptado. Los antecedentes se revisan aparte de la verificación de identidad.'
where key = 'background';
update public.ai_agents set status = 'rules', needs = 'Redactar textos necesitaría IA pagada.',
  purpose = 'Avisa al profesional qué le falta para postular (oficio, carnet). No inventa credenciales ni precios.'
where key = 'pro_assistant';
update public.ai_agents set needs = 'Necesita IA para entender texto libre: solo con presupuesto autorizado. Mientras tanto, el cliente elige la categoría.'
where key = 'customer_assistant';
update public.ai_agents set needs = 'Necesita IA para responder texto libre: solo con presupuesto autorizado. Mientras tanto, responde una persona.'
where key = 'support';

revoke execute on function public.run_rule_agents() from public, anon, authenticated;
revoke execute on function public.admin_run_rule_agents() from public, anon;
grant execute on function public.admin_run_rule_agents() to authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hmy-rule-agents', '17 * * * *', 'select public.run_rule_agents()');
  end if;
end $$;
