-- Recargas por QR bancario (pedido del dueño, 30-10-2026, estilo Yango):
-- Mi billetera → Recargar saldo → monto → "Generar QR bancario" → pago →
-- saldo acreditado.
--
-- 1. Cada recarga tiene su referencia única, el profesional, el monto en Bs,
--    la referencia del proveedor, cuándo se creó y cuándo vence, su estado y
--    cómo se verificó. Estados: pending_payment (Pendiente de pago),
--    verifying (Pago en verificación), credited (Acreditada), rejected
--    (Rechazada), expired (Vencida), reversed (Revertida).
-- 2. El saldo se acredita solo con un aviso del proveedor verificado en el
--    servidor (hmy_qr_settle, que solo llama el servidor): una sola vez, con
--    el monto y la moneda revisados y una entrada en el historial. Nunca
--    porque el profesional diga que pagó ni por un mensaje de la app.
-- 3. Si el monto o la moneda no coinciden, o se pagó después de vencer, no se
--    acredita: queda en verificación para el Propietario.
-- 4. Todavía no hay un proveedor contratado. Sin la configuración
--    qr_recharge_provider no se generan QR (la app ofrece la transferencia
--    bancaria de siempre). En desarrollo, 'dev_mock' genera QR simulados, que
--    no se pueden pagar en ningún banco, solo para cuentas de prueba, y el
--    pago se simula con dev_simulate_qr_payment.
-- 5. El Propietario revisa las que quedan en verificación, aprueba o rechaza
--    con un código nuevo, y puede revertir una acreditada sin dejar saldo
--    negativo. Todo queda auditado.
--
-- Agrega dos tablas y funciones; no cambia datos existentes.

create table public.qr_recharges (
  id uuid primary key default gen_random_uuid(),
  -- Va en la glosa del pago para encontrar la recarga.
  reference text not null unique default ('HMY' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  professional_id uuid not null references public.wallets(professional_id),
  amount numeric(10,2) not null check (amount >= 10 and amount <= 5000),
  currency text not null default 'BOB' check (currency = 'BOB'),
  -- Proveedores reales se agregan cuando haya contrato y documentación.
  provider text not null check (provider in ('dev_mock')),
  simulated boolean not null,
  provider_ref text not null,
  qr_payload text,
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'verifying', 'credited', 'rejected', 'expired', 'reversed')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- Lo que informó el proveedor (ya verificado en el servidor).
  paid_amount numeric(10,2),
  paid_currency text,
  paid_at timestamptz,
  review_reason text check (review_reason in ('wrong_amount', 'wrong_currency', 'paid_after_expiry')),
  credited_amount numeric(10,2),
  credited_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text check (review_note is null or char_length(review_note) <= 300),
  reversed_by uuid references auth.users(id),
  reversed_at timestamptz,
  reversal_reason text check (reversal_reason is null or char_length(reversal_reason) <= 300),
  unique (provider, provider_ref),
  check (simulated = (provider = 'dev_mock')),
  check (expires_at > created_at)
);
create index qr_recharges_pro_idx on public.qr_recharges (professional_id, created_at desc);
create index qr_recharges_open_idx on public.qr_recharges (status) where status in ('pending_payment', 'verifying');

-- Cada aviso del proveedor, también los repetidos o desconocidos: conciliación.
create table public.qr_recharge_events (
  id bigserial primary key,
  provider text not null,
  event_id text not null check (char_length(event_id) between 1 and 200),
  provider_ref text,
  recharge_id uuid references public.qr_recharges(id),
  amount numeric(12,2),
  currency text,
  paid_at timestamptz,
  result text,
  created_at timestamptz not null default now(),
  unique (provider, event_id)
);

alter table public.qr_recharges enable row level security;
alter table public.qr_recharge_events enable row level security;
revoke all on public.qr_recharges, public.qr_recharge_events from public, anon, authenticated;
revoke all on sequence public.qr_recharge_events_id_seq from public, anon, authenticated;

-- Proveedor de QR configurado, o null (no se generan QR).
create function public.hmy_qr_provider() returns text
language sql stable security definer set search_path = public as $$
  select nullif(value ->> 'provider', '') from public.app_settings where key = 'qr_recharge_provider'
$$;

-- Estado que ve la gente: una pendiente pasada de hora ya está vencida.
create function public.hmy_qr_status(r public.qr_recharges) returns text
language sql stable as $$
  select case when r.status = 'pending_payment' and r.expires_at <= now() then 'expired' else r.status end
$$;

