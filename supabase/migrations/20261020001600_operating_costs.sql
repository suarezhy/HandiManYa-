-- HandiMan ¡Ya! — 0016 costos operativos: uso del plan gratis, cargos
-- proyectados y alertas.
--
-- Regla del dueño: ningún proveedor pagado se activa ni gasta solo.
-- - Cada uso medido (un código por WhatsApp, una verificación de identidad,
--   una llamada a la IA) pasa antes por hmy_cost_gate.
-- - Dentro del plan gratis pasa sin costo. Fuera de él, solo si el dueño
--   autorizó ese proveedor (con su contraseña, código o huella) y sin pasar
--   el tope mensual que fijó. Si no, se frena y se avisa; nunca se cobra
--   "por si acaso".
-- - Bajar un tope o apagar un proveedor no pide confirmación: frenar el gasto
--   tiene que ser fácil.

-- ---------------------------------------------------------------------------
-- Proveedores y precios (los precios se revisan a mano; ver price_source)
-- ---------------------------------------------------------------------------
create table public.cost_vendors (
  key text primary key,
  name text not null,
  category text not null check (category in ('infraestructura', 'identidad', 'mensajes', 'ia', 'tiendas', 'web')),
  unit text not null,
  -- uso: se cobra por unidad; mensual / anual / unico: cuota fija.
  billing text not null check (billing in ('uso', 'mensual', 'anual', 'unico')),
  free_units_month int not null default 0 check (free_units_month >= 0),
  unit_price_usd numeric(10,4) not null default 0 check (unit_price_usd >= 0),
  fixed_usd numeric(10,2) not null default 0 check (fixed_usd >= 0),
  -- off: no se usa. sandbox: solo pruebas, nunca se cobra. free: en uso real,
  -- se frena al acabar el plan gratis. paid: autorizado a cobrar hasta el tope.
  status text not null default 'off' check (status in ('off', 'sandbox', 'free', 'paid')),
  paid_authorized boolean not null default false,
  monthly_cap_usd numeric(10,2) not null default 0 check (monthly_cap_usd >= 0),
  alert_percent smallint not null default 80 check (alert_percent between 1 and 100),
  sandbox_daily_limit int check (sandbox_daily_limit is null or sandbox_daily_limit > 0),
  authorized_by uuid references public.profiles(id),
  authorized_at timestamptz,
  price_source text,
  price_checked_on date,
  notes text,
  sort_order smallint not null default 100,
  updated_at timestamptz not null default now(),
  constraint cost_vendor_paid_needs_authorization check (status <> 'paid' or paid_authorized)
);

