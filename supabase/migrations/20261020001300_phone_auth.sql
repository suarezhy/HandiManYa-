-- HandiMan ¡Ya! — 0013 Ingreso con número de celular.
--
-- Una sola pantalla: la persona escribe su celular (+591), elige WhatsApp o
-- SMS y recibe un código de 6 dígitos. Supabase Auth genera el código, lo
-- vence y lo verifica (inicio de sesión por teléfono). Si el número es nuevo,
-- Supabase crea la cuenta; si ya existe, entra a esa misma cuenta. Un número
-- es una sola cuenta (auth.users.phone es único), con rol de cliente y, si lo
-- aprobamos, de profesional. El correo pasa a ser opcional.
--
-- Esta migración:
-- - Copia el celular verificado de Supabase Auth al perfil (al crear la
--   cuenta y al cambiar de número). La app ya no puede escribir el celular
--   del perfil: solo Supabase Auth, después de verificar un código.
-- - Impide dos perfiles con el mismo celular.
-- - complete_signup(): nombre, ciudad y aceptación de términos después del código.
-- - La confirmación de operaciones de dinero acepta un código nuevo ('otp')
--   además de la contraseña (cuentas antiguas) y la huella o el rostro.
-- - Límites de envío de códigos (por número y en total) para el servicio que
--   los manda por WhatsApp o SMS. Ese servicio es pago y queda apagado hasta
--   que el dueño lo apruebe: sin él, Supabase no envía ningún código.
--
-- Las cuentas creadas con correo siguen funcionando y conservan sus pedidos,
-- perfiles profesionales y billeteras (el id de la cuenta no cambia). Para
-- pasarse al celular, entran con un código a su correo y agregan su número.

do $$ begin
  if to_regclass('public.security_settings') is null then
    raise exception 'HMY: falta la migración 0011; no se aplicó nada.';
  end if;
  if to_regclass('public.otp_sends') is not null then
    raise exception 'HMY: la migración 0013 ya está aplicada; no se aplicó nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Celular de Supabase Auth → perfil
-- ---------------------------------------------------------------------------
-- Supabase guarda el número sin "+" (59171234567). Devuelve +59171234567 si
-- es un celular boliviano; si no, null.
create function public.hmy_auth_phone(p_phone text) returns text
language sql immutable set search_path = public as $$
  select case when '+' || ltrim(coalesce(p_phone, ''), '+') ~ '^\+591[67][0-9]{7}$'
              then '+' || ltrim(p_phone, '+') end
$$;

-- Un celular sin verificar de una cuenta antigua (escrito a mano) no puede
-- bloquear a quien sí verificó ese número: se le quita a la cuenta antigua.
create function public.hmy_claim_phone(p_user uuid, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set phone = null
  where phone = p_phone and id <> p_user and phone_verified_at is null;
  if found then
    insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
    values (null, 'auth.phone_released', 'profiles', p_phone,
            jsonb_build_object('verified_by', p_user, 'reason', 'otra cuenta verificó este número'));
  end if;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_city smallint;
  v_phone text;
  v_verified timestamptz;
begin
  begin
    v_city := nullif(new.raw_user_meta_data ->> 'city_id', '')::smallint;
  exception when others then
    v_city := null;
  end;
  if v_city is not null and not exists (select 1 from public.cities where id = v_city) then
    v_city := null;
  end if;

  v_phone := public.hmy_auth_phone(new.phone);
  if v_phone is not null then
    -- Cuenta por celular: el número es el de Supabase Auth.
    v_verified := new.phone_confirmed_at;
    if v_verified is not null then
      perform public.hmy_claim_phone(new.id, v_phone);
    elsif exists (select 1 from public.profiles where phone = v_phone) then
      v_phone := null;  -- se copia al verificar el código (hmy_sync_auth_phone)
    end if;
  else
    -- Cuenta antigua por correo: el número que escribió, sin verificar.
    v_phone := nullif(new.raw_user_meta_data ->> 'phone', '');
    if v_phone is not null and (v_phone !~ '^\+591[67][0-9]{7}$'
                                or exists (select 1 from public.profiles where phone = v_phone)) then
      v_phone := null;
    end if;
  end if;

  insert into public.profiles (id, full_name, phone, phone_verified_at, city_id, terms_accepted_at)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120),
    v_phone,
    case when v_phone is not null then v_verified end,
    v_city,
    case when (new.raw_user_meta_data ->> 'terms_accepted') = 'true' then now() end
  );
  insert into public.user_roles (user_id, role) values (new.id, 'customer');
  return new;
