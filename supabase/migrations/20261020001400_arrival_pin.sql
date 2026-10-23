-- HandiMan ¡Ya! — 0014 Código de llegada (PIN).
--
-- El cliente confirma que llegó la persona correcta, no un GPS:
-- 1. El profesional marca "Voy en camino" (on_the_way) y, al llegar, "He llegado".
-- 2. El servidor genera un código de 6 números al azar (generador criptográfico),
--    ligado a ese pedido y a ese profesional. Solo el profesional lo ve, una vez:
--    "Proporciona este código al cliente para verificar tu llegada."
-- 3. El cliente lo escribe en "Verificar llegada". El servidor lo compara en una
--    sola operación, guarda la hora de llegada verificada y avisa al profesional.
-- 4. Recién entonces el pedido puede pasar a "En progreso".
--
-- Seguridad:
-- - Se guarda solo un verificador (bcrypt), nunca el código.
-- - Vence a los 10 minutos. 5 intentos fallidos por código; 3 códigos por pedido
--   (después, solo el equipo puede verificar). 30 segundos entre códigos nuevos.
--   Cada cliente tiene un máximo de 10 intentos fallidos por hora, en todos sus pedidos.
-- - Un código usado, vencido o de un pedido cancelado deja de servir (sin repetición).
-- - Solo el cliente de ese pedido puede escribirlo; el profesional no puede
--   verificarse a sí mismo. La ubicación GPS nunca basta para verificar.
-- - Excepción del equipo: un admin puede verificar con un motivo escrito, que
--   queda en la auditoría.
--
-- Puntualidad: en los pedidos programados se guarda la diferencia entre la llegada
-- verificada y la hora acordada. Es solo información (con apelación y excepciones);
-- no genera multas ni descuentos automáticos.

do $$ begin
  if to_regclass('public.otp_sends') is null then
    raise exception 'HMY: falta la migración 0013; no se aplicó nada.';
  end if;
  if to_regclass('public.booking_arrivals') is not null then
    raise exception 'HMY: la migración 0014 ya estaba aplicada; no se aplicó nada.';
  end if;
end $$;

create table public.booking_arrivals (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  professional_id uuid not null references public.profiles(id) on delete cascade,
  -- Verificador del código vigente; null si no hay código activo.
  pin_hash text,
  pin_expires_at timestamptz,
  wrong_attempts smallint not null default 0,
  pins_issued smallint not null default 0,
  last_issued_at timestamptz,
  arrived_at timestamptz,
  verified_at timestamptz,
  verified_by uuid references public.profiles(id) on delete set null,
  method text check (method in ('pin', 'admin')),
  admin_reason text,
  -- Minutos tarde respecto de la hora acordada (solo pedidos programados; 0 si llegó a tiempo).
  delay_minutes int,
  check ((verified_at is null) = (method is null))
);

create table public.arrival_pin_attempts (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  ok boolean not null,
  created_at timestamptz not null default now()
);
create index arrival_pin_attempts_customer_idx on public.arrival_pin_attempts (customer_id, created_at desc);

alter table public.booking_arrivals enable row level security;
alter table public.arrival_pin_attempts enable row level security;
revoke all on public.booking_arrivals, public.arrival_pin_attempts from anon, authenticated;
grant select on public.arrival_pin_attempts to authenticated;
create policy arrival_pin_attempts_admin on public.arrival_pin_attempts for select to authenticated
  using (public.is_admin());

-- Código de 6 números sin sesgo, con el generador criptográfico de pgcrypto.
create function public.hmy_arrival_pin() returns text
language plpgsql volatile set search_path = public as $$
declare v bigint;
begin
  loop
    v := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v < 4294000000;  -- múltiplo exacto de 1.000.000
  end loop;
  return lpad((v % 1000000)::text, 6, '0');
end $$;