insert into public.cost_vendors (key, name, category, unit, billing, free_units_month, unit_price_usd, fixed_usd,
                                 status, sandbox_daily_limit, price_source, price_checked_on, notes, sort_order) values
  ('supabase', 'Supabase (base de datos, cuentas y archivos)', 'infraestructura', 'mes', 'mensual', 0, 0, 25,
   'free', null, 'https://supabase.com/pricing', '2026-10-20',
   'Hoy en el plan Free (USD 0). El plan Pro cuesta USD 25 al mes y solo se contrata con autorización.', 1),
  ('didit_kyc', 'Didit: identidad (carnet, prueba de vida y rostro)', 'identidad', 'verificación', 'uso', 30, 0.33, 0,
   'sandbox', 500, 'https://didit.me/pricing', '2026-10-20',
   'Sandbox gratis e ilimitado. Real: hasta el 31/10/2026, 500 gratis al mes; desde el 1/11/2026, USD 10 de crédito al mes (unas 30 verificaciones) con correo de empresa. El uso real necesita autorización.', 2),
  ('didit_segip', 'Didit: consulta al SEGIP', 'identidad', 'consulta', 'uso', 0, 0.20, 0,
   'off', null, 'https://docs.didit.me/api-reference/database-validation/bolivia/cedula', '2026-10-20',
   'Capa opcional pagada; solo con autorización y cuando el riesgo lo justifique.', 3),
  ('veriff', 'Veriff (respaldo, sin integrar)', 'identidad', 'verificación', 'uso', 0, 0.80, 49,
   'off', null, 'https://veriff.com/plans/self-serve', '2026-10-20',
   'Respaldo posible. No está integrado ni activo.', 4),
  ('whatsapp_otp', 'WhatsApp: códigos de acceso (Meta)', 'mensajes', 'mensaje', 'uso', 0, 0.0113, 0,
   'off', null, 'https://developers.facebook.com/docs/whatsapp/pricing', '2026-10-20',
   'Cada código se cobra. Necesita una cuenta de empresa verificada en Meta.', 5),
  ('sms_otp', 'SMS: códigos de acceso (Twilio)', 'mensajes', 'mensaje', 'uso', 0, 0.2215, 0,
   'off', null, 'https://www.twilio.com/en-us/sms/pricing/bo', '2026-10-20',
   'Respaldo que elige la persona. Cada SMS a Bolivia se cobra.', 6),
  ('push', 'Notificaciones push (Firebase y Apple)', 'mensajes', 'aviso', 'uso', 0, 0, 0,
   'off', null, 'https://firebase.google.com/pricing', '2026-10-20', 'Sin costo por aviso.', 7),
  ('ai_model', 'Modelo de IA', 'ia', 'USD', 'uso', 0, 1, 0,
   'off', null, null, null, 'Los agentes funcionan con reglas, sin IA pagada, mientras el presupuesto sea 0.', 8),
  ('apple_dev', 'Apple Developer Program', 'tiendas', 'año', 'anual', 0, 0, 99,
   'off', null, 'https://developer.apple.com/support/enrollment/', '2026-10-20',
   'Necesario para publicar en el App Store.', 9),
  ('google_play', 'Google Play (registro)', 'tiendas', 'pago único', 'unico', 0, 0, 25,
   'off', null, 'https://support.google.com/googleplay/android-developer/answer/6112435', '2026-10-20',
   'Necesario para publicar en Google Play.', 10),
  ('trip_page', 'Página pública del viaje compartido', 'web', 'mes', 'mensual', 0, 0, 0,
   'off', null, null, null, 'Alojamiento gratis; publicarla necesita autorización.', 11);

-- Cada uso medido, permitido o frenado.
create table public.cost_usage (
  id bigint generated always as identity primary key,
  vendor_key text not null references public.cost_vendors(key),
  occurred_at timestamptz not null default now(),
  units numeric(12,4) not null default 1 check (units > 0),
  sandbox boolean not null default false,
  allowed boolean not null,
  reason text,
  billable_units numeric(12,4) not null default 0,
  cost_usd numeric(10,4) not null default 0,
  ref text
);
create index cost_usage_vendor_time on public.cost_usage (vendor_key, occurred_at desc);

alter table public.cost_vendors enable row level security;
alter table public.cost_usage enable row level security;
revoke all on public.cost_vendors, public.cost_usage from anon, authenticated;
create policy cost_vendors_admin on public.cost_vendors for select to authenticated using (public.is_admin());
create policy cost_usage_admin on public.cost_usage for select to authenticated using (public.is_admin());
grant select on public.cost_vendors, public.cost_usage to authenticated;

create trigger cost_vendors_touch before update on public.cost_vendors
  for each row execute function public.touch_updated_at();

-- Los proveedores facturan por mes calendario en UTC.
create function public.hmy_month_start(p_at timestamptz default now()) returns timestamptz
language sql immutable as $$ select date_trunc('month', p_at, 'UTC') $$;