end $$;

-- Al verificar el código (cuenta nueva o cambio de número), el perfil toma
-- el número verificado.
create function public.hmy_sync_auth_phone() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_phone text := public.hmy_auth_phone(new.phone);
begin
  if v_phone is null or new.phone_confirmed_at is null then return new; end if;
  if v_phone is not distinct from public.hmy_auth_phone(old.phone)
     and old.phone_confirmed_at is not null then
    return new;
  end if;
  perform public.hmy_claim_phone(new.id, v_phone);
  update public.profiles set phone = v_phone, phone_verified_at = new.phone_confirmed_at
  where id = new.id;
  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (new.id, case when old.phone_confirmed_at is null and old.phone is not distinct from new.phone
                       then 'auth.phone_verified' else 'auth.phone_changed' end,
          'profiles', new.id::text, jsonb_build_object('phone', v_phone));
  return new;
end $$;

create trigger on_auth_user_phone after update of phone, phone_confirmed_at on auth.users
  for each row execute function public.hmy_sync_auth_phone();

-- Un celular, un perfil. Si dos cuentas antiguas escribieron el mismo número
-- (sin verificar), lo conserva la más antigua.
update public.profiles p set phone = null
where p.phone is not null and p.phone_verified_at is null
  and exists (select 1 from public.profiles q
              where q.phone = p.phone and q.id <> p.id
                and (q.phone_verified_at is not null or q.created_at < p.created_at
                     or (q.created_at = p.created_at and q.id < p.id)));
create unique index profiles_phone_unique on public.profiles (phone) where phone is not null;

-- El celular del perfil ya no se escribe desde la app; los términos se
-- aceptan con complete_signup().
revoke update on public.profiles from authenticated;
grant update (full_name, city_id, avatar_path) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Después del código: nombre, ciudad y términos
-- ---------------------------------------------------------------------------
create function public.complete_signup(p_full_name text, p_city_id smallint, p_accept_terms boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if char_length(v_name) < 3 or char_length(v_name) > 120 then raise exception 'HMY_INVALID_NAME'; end if;
  if not exists (select 1 from public.cities where id = p_city_id and is_active) then
    raise exception 'HMY_INVALID_CITY';
  end if;
  if not coalesce(p_accept_terms, false) then raise exception 'HMY_TERMS_REQUIRED'; end if;
  update public.profiles
  set full_name = v_name, city_id = p_city_id, terms_accepted_at = coalesce(terms_accepted_at, now())
  where id = auth.uid();
end $$;

create or replace function public.my_account() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'email', u.email, 'email_confirmed', u.email_confirmed_at is not null,
    'full_name', p.full_name, 'phone', p.phone, 'phone_verified', p.phone_verified_at is not null,
    'city_id', p.city_id, 'active_role', p.active_role,
    'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = p.id), '[]'::jsonb),
    'professional_status', coalesce((select status::text from public.professional_profiles where user_id = p.id), 'not_started'),
    'onboarding_completed', p.onboarding_completed_at is not null,
    'deletion_requested', p.deletion_requested_at is not null,
    'profile_complete', char_length(btrim(p.full_name)) >= 3 and p.city_id is not null and p.terms_accepted_at is not null
  )
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Confirmación de operaciones de dinero: también con un código nuevo
-- ---------------------------------------------------------------------------
-- Cada método lleva su propia hora de inicio de sesión: el registro de usos
-- distingue contraseña y código.
alter table public.security_confirmations add column method text not null default 'password';
alter table public.security_confirmations drop constraint security_confirmations_pkey;
alter table public.security_confirmations add primary key (user_id, auth_time, method);