create function public.hmy_qr_json(r public.qr_recharges) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', r.id, 'reference', r.reference, 'amount', r.amount, 'currency', r.currency,
    'provider', r.provider, 'simulated', r.simulated,
    'qr_payload', case when public.hmy_qr_status(r) = 'pending_payment' then r.qr_payload end,
    'status', public.hmy_qr_status(r), 'created_at', r.created_at, 'expires_at', r.expires_at,
    'paid_amount', r.paid_amount, 'credited_amount', r.credited_amount, 'credited_at', r.credited_at,
    'review_reason', r.review_reason)
$$;

-- ---------------------------------------------------------------- Profesional
create function public.create_qr_recharge(p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_provider text := public.hmy_qr_provider();
  v_amount numeric(10,2) := round(p_amount, 2);
  r public.qr_recharges;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not exists (select 1 from public.wallets where professional_id = v_me) then raise exception 'HMY_WALLET_NOT_FOUND'; end if;
  if public.is_suspended(v_me) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if v_amount is null or v_amount < 10 or v_amount > 5000 then raise exception 'HMY_INVALID_AMOUNT'; end if;
  if v_provider is null then raise exception 'HMY_QR_UNAVAILABLE'; end if;
  -- El QR simulado es solo para cuentas de prueba en desarrollo.
  if v_provider = 'dev_mock' and not exists (select 1 from public.professional_profiles
                                             where user_id = v_me and test_fixture) then
    raise exception 'HMY_QR_UNAVAILABLE';
  end if;
  if v_provider <> 'dev_mock' then raise exception 'HMY_QR_UNAVAILABLE'; end if;

  -- Una a la vez por profesional (serializa dos toques seguidos).
  perform 1 from public.wallets where professional_id = v_me for update;
  update public.qr_recharges set status = 'expired'
  where professional_id = v_me and status = 'pending_payment' and expires_at <= now();
  if (select count(*) from public.qr_recharges where professional_id = v_me and status = 'pending_payment') >= 3 then
    raise exception 'HMY_TOO_MANY_PENDING';
  end if;

  insert into public.qr_recharges (professional_id, amount, provider, simulated, provider_ref, expires_at)
  values (v_me, v_amount, v_provider, true, 'MOCK-' || gen_random_uuid(), now() + interval '15 minutes')
  returning * into r;
  update public.qr_recharges
  set qr_payload = 'HANDIMANYA-DEV|SIMULADO-NO-PAGAR|' || r.reference || '|BOB|' || r.amount
  where id = r.id returning * into r;
  perform public.audit('wallet.qr_create', 'qr_recharges', r.id::text,
                       jsonb_build_object('amount', r.amount, 'provider', r.provider, 'reference', r.reference));
  return public.hmy_qr_json(r);
end $$;

create function public.qr_recharge_status(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select public.hmy_qr_json(r) from public.qr_recharges r where r.id = p_id and r.professional_id = auth.uid()
$$;

create function public.my_qr_recharges() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.hmy_qr_json(r) order by r.created_at desc), '[]'::jsonb)
  from (select * from public.qr_recharges where professional_id = auth.uid() order by created_at desc limit 30) r
$$;

-- ---------------------------------------------------------------- Servidor
-- Aviso de pago del proveedor, ya verificado por la función del servidor
-- (firma y consulta de estado al proveedor). Devuelve qué pasó.
create function public.hmy_qr_settle(p_provider text, p_provider_ref text, p_event_id text, p_amount numeric,
                                     p_currency text, p_paid_at timestamptz)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_event bigint;
  r public.qr_recharges;
  v_result text;
  v_reason text;
begin
  if coalesce(p_event_id, '') = '' or coalesce(p_provider_ref, '') = '' then raise exception 'HMY_INVALID_EVENT'; end if;
  insert into public.qr_recharge_events (provider, event_id, provider_ref, amount, currency, paid_at)
  values (p_provider, p_event_id, p_provider_ref, p_amount, upper(p_currency), p_paid_at)
  on conflict (provider, event_id) do nothing
  returning id into v_event;
  if v_event is null then return 'duplicate_event'; end if;

  select * into r from public.qr_recharges where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then
    v_result := 'unknown_reference';
  elsif r.status in ('credited', 'reversed') then
    v_result := 'already_credited';
  elsif r.status in ('verifying', 'rejected') then
    v_result := 'already_' || r.status;
  else
    v_reason := case
      when upper(coalesce(p_currency, '')) <> r.currency then 'wrong_currency'
      when p_amount is distinct from r.amount then 'wrong_amount'
      when coalesce(p_paid_at, now()) > r.expires_at then 'paid_after_expiry'
    end;
    update public.qr_recharges
    set paid_amount = p_amount, paid_currency = upper(p_currency), paid_at = coalesce(p_paid_at, now()),
        status = case when v_reason is null then 'credited' else 'verifying' end,
        review_reason = v_reason,
        credited_amount = case when v_reason is null then r.amount end,
        credited_at = case when v_reason is null then now() end
    where id = r.id;
    if v_reason is null then
      perform public.wallet_post(r.professional_id, 'topup', r.amount, 0, 'qr:' || r.id, null, null,
        case when r.simulated then 'Recarga simulada (no es dinero real) ' else 'Recarga por QR ' end || r.reference);
      perform public.notify(r.professional_id, 'wallet_credited', 'Recarga acreditada',
        'Se acreditaron ' || to_char(r.amount, 'FM999G990D00') || ' Bs a tu billetera.',
        jsonb_build_object('recharge_id', r.id));
      v_result := 'credited';
    else
      perform public.notify(r.professional_id, 'wallet_verifying', 'Pago en verificación',
        'Recibimos un pago que no coincide con tu recarga. El equipo lo revisa antes de acreditarlo.',
        jsonb_build_object('recharge_id', r.id));
      v_result := 'verifying_' || v_reason;
    end if;
  end if;
  update public.qr_recharge_events set recharge_id = r.id, result = v_result where id = v_event;
  return v_result;