-- ---------------------------------------------------------------------------
-- La compuerta: ¿se puede usar este proveedor ahora? (la llaman el servidor
-- y las funciones de Supabase, nunca la app)
-- ---------------------------------------------------------------------------
create function public.hmy_cost_gate(p_vendor text, p_units numeric default 1, p_sandbox boolean default false,
                                     p_ref text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v public.cost_vendors;
  v_used numeric;
  v_spent numeric;
  v_free_left numeric;
  v_billable numeric := 0;
  v_cost numeric := 0;
  v_reason text;
  v_id bigint;
begin
  if p_units is null or p_units <= 0 then raise exception 'HMY_INVALID_UNITS'; end if;
  -- Una a la vez por proveedor, para que dos usos simultáneos no pasen el límite.
  select * into v from public.cost_vendors where key = p_vendor for update;
  if not found then raise exception 'HMY_UNKNOWN_VENDOR'; end if;

  if p_sandbox then
    if v.status = 'off' then
      v_reason := 'vendor_off';
    elsif v.sandbox_daily_limit is not null
          and (select coalesce(sum(units), 0) from public.cost_usage
               where vendor_key = p_vendor and sandbox and allowed and occurred_at > now() - interval '24 hours')
              + p_units > v.sandbox_daily_limit then
      v_reason := 'sandbox_limit';
    end if;
  elsif v.status not in ('free', 'paid') then
    v_reason := 'vendor_off';
  elsif v.unit_price_usd > 0 then
    select coalesce(sum(units), 0), coalesce(sum(cost_usd), 0) into v_used, v_spent
    from public.cost_usage
    where vendor_key = p_vendor and allowed and not sandbox and occurred_at >= public.hmy_month_start();
    v_free_left := greatest(v.free_units_month - v_used, 0);
    v_billable := greatest(p_units - v_free_left, 0);
    v_cost := round(v_billable * v.unit_price_usd, 4);
    if v_billable > 0 and v.status <> 'paid' then
      v_reason := 'free_tier_exhausted';
    elsif v_billable > 0 and v_spent + v_cost > v.monthly_cap_usd then
      v_reason := 'monthly_cap';
    end if;
  end if;

  insert into public.cost_usage (vendor_key, units, sandbox, allowed, reason, billable_units, cost_usd, ref)
  values (p_vendor, p_units, p_sandbox, v_reason is null, v_reason,
          case when v_reason is null then v_billable else 0 end, case when v_reason is null then v_cost else 0 end,
          left(p_ref, 120))
  returning id into v_id;

  if v_reason in ('free_tier_exhausted', 'monthly_cap') then
    perform public.hmy_raise_item('finance', 'alert', 'high', 'rule',
      format('%s: se frenó un uso pagado', v.name),
      case v_reason
        when 'free_tier_exhausted' then 'Se acabó el plan gratis de este mes. No se cobró nada: el uso queda frenado hasta el próximo mes o hasta que autorices un tope.'
        else format('Se llegó al tope mensual de USD %s. No se cobró de más: el uso queda frenado hasta que subas el tope o empiece el próximo mes.', v.monthly_cap_usd)
      end,
      jsonb_build_object('vendor', p_vendor, 'reason', v_reason),
      format('cost:%s:%s:%s', p_vendor, v_reason, to_char(public.hmy_month_start(), 'YYYY-MM')),
      'cost_vendors', p_vendor);
  end if;

  return jsonb_build_object('allowed', v_reason is null, 'reason', v_reason, 'cost_usd', v_cost,
                            'billable_units', v_billable, 'id', v_id);
end $$;

-- ---------------------------------------------------------------------------
-- Códigos de acceso: además de los límites por número, el presupuesto.
-- (Igual que en 0013, con la compuerta de costos al final.)
-- ---------------------------------------------------------------------------
create or replace function public.hmy_otp_gate(p_phone text, p_channel text default null, p_user uuid default null)
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
  elsif not (public.hmy_cost_gate(case p_channel when 'sms' then 'sms_otp' else 'whatsapp_otp' end, 1, false,
                                  'otp') ->> 'allowed')::boolean then
    v_reason := 'budget';
  end if;
  insert into public.otp_sends (phone, channel, user_id, allowed, reason)
  values (v_phone, p_channel, p_user, v_reason is null, v_reason)
  returning id into v_id;
  return jsonb_build_object('allowed', v_reason is null, 'reason', v_reason, 'retry_after', v_retry, 'id', v_id,
                            'channel', p_channel, 'phone', v_phone);
end $$;

-- ---------------------------------------------------------------------------
-- Tablero mensual: uso gratis, cargos hasta hoy, proyección y alertas
-- ---------------------------------------------------------------------------
create function public.hmy_cost_month(p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := public.hmy_month_start(p_month::timestamptz);
  v_to timestamptz := v_from + interval '1 month';
  v_now timestamptz := least(now(), v_to);
  -- Fracción del mes que ya pasó (mínimo un día, para no proyectar al infinito).
  v_elapsed numeric := greatest(extract(epoch from v_now - v_from) / 86400, 1);
  v_days numeric := extract(epoch from v_to - v_from) / 86400;
  v_vendors jsonb := '[]'::jsonb;
  v_alerts jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_projected numeric := 0;
  v_one_time numeric := 0;
  r record;
  v_proj_units numeric;
  v_proj_cost numeric;
  v_fixed numeric;
  v_level text;
  v_runs_out date;
  v_used numeric;
  v_spent numeric;
begin
  for r in
    select cv.*,
           coalesce(sum(u.units) filter (where u.allowed and not u.sandbox), 0) as used,
           coalesce(sum(u.units) filter (where u.allowed and u.sandbox), 0) as sandbox_used,
           coalesce(sum(u.cost_usd) filter (where u.allowed and not u.sandbox), 0) as spent,
           count(*) filter (where not u.allowed and u.reason in ('free_tier_exhausted', 'monthly_cap', 'vendor_off')
                            and not u.sandbox) as blocked
    from public.cost_vendors cv
    left join public.cost_usage u on u.vendor_key = cv.key and u.occurred_at >= v_from and u.occurred_at < v_to
    group by cv.key
    order by cv.sort_order
  loop
    -- La IA: el gasto real lo registra cada ejecución de un agente.
    v_used := r.used;
    v_spent := r.spent;
    if r.key = 'ai_model' then
      select coalesce(sum(cost_usd), 0) into v_spent from public.ai_agent_runs
      where started_at >= v_from and started_at < v_to;
      v_used := v_spent;
    end if;
    v_proj_units := round(v_used / v_elapsed * v_days, 1);
    v_proj_cost := case when r.unit_price_usd > 0
                        then round(greatest(v_proj_units - r.free_units_month, 0) * r.unit_price_usd, 2) else 0 end;
    if r.status = 'paid' then v_proj_cost := least(v_proj_cost, r.monthly_cap_usd); else v_proj_cost := 0; end if;
    v_fixed := case when r.status = 'paid' and r.billing = 'mensual' then r.fixed_usd
                    when r.status = 'paid' and r.billing = 'anual' then round(r.fixed_usd / 12, 2) else 0 end;
    v_runs_out := case when r.free_units_month > 0 and v_used > 0 and v_proj_units > r.free_units_month
                       then (v_from + make_interval(days => ceil(r.free_units_month / (v_used / v_elapsed))::int))::date end;
    v_level := case
      when r.blocked > 0 then 'blocked'
      when r.status = 'paid' and r.monthly_cap_usd > 0 and v_spent >= r.monthly_cap_usd * r.alert_percent / 100.0 then 'near_cap'
      when r.free_units_month > 0 and v_used >= r.free_units_month * r.alert_percent / 100.0 then 'near_free_limit'
      when v_runs_out is not null and v_runs_out < v_to::date then 'will_run_out'
      else 'ok' end;
    if v_level <> 'ok' then
      v_alerts := v_alerts || jsonb_build_object('vendor', r.key, 'level', v_level, 'message',
        case v_level
          when 'blocked' then format('%s: se frenaron %s usos este mes por falta de autorización o por el tope. No se cobró nada de más.', r.name, r.blocked)
          when 'near_cap' then format('%s: ya se gastó USD %s de un tope de USD %s.', r.name, round(v_spent, 2), r.monthly_cap_usd)
          when 'near_free_limit' then format('%s: se usó %s de %s gratis este mes.', r.name, v_used, r.free_units_month)
          else format('%s: al ritmo actual, el plan gratis se acaba el %s. Después se frena; no se cobra sin tu autorización.',
                      r.name, to_char(v_runs_out, 'DD/MM'))
        end);
    end if;
    v_total := v_total + v_spent;
    v_projected := v_projected + v_proj_cost + v_fixed;
    v_one_time := v_one_time + case when r.status = 'paid' and r.billing = 'unico' then r.fixed_usd else 0 end;
    v_vendors := v_vendors || jsonb_build_object(
      'key', r.key, 'name', r.name, 'category', r.category, 'unit', r.unit, 'billing', r.billing,
      'status', r.status, 'paid_authorized', r.paid_authorized,
      'free_units', r.free_units_month, 'used_units', v_used, 'sandbox_units', r.sandbox_used,
      'free_left', greatest(r.free_units_month - v_used, 0),
      'free_used_percent', case when r.free_units_month > 0 then least(round(100 * v_used / r.free_units_month), 100) end,
      'unit_price_usd', r.unit_price_usd, 'fixed_usd', r.fixed_usd,
      'cost_so_far_usd', round(v_spent, 2), 'projected_units', v_proj_units,
      'projected_usd', v_proj_cost + v_fixed, 'monthly_cap_usd', r.monthly_cap_usd,
      'alert_percent', r.alert_percent, 'blocked', r.blocked, 'level', v_level, 'runs_out_on', v_runs_out,
      'price_source', r.price_source, 'price_checked_on', r.price_checked_on, 'notes', r.notes);
  end loop;
  return jsonb_build_object('month', to_char(v_from, 'YYYY-MM'), 'days_elapsed', round(v_elapsed, 1),
                            'days_in_month', v_days, 'cost_so_far_usd', round(v_total, 2),
                            'projected_usd', round(v_projected, 2), 'one_time_usd', v_one_time,
                            'vendors', v_vendors, 'alerts', v_alerts);
end $$;

create function public.admin_cost_dashboard(p_month date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_month date := coalesce(p_month, (now() at time zone 'UTC')::date);
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.hmy_cost_month(v_month) || jsonb_build_object('history', (
    select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
             'cost_usd', (select coalesce(round(sum(cost_usd), 2), 0) from public.cost_usage
                          where allowed and not sandbox and occurred_at >= m and occurred_at < m + interval '1 month')
                         + (select coalesce(round(sum(cost_usd), 2), 0) from public.ai_agent_runs
                            where started_at >= m and started_at < m + interval '1 month'))
             order by m desc), '[]'::jsonb)
    from generate_series(public.hmy_month_start(v_month::timestamptz) - interval '5 months',
                         public.hmy_month_start(v_month::timestamptz), interval '1 month') m));