-- 'otp': la app pide un código al celular de la cuenta y lo verifica; eso es
-- un inicio de sesión nuevo (claim amr "otp"). Igual que la contraseña: de
-- hace menos de 5 minutos y sirve para una sola operación.
create or replace function public.hmy_require_confirmation(p_method text, p_purpose text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_auth_time bigint;
  v_amr text[] := case p_method when 'password' then array['password'] when 'otp' then array['otp', 'sms'] end;
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if v_amr is not null then
    select max((e ->> 'timestamp')::bigint) into v_auth_time
    from jsonb_array_elements(case when jsonb_typeof(auth.jwt() -> 'amr') = 'array'
                                   then auth.jwt() -> 'amr' else '[]'::jsonb end) e
    where e ->> 'method' = any (v_amr);
    if v_auth_time is null or to_timestamp(v_auth_time) < now() - interval '5 minutes' then
      raise exception 'HMY_CONFIRMATION_EXPIRED';
    end if;
    -- Un inicio de sesión confirma una sola operación.
    insert into public.security_confirmations (user_id, auth_time, purpose, method)
    values (auth.uid(), v_auth_time, p_purpose, p_method)
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

-- Activar huella o rostro: con un código nuevo (o la contraseña en cuentas antiguas).
drop function public.set_biometric_enabled(boolean);
create function public.set_biometric_enabled(p_enabled boolean, p_auth_method text default 'password')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if p_enabled then
    if p_auth_method not in ('password', 'otp') then raise exception 'HMY_CONFIRMATION_REQUIRED'; end if;
    perform public.hmy_require_confirmation(p_auth_method, 'biometric.enable');
  end if;
  insert into public.security_settings (user_id, biometric_enabled, updated_at)
  values (auth.uid(), p_enabled, now())
  on conflict (user_id) do update set biometric_enabled = excluded.biometric_enabled, updated_at = now();
  perform public.audit(case when p_enabled then 'security.biometric_on' else 'security.biometric_off' end,
                       'security_settings', auth.uid()::text, jsonb_build_object('auth_method', p_auth_method));
end $$;

alter table public.topup_requests drop constraint topup_requests_auth_method_check;
alter table public.topup_requests
  add constraint topup_requests_auth_method_check check (auth_method in ('password', 'otp', 'biometric'));

-- ---------------------------------------------------------------------------
-- Límites de envío de códigos (los usa el servicio que manda WhatsApp o SMS)
-- ---------------------------------------------------------------------------
create table public.otp_sends (
  id bigint generated always as identity primary key,
  phone text not null,
  channel text not null check (channel in ('sms', 'whatsapp')),
  user_id uuid,
  allowed boolean not null,
  reason text,
  delivered boolean,
  provider text,
  error text,
  created_at timestamptz not null default now()
);
create index otp_sends_phone_time on public.otp_sends (phone, created_at desc);
create index otp_sends_time on public.otp_sends (created_at desc);
alter table public.otp_sends enable row level security;
revoke all on public.otp_sends from anon, authenticated;
create policy otp_sends_admin on public.otp_sends for select to authenticated using (public.is_admin());
grant select on public.otp_sends to authenticated;

-- Supabase no le dice al servicio de envío si la persona eligió WhatsApp o
-- SMS: la app guarda la elección justo antes de pedir el código.
create table public.otp_channel_choices (
  phone text primary key,
  channel text not null check (channel in ('sms', 'whatsapp')),
  updated_at timestamptz not null default now()
);
alter table public.otp_channel_choices enable row level security;
revoke all on public.otp_channel_choices from anon, authenticated;

create function public.choose_code_channel(p_phone text, p_channel text) returns void
language plpgsql security definer set search_path = public as $$
declare v_phone text := public.hmy_auth_phone(p_phone);
begin
  if v_phone is null then raise exception 'HMY_INVALID_PHONE'; end if;
  if p_channel not in ('sms', 'whatsapp') then raise exception 'HMY_INVALID_CHANNEL'; end if;
  insert into public.otp_channel_choices (phone, channel) values (v_phone, p_channel)
  on conflict (phone) do update set channel = excluded.channel, updated_at = now();
end $$;

-- Por número: 1 por minuto, 5 por hora, 10 por día. En total: 300 por hora
-- (frena el fraude de SMS masivos). Solo celulares de Bolivia.
-- p_channel null: el que eligió la persona (WhatsApp si no eligió).
create function public.hmy_otp_gate(p_phone text, p_channel text default null, p_user uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := public.hmy_auth_phone(p_phone);
  v_last timestamptz;
  v_reason text;
  v_retry int;
  v_id bigint;
begin
  if v_phone is null then
    return jsonb_build_object('allowed', false, 'reason', 'invalid_phone');
  end if;
  p_channel := coalesce(p_channel, (select channel from public.otp_channel_choices where phone = v_phone), 'whatsapp');
  if p_channel not in ('sms', 'whatsapp') then
    return jsonb_build_object('allowed', false, 'reason', 'invalid_channel');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('otp:' || v_phone, 0));
  select max(created_at) into v_last from public.otp_sends where phone = v_phone and allowed;
  if v_last > now() - interval '60 seconds' then
    v_reason := 'too_soon';
    v_retry := greatest(1, ceil(extract(epoch from v_last + interval '60 seconds' - now()))::int);
  elsif (select count(*) from public.otp_sends
         where phone = v_phone and allowed and created_at > now() - interval '1 hour') >= 5 then
    v_reason := 'hourly_limit';
  elsif (select count(*) from public.otp_sends
         where phone = v_phone and allowed and created_at > now() - interval '24 hours') >= 10 then
    v_reason := 'daily_limit';
  elsif (select count(*) from public.otp_sends where allowed and created_at > now() - interval '1 hour') >= 300 then
    v_reason := 'global_limit';
  end if;
  insert into public.otp_sends (phone, channel, user_id, allowed, reason)
  values (v_phone, p_channel, p_user, v_reason is null, v_reason)
  returning id into v_id;
  return jsonb_build_object('allowed', v_reason is null, 'reason', v_reason, 'retry_after', v_retry, 'id', v_id,
                            'channel', p_channel, 'phone', v_phone);
end $$;

create function public.hmy_otp_result(p_id bigint, p_delivered boolean, p_provider text, p_error text default null)
returns void
language sql security definer set search_path = public as $$
  update public.otp_sends set delivered = p_delivered, provider = left(p_provider, 40), error = left(p_error, 300)
  where id = p_id
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_auth_phone(text) from public, anon, authenticated;
revoke execute on function public.hmy_claim_phone(uuid, text) from public, anon, authenticated;
revoke execute on function public.hmy_sync_auth_phone() from public, anon, authenticated;
revoke execute on function public.hmy_require_confirmation(text, text) from public, anon, authenticated;
revoke execute on function public.complete_signup(text, smallint, boolean) from public, anon;
revoke execute on function public.set_biometric_enabled(boolean, text) from public, anon;
revoke execute on function public.hmy_otp_gate(text, text, uuid) from public, anon, authenticated;
revoke execute on function public.choose_code_channel(text, text) from public;
grant execute on function public.choose_code_channel(text, text) to anon, authenticated;
revoke execute on function public.hmy_otp_result(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.complete_signup(text, smallint, boolean) to authenticated;
grant execute on function public.set_biometric_enabled(boolean, text) to authenticated;
grant execute on function public.hmy_otp_gate(text, text, uuid) to service_role;
grant execute on function public.hmy_otp_result(bigint, boolean, text, text) to service_role;
