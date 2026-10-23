-- HandiMan ¡Ya! — 0038 Finanzas y Bancos (solo el Propietario).
--
-- Cómo se mueve la plata:
-- - El cliente le paga al profesional directo, en efectivo o por QR. Ese
--   dinero no pasa por la plataforma y aquí no aparece.
-- - El profesional recarga su billetera con una transferencia o QR a una cuenta
--   de la plataforma. Esa plata sigue siendo del profesional (un saldo que se
--   le debe), no es un ingreso.
-- - La plataforma gana solo la comisión que cobra de esa billetera al cerrar un
--   trabajo (commission_capture), según la regla de comisión aprobada.
-- - Un comprobante subido no prueba que el dinero llegó al banco. Cada recarga
--   tiene un estado bancario: "sin verificar" hasta que el Propietario la
--   concilia con su extracto. No hay conexión con el banco: nada se marca como
--   verificado solo.
--
-- Nada de esto guarda contraseñas de banca por internet: solo los datos que se
-- dan para recibir un pago (banco, titular, número de cuenta, QR).
--
-- Gerente y Empleado no tienen acceso: todo pasa por funciones que exigen
-- is_admin(), las tablas no tienen permisos directos, y cambiar una cuenta de
-- cobro o conciliar exige un código nuevo (o la contraseña) y queda auditado.

-- ---------------------------------------------------------------------------
-- Cuentas de cobro de la plataforma
-- ---------------------------------------------------------------------------
create table public.receiving_accounts (
  id serial primary key,
  label text not null check (char_length(btrim(label)) between 2 and 60),
  account_type text not null check (account_type in ('caja_ahorro', 'cuenta_corriente', 'qr')),
  bank_name text not null check (char_length(btrim(bank_name)) between 2 and 80),
  holder_name text not null check (char_length(btrim(holder_name)) between 2 and 120),
  account_number text check (account_number is null or account_number ~ '^[0-9][0-9 -]{3,29}$'),
  currency text not null default 'BOB' check (currency in ('BOB', 'USD')),
  -- Imagen del QR de cobro, en el bucket privado payment-qr, carpeta del Propietario.
  qr_path text check (qr_path is null or char_length(qr_path) <= 300),
  notes text check (notes is null or char_length(notes) <= 300),
  -- 'verificada': el Propietario confirmó con su banco que la cuenta recibe.
  verification text not null default 'sin_verificar' check (verification in ('sin_verificar', 'verificada')),
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  check (account_type = 'qr' or account_number is not null),
  check (account_type <> 'qr' or qr_path is not null or account_number is not null)
);
alter table public.receiving_accounts enable row level security;
revoke all on public.receiving_accounts from public, anon, authenticated;
revoke all on sequence public.receiving_accounts_id_seq from public, anon, authenticated;

-- Conciliación de cada recarga con el banco.
alter table public.topup_requests
  add column bank_status text not null default 'sin_verificar'
    check (bank_status in ('sin_verificar', 'conciliada', 'no_encontrada')),
  add column bank_reference text check (bank_reference is null or char_length(bank_reference) <= 120),
  add column bank_account_id int references public.receiving_accounts(id),
  add column bank_checked_by uuid references auth.users(id),
  add column bank_checked_at timestamptz;

-- "•••• 1234": así se muestra un número de cuenta en listas y en la auditoría.
create function public.hmy_mask_account(p_number text) returns text
language sql immutable set search_path = public as $$
  select case when p_number is null then null
              when char_length(regexp_replace(p_number, '\D', '', 'g')) <= 4 then '••••'
              else '•••• ' || right(regexp_replace(p_number, '\D', '', 'g'), 4) end
$$;

-- Confirmación fuerte para dinero y bancos: código nuevo o contraseña, nunca
-- solo la huella.
create function public.hmy_require_strong_confirmation(p_method text, p_purpose text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_method, '') not in ('otp', 'password') then raise exception 'HMY_CONFIRMATION_REQUIRED'; end if;
  perform public.hmy_require_confirmation(p_method, p_purpose);
end $$;