end $$;

-- Desarrollo: simula el aviso del banco para un QR simulado propio. No existe
-- para QR reales: esos solo se acreditan con el aviso verificado del proveedor.
create function public.dev_simulate_qr_payment(p_id uuid, p_amount numeric default null, p_currency text default 'BOB',
                                               p_event_id text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare r public.qr_recharges;
begin
  select * into r from public.qr_recharges where id = p_id and professional_id = auth.uid();
  if not found or r.provider <> 'dev_mock' or not r.simulated or public.hmy_qr_provider() is distinct from 'dev_mock'
     or not exists (select 1 from public.professional_profiles where user_id = r.professional_id and test_fixture) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  return public.hmy_qr_settle('dev_mock', r.provider_ref, coalesce(p_event_id, 'mock:' || r.id),
                              coalesce(p_amount, r.amount), p_currency, now());
end $$;

-- ---------------------------------------------------------------- Propietario
create function public.owner_qr_recharges(p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'summary', (select jsonb_object_agg(s, jsonb_build_object('count', n, 'amount', a))
                from (select public.hmy_qr_status(r) s, count(*) n, sum(coalesce(r.credited_amount, r.amount)) a
                      from public.qr_recharges r group by 1) x),
    'unmatched_events', (select count(*) from public.qr_recharge_events where result = 'unknown_reference'),
    'items', coalesce((
      select jsonb_agg(public.hmy_qr_json(r) || jsonb_build_object(
               'professional_id', r.professional_id,
               'professional', (select display_name from public.professional_profiles where user_id = r.professional_id),
               'paid_currency', r.paid_currency, 'paid_at', r.paid_at, 'review_note', r.review_note,
               'reversal_reason', r.reversal_reason,
               'events', (select count(*) from public.qr_recharge_events e where e.recharge_id = r.id))
             order by r.created_at desc)
      from (select * from public.qr_recharges q
            where p_status is null or public.hmy_qr_status(q) = p_status
            order by q.created_at desc limit 200) r), '[]'::jsonb));
end $$;

-- Una recarga en verificación: aprobar acredita lo que el proveedor informó
-- que se pagó (en Bs); rechazar no acredita nada. Con código nuevo y motivo.
create function public.owner_review_qr_recharge(p_id uuid, p_approve boolean, p_note text, p_auth_method text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.qr_recharges;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into r from public.qr_recharges where id = p_id for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if r.status <> 'verifying' then raise exception 'HMY_ALREADY_REVIEWED'; end if;
  if p_approve and (r.paid_currency is distinct from 'BOB' or coalesce(r.paid_amount, 0) <= 0) then
    raise exception 'HMY_WRONG_CURRENCY';
  end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.qr_review');
  update public.qr_recharges
  set status = case when p_approve then 'credited' else 'rejected' end,
      credited_amount = case when p_approve then r.paid_amount end,
      credited_at = case when p_approve then now() end,
      reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note)
  where id = r.id returning * into r;
  if p_approve then
    perform public.wallet_post(r.professional_id, 'topup', r.paid_amount, 0, 'qr:' || r.id, null, null,
      case when r.simulated then 'Recarga simulada (no es dinero real) ' else 'Recarga por QR ' end || r.reference
      || ' (revisada)');
    perform public.notify(r.professional_id, 'wallet_credited', 'Recarga acreditada',
      'Se acreditaron ' || to_char(r.paid_amount, 'FM999G990D00') || ' Bs a tu billetera.', jsonb_build_object('recharge_id', r.id));
  else
    perform public.notify(r.professional_id, 'wallet_rejected', 'Recarga rechazada',
      'No pudimos acreditar tu recarga ' || r.reference || '. Escribe a soporte si necesitas ayuda.',
      jsonb_build_object('recharge_id', r.id));
  end if;
  perform public.audit(case when p_approve then 'wallet.qr_approve' else 'wallet.qr_reject' end, 'qr_recharges', r.id::text,
                       jsonb_build_object('reference', r.reference, 'amount', r.amount, 'paid_amount', r.paid_amount,
                                          'reason', r.review_reason, 'note', btrim(p_note), 'auth_method', p_auth_method));
  return public.hmy_qr_json(r);
end $$;

-- Revertir una recarga acreditada (por ejemplo, el banco anuló el pago).
-- Descuenta lo acreditado del saldo disponible; si no alcanza, no se hace:
-- nunca queda saldo negativo.
create function public.owner_reverse_qr_recharge(p_id uuid, p_reason text, p_auth_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.qr_recharges;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into r from public.qr_recharges where id = p_id for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if r.status <> 'credited' then raise exception 'HMY_INVALID_STATUS'; end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.qr_reverse');
  perform public.wallet_post(r.professional_id, 'adjustment', -r.credited_amount, 0, 'qr-reverse:' || r.id, null, null,
                             'Reversión de la recarga ' || r.reference || ': ' || btrim(p_reason));
  update public.qr_recharges
  set status = 'reversed', reversed_by = auth.uid(), reversed_at = now(), reversal_reason = btrim(p_reason)
  where id = r.id returning * into r;
  perform public.notify(r.professional_id, 'wallet_reversed', 'Recarga revertida',
    'Se revirtió tu recarga ' || r.reference || '. Revisa el historial de tu billetera.', jsonb_build_object('recharge_id', r.id));
  perform public.audit('wallet.qr_reverse', 'qr_recharges', r.id::text,
                       jsonb_build_object('reference', r.reference, 'amount', r.credited_amount, 'reason', btrim(p_reason),
                                          'auth_method', p_auth_method));
  return public.hmy_qr_json(r);
end $$;

-- Datos oficiales para la transferencia bancaria: solo cuentas que el
-- Propietario cargó y verificó con su banco.
create function public.recharge_bank_accounts() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'label', a.label, 'account_type', a.account_type, 'bank_name', a.bank_name,
           'holder_name', a.holder_name, 'account_number', a.account_number, 'currency', a.currency,
           'has_qr', a.qr_path is not null) order by a.id), '[]'::jsonb)
  from public.receiving_accounts a
  where a.is_active and a.verification = 'verificada' and a.currency = 'BOB'
    and exists (select 1 from public.wallets w where w.professional_id = auth.uid())