-- "He llegado": devuelve el código solo al profesional asignado.
create function public.mark_arrived(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  a public.booking_arrivals;
  v_pin text;
  v_wait int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.professional_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if b.status <> 'on_the_way' then raise exception 'HMY_INVALID_TRANSITION: % -> arrived', b.status; end if;

  select * into a from public.booking_arrivals where booking_id = b.id for update;
  if a.verified_at is not null then raise exception 'HMY_ARRIVAL_ALREADY_VERIFIED'; end if;
  if coalesce(a.pins_issued, 0) >= 3 then raise exception 'HMY_ARRIVAL_PIN_LIMIT'; end if;
  if a.last_issued_at > now() - interval '30 seconds' then
    v_wait := ceil(extract(epoch from a.last_issued_at + interval '30 seconds' - now()))::int;
    raise exception 'HMY_ARRIVAL_PIN_TOO_SOON:%', greatest(v_wait, 1);
  end if;

  v_pin := public.hmy_arrival_pin();
  insert into public.booking_arrivals as x (booking_id, professional_id, pin_hash, pin_expires_at, wrong_attempts,
                                            pins_issued, last_issued_at, arrived_at)
  values (b.id, b.professional_id, extensions.crypt(v_pin, extensions.gen_salt('bf', 8)),
          now() + interval '10 minutes', 0, 1, now(), now())
  on conflict (booking_id) do update set
    pin_hash = excluded.pin_hash,
    pin_expires_at = excluded.pin_expires_at,
    wrong_attempts = 0,
    pins_issued = x.pins_issued + 1,
    last_issued_at = now();

  if a.booking_id is null then
    perform public.notify(b.customer_id, 'arrival', 'Tu profesional llegó',
      'Pídele el código de 6 números y escríbelo en "Verificar llegada".', jsonb_build_object('booking_id', b.id));
  end if;
  return jsonb_build_object('pin', v_pin, 'expires_at', now() + interval '10 minutes',
                            'pins_left', 3 - coalesce(a.pins_issued, 0) - 1);
end $$;

-- "Verificar llegada": solo el cliente del pedido. Un código incorrecto o vencido
-- devuelve ok=false (no es un error) para que el intento quede registrado.
create function public.verify_arrival_pin(p_booking uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  a public.booking_arrivals;
  v_left int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.customer_id is distinct from auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if b.status <> 'on_the_way' then raise exception 'HMY_INVALID_TRANSITION: % -> arrival_verified', b.status; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then raise exception 'HMY_INVALID_PIN'; end if;
  if (select count(*) from public.arrival_pin_attempts
       where customer_id = auth.uid() and not ok and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'HMY_TOO_MANY_ATTEMPTS';
  end if;

  select * into a from public.booking_arrivals where booking_id = b.id for update;
  if a.verified_at is not null then raise exception 'HMY_ARRIVAL_ALREADY_VERIFIED'; end if;
  if a.pin_hash is null then raise exception 'HMY_ARRIVAL_NO_PIN'; end if;

  if a.pin_expires_at <= now() then
    update public.booking_arrivals set pin_hash = null where booking_id = b.id;
    return jsonb_build_object('ok', false, 'reason', 'expired', 'pins_left', 3 - a.pins_issued);
  end if;

  if extensions.crypt(p_pin, a.pin_hash) <> a.pin_hash then
    insert into public.arrival_pin_attempts (booking_id, customer_id, ok) values (b.id, auth.uid(), false);
    v_left := 5 - (a.wrong_attempts + 1);
    update public.booking_arrivals set
      wrong_attempts = wrong_attempts + 1,
      pin_hash = case when v_left <= 0 then null else pin_hash end
    where booking_id = b.id;
    return jsonb_build_object('ok', false, 'reason', case when v_left <= 0 then 'locked' else 'wrong' end,
                              'attempts_left', greatest(v_left, 0), 'pins_left', 3 - a.pins_issued);
  end if;

  insert into public.arrival_pin_attempts (booking_id, customer_id, ok) values (b.id, auth.uid(), true);
  update public.booking_arrivals set
    pin_hash = null,
    verified_at = now(),
    verified_by = auth.uid(),
    method = 'pin',
    delay_minutes = case when b.mode = 'scheduled' and b.scheduled_start is not null
                         then greatest(0, floor(extract(epoch from now() - b.scheduled_start) / 60))::int end
  where booking_id = b.id;
  perform public.notify(b.professional_id, 'arrival', 'Llegada verificada',
    'El cliente confirmó tu llegada. Ya puedes empezar el trabajo.', jsonb_build_object('booking_id', b.id));
  return jsonb_build_object('ok', true, 'verified_at', now());
end $$;

-- Excepción del equipo (por ejemplo, el cliente no tiene la app a mano y llama
-- a soporte). Se busca el pedido por su código, el que ven cliente y profesional.
create function public.admin_verify_arrival(p_code text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into b from public.bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status <> 'on_the_way' then raise exception 'HMY_INVALID_TRANSITION: % -> arrival_verified', b.status; end if;
  if exists (select 1 from public.booking_arrivals where booking_id = b.id and verified_at is not null) then
    raise exception 'HMY_ARRIVAL_ALREADY_VERIFIED';
  end if;

  insert into public.booking_arrivals as x (booking_id, professional_id, arrived_at, verified_at, verified_by,
                                            method, admin_reason)
  values (b.id, b.professional_id, now(), now(), auth.uid(), 'admin', btrim(p_reason))
  on conflict (booking_id) do update set
    pin_hash = null, verified_at = now(), verified_by = auth.uid(), method = 'admin',
    admin_reason = btrim(p_reason), arrived_at = coalesce(x.arrived_at, now());

  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (auth.uid(), 'arrival.admin_verified', 'bookings', b.id::text, jsonb_build_object('reason', btrim(p_reason)));
  perform public.notify(b.professional_id, 'arrival', 'Llegada verificada por el equipo',
    'Ya puedes empezar el trabajo.', jsonb_build_object('booking_id', b.id));
  perform public.notify(b.customer_id, 'arrival', 'Llegada verificada por el equipo',
    btrim(p_reason), jsonb_build_object('booking_id', b.id));
end $$;

-- Estado de la llegada para el cliente, el profesional o el equipo. Nunca el código.
create function public.booking_arrival(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings;
  a public.booking_arrivals;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if auth.uid() is distinct from b.customer_id and auth.uid() is distinct from b.professional_id
     and not public.is_admin() then
    raise exception 'HMY_FORBIDDEN';
  end if;
  select * into a from public.booking_arrivals where booking_id = b.id;
  return jsonb_build_object(
    'state', case when a.verified_at is not null then 'verified'
                  when a.pin_hash is not null and a.pin_expires_at > now() then 'waiting_pin'
                  when a.booking_id is not null then 'arrived'
                  else 'none' end,
    'arrived_at', a.arrived_at,
    'pin_expires_at', case when a.pin_hash is not null then a.pin_expires_at end,
    'attempts_left', case when a.pin_hash is not null then 5 - a.wrong_attempts end,
    'pins_left', 3 - coalesce(a.pins_issued, 0),
    'verified_at', a.verified_at,
    'method', a.method,
    'delay_minutes', a.delay_minutes);
end $$;

-- Sin llegada verificada no se empieza el trabajo. Si el pedido sale de
-- "en camino" por otro motivo (cancelación, disputa), el código deja de servir.
create function public.hmy_arrival_gate() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'in_progress' and old.status is distinct from 'in_progress'
     and not exists (select 1 from public.booking_arrivals where booking_id = new.id and verified_at is not null) then
    raise exception 'HMY_ARRIVAL_NOT_VERIFIED';
  end if;
  if old.status = 'on_the_way' and new.status is distinct from 'on_the_way' then
    update public.booking_arrivals set pin_hash = null where booking_id = new.id and pin_hash is not null;
  end if;
  return new;
end $$;

create trigger bookings_arrival_gate before update of status on public.bookings
  for each row execute function public.hmy_arrival_gate();

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_arrival_pin() from public, anon, authenticated;
revoke execute on function public.hmy_arrival_gate() from public, anon, authenticated;
revoke execute on function public.mark_arrived(uuid) from public, anon;
revoke execute on function public.verify_arrival_pin(uuid, text) from public, anon;
revoke execute on function public.admin_verify_arrival(text, text) from public, anon;
revoke execute on function public.booking_arrival(uuid) from public, anon;
grant execute on function public.mark_arrived(uuid) to authenticated;
grant execute on function public.verify_arrival_pin(uuid, text) to authenticated;
grant execute on function public.admin_verify_arrival(text, text) to authenticated;
grant execute on function public.booking_arrival(uuid) to authenticated;