-- ---------------------------------------------------------------------------
-- Resumen financiero del mes (hora de Bolivia)
-- ---------------------------------------------------------------------------
create function public.owner_finance_summary(p_month date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz constant text := 'America/La_Paz';
  v_month date := date_trunc('month', coalesce(p_month, (now() at time zone v_tz)::date))::date;
  v_from timestamptz := v_month::timestamp at time zone v_tz;
  v_to timestamptz := (v_month + interval '1 month')::timestamp at time zone v_tz;
  v_months jsonb;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;

  -- Seis meses: lo que entró a billeteras y la comisión ganada, por separado.
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(m, 'YYYY-MM'),
           'wallet_funds_bs', (select coalesce(sum(t.amount), 0) from public.topup_requests t
                               where t.status = 'approved'
                                 and t.reviewed_at >= m::timestamp at time zone v_tz
                                 and t.reviewed_at < (m + interval '1 month')::timestamp at time zone v_tz),
           'commission_bs', (select coalesce(-sum(l.available_delta + l.reserved_delta), 0) from public.wallet_ledger l
                             where l.entry_type = 'commission_capture'
                               and l.created_at >= m::timestamp at time zone v_tz
                               and l.created_at < (m + interval '1 month')::timestamp at time zone v_tz))
         order by m), '[]'::jsonb)
  into v_months
  from generate_series(v_month - interval '5 months', v_month, interval '1 month') m;

  return jsonb_build_object(
    'month', to_char(v_month, 'YYYY-MM'),
    'timezone', v_tz,
    'generated_at', now(),
    -- Ingreso real de la plataforma: comisiones cobradas, menos devoluciones.
    'commission_earned_bs', (select coalesce(-sum(available_delta + reserved_delta), 0) from public.wallet_ledger
                             where entry_type = 'commission_capture' and created_at >= v_from and created_at < v_to),
    'commissions_count', (select count(*) from public.wallet_ledger
                          where entry_type = 'commission_capture' and created_at >= v_from and created_at < v_to),
    'commission_refunded_bs', (select coalesce(sum(available_delta), 0) from public.wallet_ledger
                               where entry_type = 'refund' and created_at >= v_from and created_at < v_to),
    -- Recargas acreditadas: plata de los profesionales, no ingreso.
    'wallet_funds_received_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                 where status = 'approved' and reviewed_at >= v_from and reviewed_at < v_to),
    'wallet_funds_received_count', (select count(*) from public.topup_requests
                                    where status = 'approved' and reviewed_at >= v_from and reviewed_at < v_to),
    'wallet_funds_reconciled_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                   where status = 'approved' and bank_status = 'conciliada'
                                     and reviewed_at >= v_from and reviewed_at < v_to),
    'wallet_funds_unverified_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                   where status = 'approved' and bank_status = 'sin_verificar'
                                     and reviewed_at >= v_from and reviewed_at < v_to),
    'wallet_funds_not_found_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                  where status = 'approved' and bank_status = 'no_encontrada'
                                    and reviewed_at >= v_from and reviewed_at < v_to),
    'manual_adjustments_bs', (select coalesce(sum(available_delta), 0) from public.wallet_ledger
                              where entry_type = 'adjustment' and created_at >= v_from and created_at < v_to),
    -- Pendientes ahora (todas las fechas).
    'topups_pending', (select count(*) from public.topup_requests where status = 'pending'),
    'topups_pending_bs', (select coalesce(sum(amount), 0) from public.topup_requests where status = 'pending'),
    'topups_unverified_total', (select count(*) from public.topup_requests
                                where status = 'approved' and bank_status = 'sin_verificar'),
    'topups_unverified_total_bs', (select coalesce(sum(amount), 0) from public.topup_requests
                                   where status = 'approved' and bank_status = 'sin_verificar'),
    -- Saldos de los profesionales ahora: plata que se les debe.
    'wallets_available_bs', (select coalesce(sum(available), 0) from public.wallets),
    'wallets_reserved_bs', (select coalesce(sum(reserved), 0) from public.wallets),
    'wallets_count', (select count(*) from public.wallets),
    'receiving_accounts_active', (select count(*) from public.receiving_accounts where is_active),
    'receiving_accounts_verified', (select count(*) from public.receiving_accounts
                                    where is_active and verification = 'verificada'),
    -- No hay conexión con ningún banco: la conciliación es manual.
    'bank_integration', 'pendiente_configuracion',
    'months', v_months);
end $$;

-- ---------------------------------------------------------------------------
-- Movimientos de las billeteras (con referencias)
-- ---------------------------------------------------------------------------
create function public.owner_finance_transactions(p_kind text default null, p_before bigint default null,
                                                  p_limit int default 50)
