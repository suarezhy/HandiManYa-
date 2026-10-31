-- HandiMan ¡Ya! — 0009 panel de administración, reportes, bloqueos,
-- suspensiones, consentimientos, límites de uso y registro de auditoría.
--
-- Solo agrega: no borra tablas ni datos. Todo cambio de un administrador
-- queda en admin_audit_log.

-- ---------------------------------------------------------------------------
-- Suspensión de cuentas
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column suspended_at timestamptz,
  add column suspension_reason text check (suspension_reason is null or char_length(suspension_reason) <= 500);
-- Las columnas nuevas no tienen permiso de UPDATE para los usuarios (ver 0001):
-- solo cambian con admin_set_suspension.

create function public.is_suspended(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = p_user and suspended_at is not null)
$$;

-- ---------------------------------------------------------------------------
-- Bloqueos entre usuarios
-- ---------------------------------------------------------------------------
create table public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create function public.hmy_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_blocks
                 where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a))
$$;

create function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_user = auth.uid() or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'HMY_NOT_FOUND';
  end if;
  insert into public.user_blocks (blocker_id, blocked_id) values (auth.uid(), p_user) on conflict do nothing;
end $$;

create function public.unblock_user(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.user_blocks where blocker_id = auth.uid() and blocked_id = p_user
$$;

-- ¡Ya! no envía ofertas a profesionales bloqueados por el cliente (o que lo bloquearon).
create or replace function public.ya_eligible_professionals(p_category int, p_city smallint, p_zone int, p_customer uuid,
                                                            p_latitude numeric default null, p_longitude numeric default null)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  join public.profiles pr on pr.id = pp.user_id
  left join public.professional_locations pl on pl.professional_id = pp.user_id
  where pp.status = 'approved'
    and pp.is_available
    and pr.suspended_at is null
    and pp.user_id <> p_customer
    and pp.city_id = p_city
    and not public.hmy_blocked_between(pp.user_id, p_customer)
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and case
      when p_latitude is not null and pl.base_latitude is not null then
        public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) <= pl.service_radius_km
      else
        p_zone is null
        or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
        or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone)
    end
  order by public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) asc nulls last,
           pp.rating_avg desc, pp.available_since asc nulls last
  limit 25
$$;

