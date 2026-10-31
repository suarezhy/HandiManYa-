-- 0045: avisos push (Firebase Cloud Messaging; el iPhone recibe por FCM con la
-- clave APNs cargada en Firebase). Aprobado por el dueño el 23-10-2026.
--
--   1. La app registra el token de cada teléfono (register_push_device) solo
--      después de que la persona aceptó los avisos. Al cerrar sesión lo borra.
--   2. Cada aviso nuevo de la tabla notifications deja una línea por teléfono
--      activo en push_outbox (disparador). Un webhook de la base llama a la
--      función send-push, que reclama las pendientes (hmy_push_claim), las
--      envía a Firebase y anota el resultado (hmy_push_report).
--   3. Estado veraz: "sent" = Firebase lo aceptó, no que el teléfono lo mostró.
--      Un token que Firebase rechaza como no registrado se apaga.
--   4. Privacidad: el texto del push nunca lleva lo que escribió una persona
--      (mensajes, descripciones, motivos); solo el título y una frase fija por
--      tipo. El detalle se ve dentro de la app, con sesión.
--   5. send_test_push: la persona se manda un aviso de prueba a sus teléfonos.

create table public.push_devices (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique check (length(token) between 20 and 4096),
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz,
  disabled_reason text
);
create index push_devices_user_idx on public.push_devices (user_id) where disabled_at is null;
alter table public.push_devices enable row level security;
revoke all on public.push_devices from anon, authenticated;
grant select (id, platform, created_at, last_seen_at, disabled_at, disabled_reason) on public.push_devices to authenticated;
create policy push_devices_own on public.push_devices for select to authenticated using (user_id = auth.uid());

create table public.push_outbox (
  id bigserial primary key,
  notification_id bigint not null references public.notifications(id) on delete cascade,
  device_id bigint not null references public.push_devices(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'expired')),
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  unique (notification_id, device_id)
);
create index push_outbox_pending_idx on public.push_outbox (created_at) where status in ('pending', 'sending');
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;
create policy push_outbox_admin on public.push_outbox for select to authenticated using (public.is_admin());
grant select on public.push_outbox to authenticated;

-- Frase fija del push por tipo de aviso. Nunca el cuerpo original.
create function public.hmy_push_text(p_kind text) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'ya_offer' then 'Ábrelo para ver el pedido y responder a tiempo.'
    when 'booking_new' then 'Ábrelo para ver la solicitud.'
    when 'message' then 'Ábrelo para leerlo.'
    when 'push_test' then 'Si ves esto en tu teléfono, los avisos funcionan.'
    else 'Ábrelo en HandiMan ¡Ya! para ver el detalle.'
  end
$$;

-- Un aviso nuevo se pone en cola para cada teléfono activo de la persona.
create function public.hmy_push_enqueue() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.push_outbox (notification_id, device_id)
  select new.id, d.id from public.push_devices d
  where d.user_id = new.user_id and d.disabled_at is null and d.last_seen_at > now() - interval '60 days'
  on conflict do nothing;
  return null;
end $$;

create trigger notifications_push after insert on public.notifications
  for each row execute function public.hmy_push_enqueue();