$$;

-- Vencer las pendientes pasadas de hora (también lo hace cada nueva recarga).
create function public.expire_qr_recharges() returns int
language sql security definer set search_path = public as $$
  with x as (update public.qr_recharges set status = 'expired'
             where status = 'pending_payment' and expires_at <= now() returning 1)
  select count(*)::int from x
$$;

-- Frase fija del push para los avisos de billetera.
create or replace function public.hmy_push_text(p_kind text) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'ya_offer' then 'Ábrelo para ver el pedido y responder a tiempo.'
    when 'booking_new' then 'Ábrelo para ver la solicitud.'
    when 'message' then 'Ábrelo para leerlo.'
    when 'push_test' then 'Si ves esto en tu teléfono, los avisos funcionan.'
    when 'wallet_credited' then 'Tu saldo ya está disponible.'
    when 'wallet_verifying' then 'Ábrelo para ver el estado de tu recarga.'
    when 'wallet_rejected' then 'Ábrelo para ver el estado de tu recarga.'
    when 'wallet_reversed' then 'Ábrelo para ver el historial de tu billetera.'
    else 'Ábrelo en HandiMan ¡Ya! para ver el detalle.'
  end
$$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_qr_provider() from public, anon, authenticated;
revoke execute on function public.hmy_qr_status(public.qr_recharges) from public, anon, authenticated;
revoke execute on function public.hmy_qr_json(public.qr_recharges) from public, anon, authenticated;
revoke execute on function public.hmy_qr_settle(text, text, text, numeric, text, timestamptz) from public, anon, authenticated;
grant execute on function public.hmy_qr_settle(text, text, text, numeric, text, timestamptz) to service_role;
revoke execute on function public.expire_qr_recharges() from public, anon, authenticated;
grant execute on function public.expire_qr_recharges() to service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'public.create_qr_recharge(numeric)', 'public.qr_recharge_status(uuid)', 'public.my_qr_recharges()',
    'public.dev_simulate_qr_payment(uuid, numeric, text, text)', 'public.owner_qr_recharges(text)',
    'public.owner_review_qr_recharge(uuid, boolean, text, text)', 'public.owner_reverse_qr_recharge(uuid, text, text)',
    'public.recharge_bank_accounts()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