returns table (id bigint, professional_id uuid, professional_name text, entry_type text,
               available_delta numeric, reserved_delta numeric, booking_code text, topup_id bigint,
               topup_bank_status text, reference text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select l.id, l.professional_id, coalesce(pp.display_name, p.full_name), l.entry_type::text,
         l.available_delta, l.reserved_delta, b.code, l.topup_id, t.bank_status,
         coalesce(t.bank_reference, t.reference), l.note, l.created_at
  from public.wallet_ledger l
  left join public.professional_profiles pp on pp.user_id = l.professional_id
  left join public.profiles p on p.id = l.professional_id
  left join public.bookings b on b.id = l.booking_id
  left join public.topup_requests t on t.id = l.topup_id
  where (p_kind is null or l.entry_type::text = p_kind)
    and (p_before is null or l.id < p_before)
  order by l.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

-- ---------------------------------------------------------------------------
-- Recargas para conciliar
-- ---------------------------------------------------------------------------
create function public.owner_topups_reconciliation(p_bank_status text default 'sin_verificar')
returns table (id bigint, professional_id uuid, professional_name text, amount numeric, method_name text,
               reference text, has_proof boolean, status text, bank_status text, bank_reference text,
               bank_account_id int, bank_account_label text, bank_checked_at timestamptz,
               reviewed_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_bank_status not in ('sin_verificar', 'conciliada', 'no_encontrada', 'pendiente', 'todas') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  return query
  select t.id, t.professional_id, pp.display_name, t.amount, m.name, t.reference, t.proof_path is not null,
         t.status::text, t.bank_status, t.bank_reference, t.bank_account_id, a.label, t.bank_checked_at,
         t.reviewed_at, t.created_at
  from public.topup_requests t
  join public.professional_profiles pp on pp.user_id = t.professional_id
  left join public.topup_methods m on m.id = t.method_id
  left join public.receiving_accounts a on a.id = t.bank_account_id
  where case p_bank_status
          when 'todas' then true
          when 'pendiente' then t.status = 'pending'
          else t.status = 'approved' and t.bank_status = p_bank_status end
  order by t.created_at desc
  limit 200;
end $$;

-- Conciliar: el Propietario revisó su extracto. Solo recargas ya acreditadas;
-- "conciliada" pide la referencia del banco.
create function public.owner_reconcile_topup(p_topup bigint, p_bank_status text, p_bank_reference text,
                                             p_account int, p_auth_method text)
returns void
language plpgsql security definer set search_path = public as $$
declare t public.topup_requests;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_bank_status not in ('conciliada', 'no_encontrada', 'sin_verificar') then raise exception 'HMY_INVALID_STATUS'; end if;
  select * into t from public.topup_requests where id = p_topup for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if t.status <> 'approved' then raise exception 'HMY_TOPUP_NOT_CREDITED'; end if;
  if p_bank_status = 'conciliada' and coalesce(btrim(p_bank_reference), '') = '' then
    raise exception 'HMY_BANK_REFERENCE_REQUIRED';
  end if;
  if p_account is not null and not exists (select 1 from public.receiving_accounts where id = p_account) then
    raise exception 'HMY_NOT_FOUND';
  end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.reconcile');
  update public.topup_requests
  set bank_status = p_bank_status, bank_reference = nullif(btrim(p_bank_reference), ''), bank_account_id = p_account,
      bank_checked_by = auth.uid(), bank_checked_at = now()
  where id = p_topup;
  perform public.audit('finance.reconcile', 'topup_requests', p_topup::text,
                       jsonb_strip_nulls(jsonb_build_object('from', t.bank_status, 'to', p_bank_status,
                                                            'amount', t.amount, 'account', p_account,
                                                            'bank_reference', nullif(btrim(p_bank_reference), ''),
                                                            'auth_method', p_auth_method)));
end $$;

-- ---------------------------------------------------------------------------
-- Cuentas de cobro: ver, guardar, activar
-- ---------------------------------------------------------------------------
create function public.owner_receiving_accounts()
returns table (id int, label text, account_type text, bank_name text, holder_name text, account_number text,
               account_masked text, currency text, qr_path text, notes text, verification text, is_active boolean,
               updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select a.id, a.label, a.account_type, a.bank_name, a.holder_name, a.account_number,
         public.hmy_mask_account(a.account_number), a.currency, a.qr_path, a.notes, a.verification, a.is_active,
         a.updated_at
  from public.receiving_accounts a
  order by a.is_active desc, a.id;
end $$;

-- p_id null crea; si no, actualiza. Cambiar datos de cobro vuelve la cuenta a
-- "sin verificar" (hay que volver a confirmarla con el banco).
create function public.owner_save_receiving_account(p_id int, p_label text, p_account_type text, p_bank_name text,
                                                    p_holder_name text, p_account_number text, p_currency text,
                                                    p_qr_path text, p_notes text, p_auth_method text)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id int;
  v_old public.receiving_accounts;
  v_number text := nullif(btrim(p_account_number), '');
  v_qr text := nullif(btrim(p_qr_path), '');
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  -- El QR tiene que estar en la carpeta del Propietario que lo guarda.
  if v_qr is not null and public.storage_owner_folder(v_qr) is distinct from auth.uid()::text then
    raise exception 'HMY_FORBIDDEN';
  end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.account');
  if p_id is null then
    insert into public.receiving_accounts (label, account_type, bank_name, holder_name, account_number, currency,
                                           qr_path, notes, created_by, updated_by)
    values (btrim(p_label), p_account_type, btrim(p_bank_name), btrim(p_holder_name), v_number,
            coalesce(p_currency, 'BOB'), v_qr, nullif(btrim(p_notes), ''), auth.uid(), auth.uid())
    returning id into v_id;
    perform public.audit('finance.account_created', 'receiving_accounts', v_id::text,
                         jsonb_strip_nulls(jsonb_build_object('label', btrim(p_label), 'bank', btrim(p_bank_name),
                                                              'account', public.hmy_mask_account(v_number),
                                                              'qr', v_qr is not null, 'auth_method', p_auth_method)));
    return v_id;
  end if;
  select * into v_old from public.receiving_accounts where id = p_id for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  update public.receiving_accounts
  set label = btrim(p_label), account_type = p_account_type, bank_name = btrim(p_bank_name),
      holder_name = btrim(p_holder_name), account_number = v_number, currency = coalesce(p_currency, 'BOB'),
      qr_path = v_qr, notes = nullif(btrim(p_notes), ''),
      verification = case when v_old.account_number is distinct from v_number or v_old.qr_path is distinct from v_qr
                               or v_old.holder_name is distinct from btrim(p_holder_name)
                               or v_old.bank_name is distinct from btrim(p_bank_name)
                          then 'sin_verificar' else v_old.verification end,
      updated_by = auth.uid(), updated_at = now()
  where id = p_id;
  perform public.audit('finance.account_updated', 'receiving_accounts', p_id::text,
                       jsonb_strip_nulls(jsonb_build_object(
                         'account_from', public.hmy_mask_account(v_old.account_number),
                         'account_to', public.hmy_mask_account(v_number),
                         'bank_changed', v_old.bank_name is distinct from btrim(p_bank_name),
                         'holder_changed', v_old.holder_name is distinct from btrim(p_holder_name),
                         'qr_changed', v_old.qr_path is distinct from v_qr, 'auth_method', p_auth_method)));
  return p_id;
end $$;

-- Activar, desactivar o marcar como verificada con el banco.
create function public.owner_set_receiving_account(p_id int, p_active boolean, p_verification text,
                                                   p_auth_method text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_old public.receiving_accounts;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_verification not in ('sin_verificar', 'verificada') then raise exception 'HMY_INVALID_STATUS'; end if;
  select * into v_old from public.receiving_accounts where id = p_id for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'finance.account');
  update public.receiving_accounts
  set is_active = p_active, verification = p_verification, updated_by = auth.uid(), updated_at = now()
  where id = p_id;
  perform public.audit('finance.account_status', 'receiving_accounts', p_id::text,
                       jsonb_build_object('active', p_active, 'verification', p_verification,
                                          'was_active', v_old.is_active, 'was', v_old.verification,
                                          'auth_method', p_auth_method));
end $$;

-- ---------------------------------------------------------------------------
-- Historial de auditoría de dinero
-- ---------------------------------------------------------------------------
create function public.owner_finance_audit(p_limit int default 100)
returns table (id bigint, actor_name text, action text, target_table text, target_id text, details jsonb,
               created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select a.id, coalesce(p.full_name, 'Sistema'), a.action, a.target_table, a.target_id, a.details, a.created_at
  from public.admin_audit_log a
  left join public.profiles p on p.id = a.actor_id
  where a.action like 'finance.%' or a.action like 'topup.%' or a.action like 'wallet.%'
     or a.action like 'commission%' or a.target_table in ('topup_requests', 'wallets', 'wallet_ledger',
                                                          'commission_rules', 'receiving_accounts')
  order by a.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 300);
end $$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_mask_account(text) from public, anon, authenticated;
revoke execute on function public.hmy_require_strong_confirmation(text, text) from public, anon, authenticated;
revoke execute on function public.owner_finance_summary(date) from public, anon;
revoke execute on function public.owner_finance_transactions(text, bigint, int) from public, anon;
revoke execute on function public.owner_topups_reconciliation(text) from public, anon;
revoke execute on function public.owner_reconcile_topup(bigint, text, text, int, text) from public, anon;
revoke execute on function public.owner_receiving_accounts() from public, anon;
revoke execute on function public.owner_save_receiving_account(int, text, text, text, text, text, text, text, text, text)
  from public, anon;
revoke execute on function public.owner_set_receiving_account(int, boolean, text, text) from public, anon;
revoke execute on function public.owner_finance_audit(int) from public, anon;
grant execute on function public.owner_finance_summary(date), public.owner_finance_transactions(text, bigint, int),
  public.owner_topups_reconciliation(text), public.owner_reconcile_topup(bigint, text, text, int, text),
  public.owner_receiving_accounts(),
  public.owner_save_receiving_account(int, text, text, text, text, text, text, text, text, text),
  public.owner_set_receiving_account(int, boolean, text, text), public.owner_finance_audit(int)
  to authenticated;