-- La app registra el token de este teléfono. Un token pasa a quien inició
-- sesión en ese teléfono (nunca recibe avisos de la cuenta anterior).
create function public.register_push_device(p_token text, p_platform text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'HMY_FORBIDDEN'; end if;
  if p_platform not in ('android', 'ios', 'web') then raise exception 'HMY_INVALID'; end if;
  if p_token is null or length(p_token) not between 20 and 4096 then raise exception 'HMY_INVALID'; end if;
  insert into public.push_devices (user_id, token, platform)
  values (v_me, p_token, p_platform)
  on conflict (token) do update
    set user_id = v_me, platform = excluded.platform, last_seen_at = now(),
        disabled_at = null, disabled_reason = null,
        created_at = case when push_devices.user_id = v_me then push_devices.created_at else now() end;
  -- Como máximo 10 teléfonos activos por cuenta: se apagan los más viejos.
  update public.push_devices set disabled_at = now(), disabled_reason = 'replaced'
  where id in (select id from public.push_devices where user_id = v_me and disabled_at is null
               order by last_seen_at desc offset 10);
end $$;

create function public.unregister_push_device(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_devices where token = p_token and user_id = auth.uid()
$$;

-- Estado de los avisos de la persona: teléfonos activos y el último envío.
create function public.my_push_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_last record;
begin
  if v_me is null then raise exception 'HMY_FORBIDDEN'; end if;
  select o.status, o.last_error, o.created_at, o.sent_at, n.kind into v_last
  from public.push_outbox o
  join public.push_devices d on d.id = o.device_id
  join public.notifications n on n.id = o.notification_id
  where d.user_id = v_me
  order by o.id desc limit 1;
  return jsonb_build_object(
    'devices', (select count(*) from public.push_devices where user_id = v_me and disabled_at is null),
    'last_status', v_last.status,
    'last_error', v_last.last_error,
    'last_kind', v_last.kind,
    'last_created_at', v_last.created_at,
    'last_sent_at', v_last.sent_at);
end $$;

-- Aviso de prueba a los teléfonos de la persona (uno por minuto).
create function public.send_test_push() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_devices int;
begin
  if v_me is null then raise exception 'HMY_FORBIDDEN'; end if;
  select count(*) into v_devices from public.push_devices where user_id = v_me and disabled_at is null;
  if v_devices = 0 then raise exception 'HMY_NO_PUSH_DEVICE'; end if;
  if exists (select 1 from public.notifications where user_id = v_me and kind = 'push_test'
             and created_at > now() - interval '1 minute') then
    raise exception 'HMY_RATE_LIMITED';
  end if;
  perform public.notify(v_me, 'push_test', 'Aviso de prueba', public.hmy_push_text('push_test'));
  return v_devices;
end $$;

-- Servidor (send-push): reclama hasta p_limit envíos pendientes. Un envío que
-- quedó "sending" más de 5 minutos se reintenta; después de 5 intentos falla.
-- Lo que tiene más de 24 horas ya no se manda (queda "expired").
create function public.hmy_push_claim(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rows jsonb;
begin
  update public.push_outbox set status = 'expired', last_error = coalesce(last_error, 'vencido sin enviar')
  where status in ('pending', 'sending') and created_at < now() - interval '24 hours';
  update public.push_outbox set status = 'failed'
  where status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts >= 5;

  with picked as (
    select o.id from public.push_outbox o
    join public.push_devices d on d.id = o.device_id
    where d.disabled_at is null
      and (o.status = 'pending' or (o.status = 'sending' and o.claimed_at < now() - interval '5 minutes'))
    order by o.id
    limit greatest(1, least(p_limit, 500))
    for update of o skip locked
  ), upd as (
    update public.push_outbox o set status = 'sending', claimed_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id, 'token', d.token, 'platform', d.platform,
    'title', left(n.title, 120), 'body', public.hmy_push_text(n.kind),
    'data', jsonb_strip_nulls(jsonb_build_object(
      'kind', n.kind, 'notification_id', n.id::text,
      'booking_id', n.data ->> 'booking_id', 'conversation_id', n.data ->> 'conversation_id'))
  ) order by u.id), '[]'::jsonb) into v_rows
  from upd u
  join public.push_devices d on d.id = u.device_id
  join public.notifications n on n.id = u.notification_id;
  return v_rows;
end $$;

-- Servidor (send-push): resultado de cada envío.
-- p_results: [{"id": 1, "ok": true} | {"id": 2, "ok": false, "error": "...", "unregistered": true, "retry": false}]
create function public.hmy_push_report(p_results jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    if (r ->> 'ok')::boolean then
      update public.push_outbox set status = 'sent', sent_at = now(), last_error = null
      where id = (r ->> 'id')::bigint and status = 'sending';
    else
      update public.push_outbox
      set status = case when coalesce((r ->> 'retry')::boolean, false) and attempts < 5 then 'pending' else 'failed' end,
          last_error = left(coalesce(r ->> 'error', 'error'), 300)
      where id = (r ->> 'id')::bigint and status = 'sending';
      if coalesce((r ->> 'unregistered')::boolean, false) then
        update public.push_devices set disabled_at = now(), disabled_reason = 'unregistered'
        where id = (select device_id from public.push_outbox where id = (r ->> 'id')::bigint);
      end if;
    end if;
  end loop;
end $$;

-- Propietario: cómo van los avisos push (sin tokens).
create function public.owner_push_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'devices', (select coalesce(jsonb_object_agg(platform, n), '{}'::jsonb)
                from (select platform, count(*) n from public.push_devices where disabled_at is null group by platform) x),
    'last_24h', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                 from (select status, count(*) n from public.push_outbox
                       where created_at > now() - interval '24 hours' group by status) x),
    'recent_errors', (select coalesce(jsonb_agg(jsonb_build_object('error', last_error, 'at', created_at) order by id desc), '[]'::jsonb)
                      from (select id, last_error, created_at from public.push_outbox
                            where status in ('failed', 'expired') order by id desc limit 5) x));
end $$;

revoke execute on function public.hmy_push_text(text) from public, anon, authenticated;
revoke execute on function public.hmy_push_enqueue() from public, anon, authenticated;
revoke execute on function public.hmy_push_claim(int) from public, anon, authenticated;
revoke execute on function public.hmy_push_report(jsonb) from public, anon, authenticated;
revoke execute on function public.register_push_device(text, text) from public, anon;
revoke execute on function public.unregister_push_device(text) from public, anon;
revoke execute on function public.my_push_status() from public, anon;
revoke execute on function public.send_test_push() from public, anon;
revoke execute on function public.owner_push_overview() from public, anon;
grant execute on function public.register_push_device(text, text) to authenticated;
grant execute on function public.unregister_push_device(text) to authenticated;
grant execute on function public.my_push_status() to authenticated;
grant execute on function public.send_test_push() to authenticated;
grant execute on function public.owner_push_overview() to authenticated;
grant execute on function public.hmy_push_text(text) to service_role;
grant execute on function public.hmy_push_claim(int) to service_role;
grant execute on function public.hmy_push_report(jsonb) to service_role;