-- ---------------------------------------------------------------------------
-- Reglas al crear pedidos, mensajes y tickets: cuenta activa, sin bloqueo y
-- con límite de uso (evita abuso y spam).
-- ---------------------------------------------------------------------------
create function public.guard_new_booking() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_suspended(new.customer_id) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  if new.professional_id is not null and public.hmy_blocked_between(new.customer_id, new.professional_id) then
    raise exception 'HMY_BLOCKED';
  end if;
  if (select count(*) from public.bookings
      where customer_id = new.customer_id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'HMY_RATE_LIMITED';
  end if;
  return new;
end $$;

create trigger bookings_guard before insert on public.bookings
  for each row execute function public.guard_new_booking();

create function public.guard_new_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.conversations;
begin
  if public.is_suspended(new.sender_id) then raise exception 'HMY_ACCOUNT_SUSPENDED'; end if;
  select * into c from public.conversations where id = new.conversation_id;
  if public.hmy_blocked_between(c.customer_id, c.professional_id) then raise exception 'HMY_BLOCKED'; end if;
  if (select count(*) from public.messages
      where sender_id = new.sender_id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'HMY_RATE_LIMITED';
  end if;
  return new;
end $$;

create trigger messages_guard before insert on public.messages
  for each row execute function public.guard_new_message();

create function public.guard_new_ticket() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.support_tickets
      where user_id = new.user_id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'HMY_RATE_LIMITED';
  end if;
  return new;
end $$;

create trigger support_tickets_guard before insert on public.support_tickets
  for each row execute function public.guard_new_ticket();

-- Un profesional suspendido no puede ponerse disponible ni aceptar.
create function public.guard_pro_available() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_available and not old.is_available and public.is_suspended(new.user_id) then
    raise exception 'HMY_ACCOUNT_SUSPENDED';
  end if;
  return new;
end $$;

create trigger professional_profiles_guard before update of is_available on public.professional_profiles
  for each row execute function public.guard_pro_available();

-- ---------------------------------------------------------------------------
-- Reportes de usuarios
-- ---------------------------------------------------------------------------
create table public.user_reports (
  id bigserial primary key,
  reporter_id uuid not null references public.profiles(id),
  reported_id uuid not null references public.profiles(id),
  booking_id uuid references public.bookings(id),
  reason text not null check (reason in ('no_se_presento', 'mal_trabajo', 'cobro_indebido', 'acoso',
                                         'fraude', 'contenido_inapropiado', 'otro')),
  details text check (details is null or char_length(details) <= 1500),
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  resolution text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check (reporter_id <> reported_id)
);
create index user_reports_status_idx on public.user_reports (status, created_at);

create function public.report_user(p_user uuid, p_reason text, p_details text default null,
                                   p_booking uuid default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if p_user = auth.uid() or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'HMY_NOT_FOUND';
  end if;
  if p_booking is not null and not exists (
    select 1 from public.bookings where id = p_booking
      and auth.uid() in (customer_id, professional_id) and p_user in (customer_id, professional_id)
  ) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if (select count(*) from public.user_reports
      where reporter_id = auth.uid() and created_at > now() - interval '1 day') >= 5 then
    raise exception 'HMY_RATE_LIMITED';
  end if;
  insert into public.user_reports (reporter_id, reported_id, booking_id, reason, details)
  values (auth.uid(), p_user, p_booking, p_reason, nullif(trim(p_details), ''))
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Consentimientos (qué versión de cada documento aceptó cada usuario)
-- ---------------------------------------------------------------------------
create table public.consent_records (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  document text not null check (document in ('terminos', 'privacidad', 'cancelaciones', 'comisiones',
                                             'reglas_profesionales', 'uso_aceptable', 'ubicacion')),
  version text not null check (char_length(version) between 1 and 40),
  accepted_at timestamptz not null default now(),
  unique (user_id, document, version)
);

create function public.record_consent(p_document text, p_version text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  insert into public.consent_records (user_id, document, version) values (auth.uid(), p_document, p_version)
  on conflict do nothing;
  if p_document = 'terminos' then
    update public.profiles set terms_accepted_at = coalesce(terms_accepted_at, now()) where id = auth.uid();
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Auditoría automática de cambios del administrador en la configuración
-- ---------------------------------------------------------------------------
create function public.audit_admin_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
begin
  if public.is_admin() then
    perform public.audit(tg_table_name || '.' || lower(tg_op), tg_table_name,
                         coalesce(v_new ->> 'id', v_old ->> 'id'),
                         jsonb_strip_nulls(jsonb_build_object('old', v_old, 'new', v_new)));
  end if;
  return coalesce(new, old);
end $$;

create trigger commission_rules_audit after insert or update or delete on public.commission_rules
  for each row execute function public.audit_admin_change();
create trigger topup_methods_audit after insert or update or delete on public.topup_methods
  for each row execute function public.audit_admin_change();
create trigger service_categories_audit after insert or update or delete on public.service_categories
  for each row execute function public.audit_admin_change();
create trigger cities_audit after insert or update or delete on public.cities
  for each row execute function public.audit_admin_change();
create trigger service_zones_audit after insert or update or delete on public.service_zones
  for each row execute function public.audit_admin_change();
create trigger promotions_audit after insert or update or delete on public.promotions
  for each row execute function public.audit_admin_change();

-- Las decisiones de verificación también quedan en la auditoría.
create function public.audit_verification() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.actor_id is distinct from new.professional_id and public.is_admin() then
    perform public.audit('professional.' || new.to_status, 'professional_profiles', new.professional_id::text,
                         jsonb_strip_nulls(jsonb_build_object('from', new.from_status, 'note', new.note)));
  end if;
  return new;
end $$;

create trigger verification_events_audit after insert on public.verification_events
  for each row execute function public.audit_verification();

-- ---------------------------------------------------------------------------
-- Acciones del administrador
-- ---------------------------------------------------------------------------
alter table public.professional_documents add column review_note text;

create function public.admin_review_document(p_document bigint, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_pro uuid;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('pending', 'accepted', 'rejected') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status = 'rejected' and coalesce(trim(p_note), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.professional_documents set status = p_status, review_note = nullif(trim(p_note), '')
  where id = p_document returning professional_id into v_pro;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.audit('document.' || p_status, 'professional_documents', p_document::text,
                       jsonb_strip_nulls(jsonb_build_object('professional', v_pro, 'note', p_note)));
end $$;

create function public.admin_set_suspension(p_user uuid, p_suspend boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_pro public.verification_status;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_user = auth.uid() or public.has_role('admin', p_user) then raise exception 'HMY_FORBIDDEN'; end if;
  if p_suspend and coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.profiles
  set suspended_at = case when p_suspend then coalesce(suspended_at, now()) end,
      suspension_reason = case when p_suspend then trim(p_reason) end,
      active_role = case when p_suspend then 'customer'::public.app_role else active_role end
  where id = p_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;

  select status into v_pro from public.professional_profiles where user_id = p_user;
  if p_suspend and v_pro = 'approved' then
    perform public.review_professional_application(p_user, 'suspended', p_reason);
  elsif not p_suspend and v_pro = 'suspended' then
    perform public.review_professional_application(p_user, 'approved', 'Suspensión levantada');
  end if;

  perform public.notify(p_user, 'account',
    case when p_suspend then 'Tu cuenta fue suspendida' else 'Tu cuenta está activa otra vez' end,
    case when p_suspend then 'Motivo: ' || trim(p_reason) || '. Si crees que es un error, escríbenos desde Ayuda.'
         else 'Ya puedes volver a usar HandiMan ¡Ya!.' end, null);
  perform public.audit(case when p_suspend then 'account.suspend' else 'account.reactivate' end,
                       'profiles', p_user::text, jsonb_strip_nulls(jsonb_build_object('reason', p_reason)));
end $$;

create function public.admin_review_report(p_report bigint, p_status text, p_resolution text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('reviewing', 'resolved', 'dismissed') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status in ('resolved', 'dismissed') and coalesce(trim(p_resolution), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  update public.user_reports
  set status = p_status, resolution = nullif(trim(p_resolution), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_report;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  perform public.audit('report.' || p_status, 'user_reports', p_report::text,
                       jsonb_strip_nulls(jsonb_build_object('resolution', p_resolution)));
end $$;

create function public.admin_update_ticket(p_ticket bigint, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('open', 'in_progress', 'closed') then raise exception 'HMY_INVALID_STATUS'; end if;
  update public.support_tickets set status = p_status, admin_note = coalesce(nullif(trim(p_note), ''), admin_note)
  where id = p_ticket returning user_id into v_user;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if nullif(trim(p_note), '') is not null then
    perform public.notify(v_user, 'support', 'Respuesta de soporte', trim(p_note), null);
  end if;
  perform public.audit('ticket.' || p_status, 'support_tickets', p_ticket::text,
                       jsonb_strip_nulls(jsonb_build_object('note', p_note)));
end $$;

-- Reglas de comisión: el administrador las define; la app nunca inventa un porcentaje.
create function public.admin_save_commission_rule(
  p_id int, p_name text, p_category int, p_city smallint, p_rate_percent numeric, p_fixed_fee numeric,
  p_reserve_amount numeric, p_min_balance numeric, p_capture_at public.commission_milestone, p_active boolean
) returns int
language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(coalesce(trim(p_name), '')) < 3 then raise exception 'HMY_NAME_REQUIRED'; end if;
  if p_rate_percent is null and p_fixed_fee is null then raise exception 'HMY_COMMISSION_REQUIRED'; end if;
  if p_id is null then
    insert into public.commission_rules (name, category_id, city_id, rate_percent, fixed_fee, reserve_amount,
                                         min_balance, capture_at, is_active, created_by)
    values (trim(p_name), p_category, p_city, p_rate_percent, p_fixed_fee, coalesce(p_reserve_amount, 0),
            coalesce(p_min_balance, 0), coalesce(p_capture_at, 'completed'), coalesce(p_active, true), auth.uid())
    returning id into v_id;
  else
    update public.commission_rules
    set name = trim(p_name), category_id = p_category, city_id = p_city, rate_percent = p_rate_percent,
        fixed_fee = p_fixed_fee, reserve_amount = coalesce(p_reserve_amount, 0),
        min_balance = coalesce(p_min_balance, 0), capture_at = coalesce(p_capture_at, 'completed'),
        is_active = coalesce(p_active, true)
    where id = p_id returning id into v_id;
    if not found then raise exception 'HMY_NOT_FOUND'; end if;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Lecturas del panel (solo administradores)
-- ---------------------------------------------------------------------------
create function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return jsonb_build_object(
    'pending_applications', (select count(*) from public.professional_profiles where status in ('submitted', 'under_review')),
    'pending_topups', (select count(*) from public.topup_requests where status = 'pending'),
    'open_disputes', (select count(*) from public.disputes where status = 'open'),
    'open_reports', (select count(*) from public.user_reports where status in ('open', 'reviewing')),
    'open_tickets', (select count(*) from public.support_tickets where status <> 'closed'),
    'bookings_today', (select count(*) from public.bookings where created_at >= date_trunc('day', now())),
    'active_bookings', (select count(*) from public.bookings
                        where status not in ('draft', 'completed', 'cancelled')),
    'approved_professionals', (select count(*) from public.professional_profiles where status = 'approved'),
    'available_professionals', (select count(*) from public.professional_profiles where status = 'approved' and is_available),
    'users', (select count(*) from public.profiles),
    'active_commission_rules', (select count(*) from public.commission_rules where is_active)
  );
end $$;

create function public.admin_applications(p_status text default 'pending')
returns table (user_id uuid, display_name text, full_name text, phone text, email text, city_name text,
               category_name text, status public.verification_status, submitted_at timestamptz, documents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select pp.user_id, pp.display_name, p.full_name, p.phone, u.email::text, c.name, sc.name, pp.status, pp.submitted_at,
         (select count(*)::int from public.professional_documents d where d.professional_id = pp.user_id)
  from public.professional_profiles pp
  join public.profiles p on p.id = pp.user_id
  left join auth.users u on u.id = pp.user_id
  left join public.cities c on c.id = pp.city_id
  left join public.service_categories sc on sc.id = pp.primary_category_id
  where case p_status
          when 'pending' then pp.status in ('submitted', 'under_review')
          when 'all' then true
          else pp.status::text = p_status
        end
  order by pp.submitted_at asc nulls last
  limit 200;
end $$;

create function public.admin_application_detail(p_professional uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select jsonb_build_object(
    'user_id', pp.user_id, 'display_name', pp.display_name, 'full_name', p.full_name, 'phone', p.phone,
    'email', u.email, 'city_name', c.name, 'category_name', sc.name, 'bio', pp.bio,
    'years_experience', pp.years_experience, 'status', pp.status, 'submitted_at', pp.submitted_at,
    'review_note', pp.review_note, 'suspended_at', p.suspended_at,
    'zones', coalesce((select jsonb_agg(z.name order by z.name) from public.professional_zones pz
                       join public.service_zones z on z.id = pz.zone_id where pz.professional_id = pp.user_id), '[]'),
    'categories', coalesce((select jsonb_agg(s2.name order by s2.name) from public.professional_services ps
                            join public.service_categories s2 on s2.id = ps.category_id
                            where ps.professional_id = pp.user_id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type,
                             'storage_path', d.storage_path, 'status', d.status, 'review_note', d.review_note,
                             'uploaded_at', d.uploaded_at) order by d.uploaded_at)
                           from public.professional_documents d where d.professional_id = pp.user_id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('to_status', e.to_status, 'note', e.note,
                           'created_at', e.created_at) order by e.created_at desc)
                         from public.verification_events e where e.professional_id = pp.user_id), '[]')
  ) into v
  from public.professional_profiles pp
  join public.profiles p on p.id = pp.user_id
  left join auth.users u on u.id = pp.user_id
  left join public.cities c on c.id = pp.city_id
  left join public.service_categories sc on sc.id = pp.primary_category_id
  where pp.user_id = p_professional;
  if v is null then raise exception 'HMY_NOT_FOUND'; end if;
  return v;
end $$;

create function public.admin_topups(p_status text default 'pending')
returns table (id bigint, professional_id uuid, display_name text, amount numeric, method_name text,
               reference text, proof_path text, status public.topup_status, review_note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select t.id, t.professional_id, pp.display_name, t.amount, m.name, t.reference, t.proof_path, t.status,
         t.review_note, t.created_at
  from public.topup_requests t
  join public.professional_profiles pp on pp.user_id = t.professional_id
  left join public.topup_methods m on m.id = t.method_id
  where p_status = 'all' or t.status::text = p_status
  order by t.created_at asc
  limit 200;
end $$;

create function public.admin_reports(p_status text default 'open')
returns table (id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text,
               booking_id uuid, reason text, details text, status text, resolution text, created_at timestamptz,
               reports_against int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select r.id, r.reporter_id, a.full_name, r.reported_id, b.full_name, r.booking_id, r.reason, r.details,
         r.status, r.resolution, r.created_at,
         (select count(*)::int from public.user_reports x where x.reported_id = r.reported_id)
  from public.user_reports r
  join public.profiles a on a.id = r.reporter_id
  join public.profiles b on b.id = r.reported_id
  where case p_status when 'open' then r.status in ('open', 'reviewing') when 'all' then true
                      else r.status = p_status end
  order by r.created_at asc
  limit 200;
end $$;

create function public.admin_disputes(p_status text default 'open')
returns table (booking_id uuid, reason text, status text, resolution text, created_at timestamptz,
               opened_by_name text, customer_name text, professional_name text, category_name text,
               booking_status public.booking_status)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select d.booking_id, d.reason, d.status, d.resolution, d.created_at, o.full_name, c.full_name,
         pp.display_name, sc.name, bk.status
  from public.disputes d
  join public.bookings bk on bk.id = d.booking_id
  join public.profiles o on o.id = d.opened_by
  join public.profiles c on c.id = bk.customer_id
  left join public.professional_profiles pp on pp.user_id = bk.professional_id
  left join public.service_categories sc on sc.id = bk.category_id
  where p_status = 'all' or d.status = p_status
  order by d.created_at asc
  limit 200;
end $$;

create function public.admin_tickets(p_status text default 'open')
returns table (id bigint, user_id uuid, user_name text, booking_id uuid, subject text, body text, status text,
               admin_note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select t.id, t.user_id, p.full_name, t.booking_id, t.subject, t.body, t.status, t.admin_note, t.created_at
  from public.support_tickets t join public.profiles p on p.id = t.user_id
  where case p_status when 'open' then t.status <> 'closed' when 'all' then true else t.status = p_status end
  order by t.created_at asc
  limit 200;
end $$;

create function public.admin_users(p_query text default null)
returns table (id uuid, full_name text, email text, phone text, city_name text, roles text[],
               professional_status public.verification_status, suspended_at timestamptz,
               suspension_reason text, reports_against int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare q text := '%' || public.hmy_norm(coalesce(trim(p_query), '')) || '%';
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select p.id, p.full_name, u.email::text, p.phone, c.name,
         coalesce((select array_agg(r.role::text order by r.role) from public.user_roles r where r.user_id = p.id), '{}'),
         pp.status, p.suspended_at, p.suspension_reason,
         (select count(*)::int from public.user_reports x where x.reported_id = p.id), p.created_at
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join public.cities c on c.id = p.city_id
  left join public.professional_profiles pp on pp.user_id = p.id
  where public.hmy_norm(p.full_name) like q or public.hmy_norm(coalesce(u.email::text, '')) like q
     or coalesce(p.phone, '') like q
  order by p.suspended_at desc nulls last, p.created_at desc
  limit 50;
end $$;

create function public.admin_audit_entries(p_limit int default 100)
returns table (id bigint, actor_name text, action text, target_table text, target_id text, details jsonb,
               created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return query
  select l.id, coalesce(p.full_name, 'Sistema'), l.action, l.target_table, l.target_id, l.details, l.created_at
  from public.admin_audit_log l left join public.profiles p on p.id = l.actor_id
  order by l.created_at desc, l.id desc
  limit least(greatest(p_limit, 1), 500);
end $$;

-- Estado de la cuenta propia: administrador, suspensión y a quién bloqueó.
create function public.my_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('is_admin', public.is_admin(), 'suspended_at', p.suspended_at,
                            'suspension_reason', p.suspension_reason,
                            'blocked', coalesce((select jsonb_agg(blocked_id) from public.user_blocks
                                                 where blocker_id = auth.uid()), '[]'))
  from public.profiles p where p.id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- RLS y permisos
-- ---------------------------------------------------------------------------
alter table public.user_blocks enable row level security;
alter table public.user_reports enable row level security;
alter table public.consent_records enable row level security;

create policy blocks_own on public.user_blocks for select using (blocker_id = auth.uid() or public.is_admin());
create policy reports_own on public.user_reports for select using (reporter_id = auth.uid() or public.is_admin());
create policy consents_own on public.consent_records for select using (user_id = auth.uid() or public.is_admin());

revoke insert, update, delete on public.user_blocks from anon, authenticated;
revoke insert, update, delete on public.user_reports from anon, authenticated;
revoke insert, update, delete on public.consent_records from anon, authenticated;
revoke insert, update, delete on public.admin_audit_log from anon, authenticated;

revoke execute on function public.audit_admin_change() from public, anon, authenticated;
revoke execute on function public.audit_verification() from public, anon, authenticated;
revoke execute on function public.guard_new_booking() from public, anon, authenticated;
revoke execute on function public.guard_new_message() from public, anon, authenticated;
revoke execute on function public.guard_new_ticket() from public, anon, authenticated;
revoke execute on function public.guard_pro_available() from public, anon, authenticated;
revoke execute on function public.hmy_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.block_user(uuid)', 'public.unblock_user(uuid)', 'public.report_user(uuid, text, text, uuid)',
    'public.record_consent(text, text)', 'public.my_status()', 'public.is_suspended(uuid)',
    'public.admin_review_document(bigint, text, text)', 'public.admin_set_suspension(uuid, boolean, text)',
    'public.admin_review_report(bigint, text, text)', 'public.admin_update_ticket(bigint, text, text)',
    'public.admin_save_commission_rule(int, text, int, smallint, numeric, numeric, numeric, numeric, public.commission_milestone, boolean)',
    'public.admin_dashboard()', 'public.admin_applications(text)', 'public.admin_application_detail(uuid)',
    'public.admin_topups(text)', 'public.admin_reports(text)', 'public.admin_disputes(text)',
    'public.admin_tickets(text)', 'public.admin_users(text)', 'public.admin_audit_entries(int)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