end $$;

-- ---------------------------------------------------------------------------
-- Autorizar o frenar un proveedor
-- ---------------------------------------------------------------------------
create function public.admin_set_vendor(p_key text, p_status text, p_monthly_cap_usd numeric default 0,
                                        p_auth_method text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.cost_vendors;
  v_rank_old int;
  v_rank_new int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into v from public.cost_vendors where key = p_key for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if p_status not in ('off', 'sandbox', 'free', 'paid') or p_monthly_cap_usd is null or p_monthly_cap_usd < 0
     or p_monthly_cap_usd > 10000 then
    raise exception 'HMY_INVALID_SETTING';
  end if;
  if p_status = 'paid' and p_monthly_cap_usd = 0 and v.billing = 'uso' then raise exception 'HMY_CAP_REQUIRED'; end if;
  if p_status = 'sandbox' and v.sandbox_daily_limit is null then raise exception 'HMY_NO_SANDBOX'; end if;
  v_rank_old := array_position(array['off', 'sandbox', 'free', 'paid'], v.status);
  v_rank_new := array_position(array['off', 'sandbox', 'free', 'paid'], p_status);
  -- Más uso real o más gasto: confirma que es el dueño. Frenar no lo pide.
  if v_rank_new > v_rank_old or (p_status = 'paid' and p_monthly_cap_usd > v.monthly_cap_usd) then
    perform public.hmy_require_confirmation(p_auth_method, 'costs.' || p_key);
  end if;
  update public.cost_vendors
  set status = p_status,
      paid_authorized = p_status = 'paid',
      monthly_cap_usd = case when p_status = 'paid' then p_monthly_cap_usd else 0 end,
      authorized_by = case when p_status = 'paid' then auth.uid() end,
      authorized_at = case when p_status = 'paid' then now() end
  where key = p_key;
  -- El presupuesto de IA es el mismo tope.
  if p_key = 'ai_model' then
    update public.app_settings
    set value = jsonb_set(value, '{monthly_usd}', to_jsonb(case when p_status = 'paid' then p_monthly_cap_usd else 0 end)),
        updated_by = auth.uid(), updated_at = now()
    where key = 'ai_budget';
  end if;
  perform public.audit('costs.vendor', 'cost_vendors', p_key,
                       jsonb_build_object('from', v.status, 'to', p_status, 'cap_usd', p_monthly_cap_usd));
end $$;

-- admin_set_setting('ai_budget') también mueve el tope del proveedor de IA.
create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_auth_method text default null)
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
    update public.cost_vendors
    set status = case when (p_value ->> 'monthly_usd')::numeric > 0 then 'paid' else 'off' end,
        paid_authorized = (p_value ->> 'monthly_usd')::numeric > 0,
        monthly_cap_usd = (p_value ->> 'monthly_usd')::numeric,
        authorized_by = auth.uid(), authorized_at = now()
    where key = 'ai_model';
  else
    raise exception 'HMY_INVALID_SETTING';
  end if;
  update public.app_settings set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
  perform public.audit('settings.' || p_key, 'app_settings', p_key, p_value);
