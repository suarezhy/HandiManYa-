-- HandiMan ¡Ya! — 0002 billetera prepagada del profesional y comisiones.
--
-- Reglas:
-- * Los saldos solo cambian dentro de funciones del servidor.
-- * Cada movimiento queda en un libro mayor de solo inserción (wallet_ledger).
-- * Cada movimiento lleva una clave de idempotencia única: repetir la misma
--   operación nunca cobra dos veces.
-- * No hay porcentaje de comisión por defecto. El administrador crea las reglas.

create type public.ledger_entry_type as enum (
  'topup', 'commission_reserve', 'commission_release', 'commission_capture',
  'adjustment', 'refund'
);

create type public.topup_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create type public.commission_milestone as enum ('accepted', 'completed');

create table public.wallets (
  professional_id uuid primary key references public.professional_profiles(user_id) on delete restrict,
  available numeric(12,2) not null default 0 check (available >= 0),
  reserved numeric(12,2) not null default 0 check (reserved >= 0),
  currency text not null default 'BOB' check (currency = 'BOB'),
  updated_at timestamptz not null default now()
);

create table public.wallet_ledger (
  id bigserial primary key,
  professional_id uuid not null references public.wallets(professional_id),
  entry_type public.ledger_entry_type not null,
  -- Variación del saldo disponible y del saldo reservado (pueden ser negativas).
  available_delta numeric(12,2) not null,
  reserved_delta numeric(12,2) not null default 0,
  available_after numeric(12,2) not null,
  reserved_after numeric(12,2) not null,
  booking_id uuid,
  topup_id bigint,
  idempotency_key text not null unique,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index wallet_ledger_pro_idx on public.wallet_ledger (professional_id, created_at desc);

create function public.ledger_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'HMY_LEDGER_APPEND_ONLY';
end $$;

create trigger wallet_ledger_no_update before update or delete on public.wallet_ledger
  for each row execute function public.ledger_is_append_only();

create table public.commission_rules (
  id serial primary key,
  name text not null,
  category_id int references public.service_categories(id),
  city_id smallint references public.cities(id),
  -- Porcentaje sobre el monto final del trabajo, si se conoce.
  rate_percent numeric(5,2) check (rate_percent is null or (rate_percent >= 0 and rate_percent <= 100)),
  -- Cargo fijo por trabajo, usado cuando no hay monto final o no hay porcentaje.
  fixed_fee numeric(10,2) check (fixed_fee is null or fixed_fee >= 0),
  -- Monto que se reserva al aceptar.
  reserve_amount numeric(10,2) not null default 0 check (reserve_amount >= 0),
  -- Saldo mínimo disponible para poder aceptar trabajos.
  min_balance numeric(10,2) not null default 0 check (min_balance >= 0),
  capture_at public.commission_milestone not null default 'completed',
  is_active boolean not null default true,
  valid_from timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.topup_methods (
  id serial primary key,
  name text not null,
  instructions text not null,
  is_active boolean not null default true,
  sort_order int not null default 100
);

create table public.topup_requests (
  id bigserial primary key,
  professional_id uuid not null references public.wallets(professional_id),
  method_id int references public.topup_methods(id),
  amount numeric(10,2) not null check (amount > 0 and amount <= 10000),
  reference text check (reference is null or char_length(reference) <= 120),
  proof_path text,
  status public.topup_status not null default 'pending',
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

create table public.admin_audit_log (
  id bigserial primary key,
  actor_id uuid,
  action text not null,
  target_table text,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create function public.audit(p_action text, p_table text, p_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (auth.uid(), p_action, p_table, p_id, coalesce(p_details, '{}'::jsonb))
$$;

-- La billetera nace cuando el profesional es aprobado.
create function public.create_wallet_on_approval() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' then
    insert into public.wallets (professional_id) values (new.user_id) on conflict do nothing;
  end if;
  return new;
end $$;

create trigger professional_wallet_on_approval
  after insert or update of status on public.professional_profiles
  for each row execute function public.create_wallet_on_approval();

-- Núcleo de todos los movimientos. Bloquea la billetera, valida, aplica y
-- registra. Si la clave de idempotencia ya existe, no hace nada y devuelve
-- el movimiento anterior.
create function public.wallet_post(
  p_professional uuid,
  p_type public.ledger_entry_type,
  p_available_delta numeric,
  p_reserved_delta numeric,
  p_key text,
  p_booking uuid default null,
  p_topup bigint default null,
  p_note text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  w public.wallets;
  v_id bigint;
begin
  if p_key is null or p_key = '' then raise exception 'HMY_IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into w from public.wallets where professional_id = p_professional for update;
  if not found then raise exception 'HMY_WALLET_NOT_FOUND'; end if;

  select id into v_id from public.wallet_ledger where idempotency_key = p_key;
  if found then return v_id; end if;

  if w.available + p_available_delta < 0 then raise exception 'HMY_INSUFFICIENT_BALANCE'; end if;
  if w.reserved + p_reserved_delta < 0 then raise exception 'HMY_INVALID_RESERVATION'; end if;

  update public.wallets
  set available = available + p_available_delta,
      reserved = reserved + p_reserved_delta,
      updated_at = now()
  where professional_id = p_professional;

  insert into public.wallet_ledger (professional_id, entry_type, available_delta, reserved_delta,
                                    available_after, reserved_after, booking_id, topup_id,
                                    idempotency_key, note, created_by)
  values (p_professional, p_type, p_available_delta, p_reserved_delta,
          w.available + p_available_delta, w.reserved + p_reserved_delta, p_booking, p_topup,
          p_key, p_note, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Regla aplicable: la más específica (categoría + ciudad > categoría > ciudad > general).
create function public.commission_rule_for(p_category int, p_city smallint)
returns public.commission_rules
language sql stable security definer set search_path = public as $$
  select r.* from public.commission_rules r
  where r.is_active and r.valid_from <= now()
    and (r.category_id is null or r.category_id = p_category)
    and (r.city_id is null or r.city_id = p_city)
  order by (r.category_id is not null)::int + (r.city_id is not null)::int desc, r.valid_from desc
  limit 1
$$;

-- Profesional: pedir una recarga. Nunca acredita saldo por sí sola.
create function public.request_topup(p_amount numeric, p_method int, p_reference text default null,
                                     p_proof_path text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not exists (select 1 from public.wallets where professional_id = auth.uid()) then
    raise exception 'HMY_WALLET_NOT_FOUND';
  end if;
  if not exists (select 1 from public.topup_methods where id = p_method and is_active) then
    raise exception 'HMY_INVALID_METHOD';
  end if;
  if (select count(*) from public.topup_requests where professional_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'HMY_TOO_MANY_PENDING';
  end if;
  insert into public.topup_requests (professional_id, method_id, amount, reference, proof_path)
  values (auth.uid(), p_method, round(p_amount, 2), p_reference, p_proof_path)
  returning id into v_id;
  return v_id;
end $$;

-- Administrador: aprobar o rechazar una recarga después de verificar el pago.
create function public.review_topup(p_topup bigint, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare t public.topup_requests;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into t from public.topup_requests where id = p_topup for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if t.status <> 'pending' then raise exception 'HMY_ALREADY_REVIEWED'; end if;

  update public.topup_requests
  set status = case when p_approve then 'approved'::public.topup_status else 'rejected'::public.topup_status end,
      reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
  where id = p_topup;

  if p_approve then
    perform public.wallet_post(t.professional_id, 'topup', t.amount, 0, 'topup:' || t.id, null, t.id, p_note);
  end if;
  perform public.audit(case when p_approve then 'topup.approve' else 'topup.reject' end,
                       'topup_requests', t.id::text, jsonb_build_object('amount', t.amount, 'note', p_note));
end $$;

-- Administrador: ajuste manual con motivo obligatorio.
create function public.admin_wallet_adjustment(p_professional uuid, p_amount numeric, p_reason text, p_key text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  v_id := public.wallet_post(p_professional, 'adjustment', round(p_amount, 2), 0, 'adjust:' || p_key, null, null, p_reason);
  perform public.audit('wallet.adjust', 'wallets', p_professional::text,
                       jsonb_build_object('amount', p_amount, 'reason', p_reason, 'key', p_key));
  return v_id;
end $$;

-- RLS
alter table public.wallets enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.commission_rules enable row level security;
alter table public.topup_methods enable row level security;
alter table public.topup_requests enable row level security;
alter table public.admin_audit_log enable row level security;

create policy wallets_own on public.wallets for select using (professional_id = auth.uid() or public.is_admin());
create policy ledger_own on public.wallet_ledger for select using (professional_id = auth.uid() or public.is_admin());
create policy rules_read on public.commission_rules for select using (auth.uid() is not null);
create policy rules_admin on public.commission_rules for all using (public.is_admin()) with check (public.is_admin());
create policy methods_read on public.topup_methods for select using (is_active or public.is_admin());
create policy methods_admin on public.topup_methods for all using (public.is_admin()) with check (public.is_admin());
create policy topups_own on public.topup_requests for select using (professional_id = auth.uid() or public.is_admin());
create policy audit_admin on public.admin_audit_log for select using (public.is_admin());

revoke insert, update, delete on public.wallets from anon, authenticated;
revoke insert, update, delete on public.wallet_ledger from anon, authenticated;
revoke insert, update, delete on public.topup_requests from anon, authenticated;
revoke insert, update, delete on public.admin_audit_log from anon, authenticated;

revoke execute on function public.wallet_post(uuid, public.ledger_entry_type, numeric, numeric, text, uuid, bigint, text) from public, anon, authenticated;
revoke execute on function public.audit(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.commission_rule_for(int, smallint) from public, anon, authenticated;
revoke execute on function public.create_wallet_on_approval() from public, anon, authenticated;
revoke execute on function public.request_topup(numeric, int, text, text) from public, anon;
revoke execute on function public.review_topup(bigint, boolean, text) from public, anon;
revoke execute on function public.admin_wallet_adjustment(uuid, numeric, text, text) from public, anon;
