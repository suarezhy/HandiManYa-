-- HandiMan ¡Ya! — 0011 Confirmación de identidad para recargas de saldo.
--
-- Cada recarga necesita una confirmación nueva del profesional:
-- - Contraseña: la app vuelve a iniciar sesión con la contraseña (Supabase Auth)
--   y la base exige que ese inicio de sesión sea de hace menos de 5 minutos
--   (claim `amr` del JWT). Cada inicio de sesión sirve para UNA sola operación.
-- - Huella o rostro: lo verifica el teléfono (nunca llega a la base ningún dato
--   biométrico). La base exige que el profesional lo haya activado en
--   Perfil → Seguridad, confirmando antes con su contraseña. No reemplaza la
--   sesión: la base sigue exigiendo un usuario autenticado, dueño de la billetera.
--
-- Además: una clave por intento (client_key) evita solicitudes repetidas por
-- toques dobles o reintentos, y cada solicitud queda en el registro de auditoría.
-- La recarga sigue quedando "pendiente": el saldo solo sube cuando el equipo
-- verifica el pago y la aprueba (review_topup, sin cambios).
--
-- hmy_require_confirmation() es la misma regla para futuras operaciones de
-- dinero (por ejemplo, retiros).

do $$ begin
  if to_regclass('public.service_problems') is null then
    raise exception 'HMY: falta la migración 0010; no se aplicó nada.';
  end if;
  if to_regclass('public.security_settings') is not null then
    raise exception 'HMY: la migración 0011 ya está aplicada; no se aplicó nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Preferencias de seguridad (solo lectura para el dueño; se cambian por función)
-- ---------------------------------------------------------------------------
create table public.security_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  biometric_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.security_settings enable row level security;
create policy security_settings_own on public.security_settings
  for select to authenticated using (user_id = auth.uid());
revoke all on public.security_settings from anon, authenticated;
grant select on public.security_settings to authenticated;

-- Inicios de sesión con contraseña ya usados para confirmar algo.
create table public.security_confirmations (
  user_id uuid not null references public.profiles(id) on delete cascade,
  auth_time bigint not null,
  purpose text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, auth_time)
);
alter table public.security_confirmations enable row level security;
revoke all on public.security_confirmations from anon, authenticated;

-- ---------------------------------------------------------------------------
-- La regla de confirmación
-- ---------------------------------------------------------------------------
create function public.hmy_require_confirmation(p_method text, p_purpose text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_auth_time bigint;
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if p_method = 'password' then
    select max((e ->> 'timestamp')::bigint) into v_auth_time
    from jsonb_array_elements(case when jsonb_typeof(auth.jwt() -> 'amr') = 'array'
                                   then auth.jwt() -> 'amr' else '[]'::jsonb end) e
    where e ->> 'method' = 'password';
    if v_auth_time is null or to_timestamp(v_auth_time) < now() - interval '5 minutes' then
      raise exception 'HMY_CONFIRMATION_EXPIRED';
    end if;
    -- Un inicio de sesión confirma una sola operación.
    insert into public.security_confirmations (user_id, auth_time, purpose)
    values (auth.uid(), v_auth_time, p_purpose)
    on conflict do nothing;
    if not found then raise exception 'HMY_CONFIRMATION_USED'; end if;
  elsif p_method = 'biometric' then
    if not coalesce((select biometric_enabled from public.security_settings where user_id = auth.uid()), false) then
      raise exception 'HMY_BIOMETRIC_DISABLED';
    end if;
  else
    raise exception 'HMY_CONFIRMATION_REQUIRED';
  end if;
end $$;

-- Perfil → Seguridad: activar exige la contraseña recién confirmada; desactivar, no.
create function public.set_biometric_enabled(p_enabled boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if p_enabled then
    perform public.hmy_require_confirmation('password', 'biometric.enable');
  end if;
  insert into public.security_settings (user_id, biometric_enabled, updated_at)
  values (auth.uid(), p_enabled, now())
  on conflict (user_id) do update set biometric_enabled = excluded.biometric_enabled, updated_at = now();
  perform public.audit(case when p_enabled then 'security.biometric_on' else 'security.biometric_off' end,
                       'security_settings', auth.uid()::text, '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Recargas: confirmación obligatoria y sin duplicados
-- ---------------------------------------------------------------------------
alter table public.topup_requests
  add column auth_method text check (auth_method in ('password', 'biometric')),
  add column client_key uuid;
create unique index topup_requests_client_key on public.topup_requests (professional_id, client_key);

drop function public.request_topup(numeric, int, text, text);
create function public.request_topup(p_amount numeric, p_method int, p_reference text, p_proof_path text,
                                     p_auth_method text, p_client_key uuid)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if not exists (select 1 from public.wallets where professional_id = auth.uid()) then
    raise exception 'HMY_WALLET_NOT_FOUND';
  end if;
  if p_client_key is null then raise exception 'HMY_CONFIRMATION_REQUIRED'; end if;
  -- Una solicitud a la vez por profesional, para que dos toques no creen dos.
  perform pg_advisory_xact_lock(hashtextextended('topup:' || auth.uid()::text, 0));
  select id into v_id from public.topup_requests
  where professional_id = auth.uid() and client_key = p_client_key;
  if found then return v_id; end if;  -- el mismo intento repetido: misma solicitud

  if p_amount is null or p_amount <= 0 or p_amount > 10000 or p_amount <> round(p_amount, 2) then
    raise exception 'HMY_INVALID_AMOUNT';
  end if;
  if not exists (select 1 from public.topup_methods where id = p_method and is_active) then
    raise exception 'HMY_INVALID_METHOD';
  end if;
  if p_proof_path is not null and p_proof_path not like auth.uid()::text || '/%' then
    raise exception 'HMY_INVALID_PATH';
  end if;
  if (select count(*) from public.topup_requests where professional_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'HMY_TOO_MANY_PENDING';
  end if;
  perform public.hmy_require_confirmation(p_auth_method, 'wallet.topup');

  insert into public.topup_requests (professional_id, method_id, amount, reference, proof_path, auth_method, client_key)
  values (auth.uid(), p_method, p_amount, nullif(trim(p_reference), ''), p_proof_path, p_auth_method, p_client_key)
  returning id into v_id;
  perform public.audit('topup.request', 'topup_requests', v_id::text,
                       jsonb_build_object('amount', p_amount, 'method_id', p_method, 'auth_method', p_auth_method));
  return v_id;
end $$;

revoke execute on function public.hmy_require_confirmation(text, text) from public, anon, authenticated;
revoke execute on function public.set_biometric_enabled(boolean) from public, anon;
revoke execute on function public.request_topup(numeric, int, text, text, text, uuid) from public, anon;
grant execute on function public.set_biometric_enabled(boolean) to authenticated;
grant execute on function public.request_topup(numeric, int, text, text, text, uuid) to authenticated;