end $$;

-- ---------------------------------------------------------------------------
-- Monitor de costos (reglas, sin IA): avisa antes de que algo se frene
-- ---------------------------------------------------------------------------
create function public.run_cost_monitors()
returns int
language plpgsql security definer set search_path = public as $$
declare
  a jsonb;
  n int := 0;
  v_month text := to_char(public.hmy_month_start(), 'YYYY-MM');
begin
  for a in select * from jsonb_array_elements(public.hmy_cost_month((now() at time zone 'UTC')::date) -> 'alerts') loop
    if public.hmy_raise_item('finance', 'alert',
         case a ->> 'level' when 'blocked' then 'high' when 'near_cap' then 'high' else 'medium' end, 'rule',
         'Costos: ' || left(a ->> 'message', 180), a ->> 'message', a,
         format('cost:%s:%s:%s', a ->> 'vendor', a ->> 'level', v_month), 'cost_vendors', a ->> 'vendor') is not null then
      n := n + 1;
    end if;
  end loop;
  update public.ai_agents set last_run_at = now(), last_run_status = 'ok' where key = 'finance';
  return n;
end $$;

create function public.admin_run_cost_monitors()
returns int
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return public.run_cost_monitors();
end $$;

update public.ai_agents
set purpose = 'Comisiones cobradas (ingreso real), separadas de las recargas; uso de los planes gratis, cargos proyectados y alertas de gasto. Frena cualquier gasto no autorizado.',
    needs = null
where key = 'finance';

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public.hmy_month_start(timestamptz) from public, anon, authenticated;
revoke execute on function public.hmy_cost_gate(text, numeric, boolean, text) from public, anon, authenticated;
revoke execute on function public.hmy_cost_month(date) from public, anon, authenticated;
revoke execute on function public.run_cost_monitors() from public, anon, authenticated;
revoke execute on function public.admin_cost_dashboard(date) from public, anon;
revoke execute on function public.admin_set_vendor(text, text, numeric, text) from public, anon;
revoke execute on function public.admin_run_cost_monitors() from public, anon;
revoke execute on function public.admin_set_setting(text, jsonb, text) from public, anon;
grant execute on function public.hmy_cost_gate(text, numeric, boolean, text) to service_role;
grant execute on function public.admin_cost_dashboard(date), public.admin_set_vendor(text, text, numeric, text),
  public.admin_run_cost_monitors(), public.admin_set_setting(text, jsonb, text) to authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hmy-cost-monitors', '12 * * * *', 'select public.run_cost_monitors()');
  end if;
end $$;
