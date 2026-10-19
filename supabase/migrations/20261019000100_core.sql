-- HandiMan ¡Ya! — 0001 núcleo: geografía, categorías, perfiles, roles,
-- profesionales y verificación.
--
-- Diseñado para un proyecto Supabase NUEVO y vacío. Se detiene si encuentra
-- las tablas del proyecto DEV anterior (FlutterFlow) para no tocar sus datos.

do $$ begin
  if to_regclass('public.profiles') is not null
     or to_regclass('public.provider_profiles') is not null
     or to_regclass('public.service_requests') is not null then
    raise exception 'HMY: este proyecto ya tiene tablas anteriores. Estas migraciones son para un proyecto Supabase nuevo; no se aplicó nada.';
  end if;
end $$;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('customer', 'professional', 'admin');

create type public.verification_status as enum (
  'not_started', 'draft', 'submitted', 'under_review', 'approved',
  'rejected', 'suspended', 'reverification_required'
);

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------
create function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Texto normalizado para búsquedas sin tildes ni mayúsculas.
create function public.hmy_norm(t text) returns text
language sql immutable parallel safe as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, '')))
$$;

-- ---------------------------------------------------------------------------
-- Geografía: país → departamento → ciudad → zona.
-- Se puede ampliar a toda Bolivia sin cambiar el diseño.
-- ---------------------------------------------------------------------------
create table public.departments (
  id smallint primary key,
  code text not null unique,
  name text not null
);

create table public.cities (
  id smallserial primary key,
  department_id smallint not null references public.departments(id),
  slug text not null unique,
  name text not null,
  timezone text not null default 'America/La_Paz',
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_active boolean not null default false,
  sort_order int not null default 100
);

create table public.service_zones (
  id serial primary key,
  city_id smallint not null references public.cities(id),
  slug text not null,
  name text not null,
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_active boolean not null default true,
  sort_order int not null default 100,
  unique (city_id, slug)
);

insert into public.departments (id, code, name) values
  (1, 'CH', 'Chuquisaca'), (2, 'LP', 'La Paz'), (3, 'CB', 'Cochabamba'),
  (4, 'OR', 'Oruro'), (5, 'PT', 'Potosí'), (6, 'TJ', 'Tarija'),
  (7, 'SC', 'Santa Cruz'), (8, 'BE', 'Beni'), (9, 'PD', 'Pando');

insert into public.cities (department_id, slug, name, latitude, longitude, is_active, sort_order) values
  (7, 'santa-cruz', 'Santa Cruz de la Sierra', -17.783300, -63.182100, true, 1),
  (3, 'cochabamba', 'Cochabamba', -17.389500, -66.156800, true, 2),
  (2, 'la-paz', 'La Paz', -16.500000, -68.150000, true, 3);

-- Zonas iniciales generales; el administrador las ajusta o agrega más.
insert into public.service_zones (city_id, slug, name, sort_order)
select c.id, z.slug, z.name, z.ord
from public.cities c
cross join (values ('centro', 'Centro', 1), ('norte', 'Zona Norte', 2),
                   ('sur', 'Zona Sur', 3), ('este', 'Zona Este', 4),
                   ('oeste', 'Zona Oeste', 5)) as z(slug, name, ord);

-- ---------------------------------------------------------------------------
-- Categorías de servicio (configurables)
-- ---------------------------------------------------------------------------
create table public.service_categories (
  id serial primary key,
  slug text not null unique,
  name text not null,
  icon text not null default 'build',
  description text,
  parent_id int references public.service_categories(id),
  is_active boolean not null default true,
  sort_order int not null default 100
);

insert into public.service_categories (slug, name, icon, description, sort_order) values
  ('plomeria', 'Plomería', 'plumbing', 'Fugas, cañerías, grifos y baños', 1),
  ('electricidad', 'Electricidad', 'electrical_services', 'Instalaciones, tomacorrientes y tableros', 2),
  ('limpieza', 'Limpieza', 'cleaning_services', 'Limpieza de casas y oficinas', 3),
  ('pintura', 'Pintura', 'format_paint', 'Interiores, exteriores y retoques', 4),
  ('albanileria', 'Albañilería', 'construction', 'Albañil para muros, pisos y revoques', 5),
  ('carpinteria', 'Carpintería', 'carpenter', 'Muebles, puertas y reparaciones en madera', 6),
  ('jardineria', 'Jardinería', 'yard', 'Poda, césped y mantenimiento de jardines', 7),
  ('reparaciones-hogar', 'Reparaciones del hogar', 'home_repair_service', 'Arreglos generales en tu casa', 8);

-- ---------------------------------------------------------------------------
-- Perfiles y roles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 120),
  phone text check (phone is null or phone ~ '^\+591[67][0-9]{7}$'),
  phone_verified_at timestamptz,
  city_id smallint references public.cities(id),
  avatar_path text,
  active_role public.app_role not null default 'customer',
  onboarding_completed_at timestamptz,
  terms_accepted_at timestamptz,
  deletion_requested_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

create table public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.profiles(id),
  primary key (user_id, role)
);

create function public.has_role(p_role public.app_role, p_user uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = p_user and role = p_role)
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_role('admin')
$$;

-- Cada cuenta nueva empieza como cliente.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_city smallint;
  v_phone text;
begin
  begin
    v_city := nullif(new.raw_user_meta_data ->> 'city_id', '')::smallint;
  exception when others then
    v_city := null;
  end;
  if v_city is not null and not exists (select 1 from public.cities where id = v_city) then
    v_city := null;
  end if;
  v_phone := nullif(new.raw_user_meta_data ->> 'phone', '');
  if v_phone is not null and v_phone !~ '^\+591[67][0-9]{7}$' then
    v_phone := null;
  end if;

  insert into public.profiles (id, full_name, phone, city_id, terms_accepted_at)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120),
    v_phone,
    v_city,
    case when (new.raw_user_meta_data ->> 'terms_accepted') = 'true' then now() end
  );
  insert into public.user_roles (user_id, role) values (new.id, 'customer');
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- El rol activo solo cambia por esta función, y solo a un rol que la base de
-- datos ya concedió.
create function public.set_active_role(p_role public.app_role) returns public.app_role
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'HMY_AUTH_REQUIRED';
  end if;
  if not public.has_role(p_role) then
    raise exception 'HMY_ROLE_NOT_GRANTED';
  end if;
  if p_role = 'professional' and not exists (
    select 1 from public.professional_profiles
    where user_id = auth.uid() and status = 'approved'
  ) then
    raise exception 'HMY_PROFESSIONAL_NOT_APPROVED';
  end if;
  update public.profiles set active_role = p_role where id = auth.uid();
  return p_role;
end $$;

create function public.complete_onboarding() returns void
language sql security definer set search_path = public as $$
  update public.profiles set onboarding_completed_at = coalesce(onboarding_completed_at, now())
  where id = auth.uid()
$$;

create function public.request_account_deletion() returns void
language sql security definer set search_path = public as $$
  update public.profiles set deletion_requested_at = now() where id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Profesionales
-- ---------------------------------------------------------------------------
create table public.professional_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 120),
  primary_category_id int references public.service_categories(id),
  bio text check (bio is null or char_length(bio) <= 2000),
  years_experience smallint check (years_experience between 0 and 70),
  city_id smallint references public.cities(id),
  price_note text check (price_note is null or char_length(price_note) <= 300),
  photo_path text,
  status public.verification_status not null default 'draft',
  is_available boolean not null default false,
  available_since timestamptz,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text,
  rating_avg numeric(3,2) not null default 0,
  rating_count int not null default 0,
  completed_jobs int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger professional_profiles_touch before update on public.professional_profiles
  for each row execute function public.touch_updated_at();

create table public.professional_services (
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  category_id int not null references public.service_categories(id),
  specialty text check (specialty is null or char_length(specialty) <= 120),
  price_from numeric(10,2) check (price_from is null or price_from >= 0),
  primary key (professional_id, category_id)
);

create table public.professional_zones (
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  zone_id int not null references public.service_zones(id),
  primary key (professional_id, zone_id)
);

create table public.professional_availability (
  id bigserial primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_time time not null,
  end_time time not null check (end_time > start_time)
);

create table public.professional_portfolio (
  id bigserial primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  storage_path text not null,
  caption text,
  created_at timestamptz not null default now()
);

create table public.professional_documents (
  id bigserial primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  doc_type text not null check (doc_type in ('ci_anverso', 'ci_reverso', 'certificado', 'antecedentes', 'otro')),
  storage_path text not null,
  expires_on date,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  uploaded_at timestamptz not null default now()
);

create table public.verification_events (
  id bigserial primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  from_status public.verification_status,
  to_status public.verification_status not null,
  actor_id uuid references public.profiles(id),
  note text,
  created_at timestamptz not null default now()
);

-- Postular como profesional: crea el borrador.
create function public.start_professional_application() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_name text;
  v_city smallint;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select full_name, city_id into v_name, v_city from public.profiles where id = auth.uid();
  insert into public.professional_profiles (user_id, display_name, city_id)
  values (auth.uid(), coalesce(v_name, ''), v_city)
  on conflict (user_id) do nothing;
end $$;

create function public.submit_professional_application() returns public.verification_status
language plpgsql security definer set search_path = public as $$
declare
  p public.professional_profiles;
begin
  select * into p from public.professional_profiles where user_id = auth.uid() for update;
  if not found then raise exception 'HMY_NO_APPLICATION'; end if;
  if p.status not in ('draft', 'rejected', 'reverification_required') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  if char_length(trim(p.display_name)) < 3 or p.city_id is null or p.primary_category_id is null then
    raise exception 'HMY_APPLICATION_INCOMPLETE';
  end if;
  if not exists (select 1 from public.professional_documents where professional_id = p.user_id) then
    raise exception 'HMY_DOCUMENTS_REQUIRED';
  end if;
  update public.professional_profiles set status = 'submitted', submitted_at = now()
  where user_id = p.user_id;
  insert into public.verification_events (professional_id, from_status, to_status, actor_id)
  values (p.user_id, p.status, 'submitted', auth.uid());
  return 'submitted';
end $$;

-- Solo administradores. Aprobar concede el rol profesional.
create function public.review_professional_application(
  p_professional uuid, p_decision public.verification_status, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_from public.verification_status;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_decision not in ('under_review', 'approved', 'rejected', 'suspended', 'reverification_required') then
    raise exception 'HMY_INVALID_STATUS';
  end if;
  if p_decision in ('rejected', 'reverification_required') and coalesce(trim(p_note), '') = '' then
    raise exception 'HMY_REASON_REQUIRED';
  end if;
  select status into v_from from public.professional_profiles where user_id = p_professional for update;
  if not found then raise exception 'HMY_NO_APPLICATION'; end if;

  update public.professional_profiles
  set status = p_decision, reviewed_at = now(), reviewed_by = auth.uid(), review_note = p_note,
      is_available = case when p_decision = 'approved' then is_available else false end
  where user_id = p_professional;

  insert into public.verification_events (professional_id, from_status, to_status, actor_id, note)
  values (p_professional, v_from, p_decision, auth.uid(), p_note);

  if p_decision = 'approved' then
    insert into public.user_roles (user_id, role, granted_by)
    values (p_professional, 'professional', auth.uid())
    on conflict do nothing;
  elsif p_decision in ('rejected', 'suspended') then
    update public.profiles set active_role = 'customer'
    where id = p_professional and active_role = 'professional';
  end if;
end $$;

create function public.set_availability(p_available boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.professional_profiles
  set is_available = p_available,
      available_since = case when p_available then now() else null end
  where user_id = auth.uid() and status = 'approved';
  if not found then raise exception 'HMY_PROFESSIONAL_NOT_APPROVED'; end if;
  return p_available;
end $$;

-- ---------------------------------------------------------------------------
-- Búsqueda pública: solo profesionales aprobados y solo datos no sensibles
-- (zona general, nunca dirección ni coordenadas exactas).
-- ---------------------------------------------------------------------------
create function public.search_professionals(
  p_city_id smallint default null,
  p_category_id int default null,
  p_zone_id int default null,
  p_query text default null,
  p_available_now boolean default false,
  p_min_rating numeric default null,
  p_sort text default 'recommended',
  p_limit int default 20,
  p_offset int default 0
) returns table (
  id uuid,
  display_name text,
  photo_path text,
  primary_category_id int,
  primary_category text,
  specialties text[],
  city_id smallint,
  city text,
  zones text[],
  rating_avg numeric,
  rating_count int,
  completed_jobs int,
  is_available boolean,
  price_from numeric,
  is_verified boolean
)
language sql stable security definer set search_path = public as $$
  with base as (
    select pp.*,
           pc.name as cat_name,
           c.name as city_name,
           array(select coalesce(ps.specialty, sc.name) from public.professional_services ps
                 join public.service_categories sc on sc.id = ps.category_id
                 where ps.professional_id = pp.user_id order by sc.sort_order) as specs,
           array(select z.name from public.professional_zones pz
                 join public.service_zones z on z.id = pz.zone_id
                 where pz.professional_id = pp.user_id order by z.sort_order) as zone_names,
           (select min(ps.price_from) from public.professional_services ps
            where ps.professional_id = pp.user_id
              and (p_category_id is null or ps.category_id = p_category_id)) as min_price
    from public.professional_profiles pp
    left join public.service_categories pc on pc.id = pp.primary_category_id
    left join public.cities c on c.id = pp.city_id
    where pp.status = 'approved'
      and (p_city_id is null or pp.city_id = p_city_id)
      and (p_category_id is null or pp.primary_category_id = p_category_id
           or exists (select 1 from public.professional_services ps
                      where ps.professional_id = pp.user_id and ps.category_id = p_category_id))
      and (p_zone_id is null or exists (select 1 from public.professional_zones pz
                                        where pz.professional_id = pp.user_id and pz.zone_id = p_zone_id))
      and (not coalesce(p_available_now, false) or pp.is_available)
      and (p_min_rating is null or pp.rating_avg >= p_min_rating)
  )
  select b.user_id, b.display_name, b.photo_path, b.primary_category_id, b.cat_name, b.specs,
         b.city_id, b.city_name, b.zone_names, b.rating_avg, b.rating_count, b.completed_jobs,
         b.is_available, b.min_price, true
  from base b
  where p_query is null or trim(p_query) = ''
     or public.hmy_norm(b.display_name || ' ' || coalesce(b.cat_name, '') || ' '
                        || array_to_string(b.specs, ' ') || ' ' || array_to_string(b.zone_names, ' ')
                        || ' ' || coalesce(b.city_name, ''))
        like '%' || public.hmy_norm(trim(p_query)) || '%'
  order by
    case when p_sort = 'available' then (not b.is_available)::int end,
    case when p_sort = 'rating' then b.rating_avg end desc,
    case when p_sort = 'recommended' then (not b.is_available)::int end,
    case when p_sort = 'recommended' then b.rating_avg * ln(b.rating_count + 2) end desc,
    b.display_name
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;

create function public.get_professional_public(p_id uuid)
returns table (
  id uuid, display_name text, photo_path text, bio text, years_experience smallint,
  primary_category text, city text, zones text[], price_note text,
  rating_avg numeric, rating_count int, completed_jobs int, is_available boolean,
  is_verified boolean,
  services jsonb, portfolio jsonb, weekly_availability jsonb
)
language sql stable security definer set search_path = public as $$
  select pp.user_id, pp.display_name, pp.photo_path, pp.bio, pp.years_experience,
         sc.name, c.name,
         array(select z.name from public.professional_zones pz join public.service_zones z on z.id = pz.zone_id
               where pz.professional_id = pp.user_id order by z.sort_order),
         pp.price_note, pp.rating_avg, pp.rating_count, pp.completed_jobs, pp.is_available,
         pp.status = 'approved',
         coalesce((select jsonb_agg(jsonb_build_object('category_id', s.category_id, 'category', c2.name,
                                                       'specialty', s.specialty, 'price_from', s.price_from)
                                    order by c2.sort_order)
                   from public.professional_services s join public.service_categories c2 on c2.id = s.category_id
                   where s.professional_id = pp.user_id), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('path', po.storage_path, 'caption', po.caption)
                                    order by po.created_at desc)
                   from public.professional_portfolio po where po.professional_id = pp.user_id), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('weekday', a.weekday, 'start', a.start_time, 'end', a.end_time)
                                    order by a.weekday, a.start_time)
                   from public.professional_availability a where a.professional_id = pp.user_id), '[]'::jsonb)
  from public.professional_profiles pp
  left join public.service_categories sc on sc.id = pp.primary_category_id
  left join public.cities c on c.id = pp.city_id
  where pp.user_id = p_id and pp.status = 'approved'
$$;

-- ---------------------------------------------------------------------------
-- Seguridad (RLS)
-- ---------------------------------------------------------------------------
alter table public.departments enable row level security;
alter table public.cities enable row level security;
alter table public.service_zones enable row level security;
alter table public.service_categories enable row level security;
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.professional_profiles enable row level security;
alter table public.professional_services enable row level security;
alter table public.professional_zones enable row level security;
alter table public.professional_availability enable row level security;
alter table public.professional_portfolio enable row level security;
alter table public.professional_documents enable row level security;
alter table public.verification_events enable row level security;

-- Catálogos: lectura pública, escritura solo admin.
create policy departments_read on public.departments for select using (true);
create policy cities_read on public.cities for select using (is_active or public.is_admin());
create policy cities_admin on public.cities for all using (public.is_admin()) with check (public.is_admin());
create policy zones_read on public.service_zones for select using (is_active or public.is_admin());
create policy zones_admin on public.service_zones for all using (public.is_admin()) with check (public.is_admin());
create policy categories_read on public.service_categories for select using (is_active or public.is_admin());
create policy categories_admin on public.service_categories for all using (public.is_admin()) with check (public.is_admin());

-- Perfiles: cada uno ve y edita el suyo. El admin puede leer.
create policy profiles_self_read on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy profiles_self_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke insert, delete, update on public.profiles from anon, authenticated;
grant update (full_name, phone, city_id, avatar_path, terms_accepted_at) on public.profiles to authenticated;

create policy roles_self_read on public.user_roles for select using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.user_roles from anon, authenticated;

-- Perfil profesional: el dueño lo ve y edita sus datos descriptivos; el
-- estado de verificación, calificaciones y disponibilidad solo cambian por
-- funciones del servidor.
create policy pro_self_read on public.professional_profiles for select
  using (user_id = auth.uid() or public.is_admin());
create policy pro_self_update on public.professional_profiles for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke insert, delete, update on public.professional_profiles from anon, authenticated;
grant update (display_name, primary_category_id, bio, years_experience, city_id, price_note, photo_path)
  on public.professional_profiles to authenticated;

create function public.is_approved_professional(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.professional_profiles where user_id = p_id and status = 'approved')
$$;

create policy pro_services_read on public.professional_services for select
  using (public.is_approved_professional(professional_id) or professional_id = auth.uid() or public.is_admin());
create policy pro_services_own on public.professional_services for all
  using (professional_id = auth.uid()) with check (professional_id = auth.uid());
create policy pro_zones_read on public.professional_zones for select
  using (public.is_approved_professional(professional_id) or professional_id = auth.uid() or public.is_admin());
create policy pro_zones_own on public.professional_zones for all
  using (professional_id = auth.uid()) with check (professional_id = auth.uid());
create policy pro_avail_read on public.professional_availability for select
  using (public.is_approved_professional(professional_id) or professional_id = auth.uid() or public.is_admin());
create policy pro_avail_own on public.professional_availability for all
  using (professional_id = auth.uid()) with check (professional_id = auth.uid());
create policy pro_portfolio_read on public.professional_portfolio for select
  using (public.is_approved_professional(professional_id) or professional_id = auth.uid() or public.is_admin());
create policy pro_portfolio_own on public.professional_portfolio for all
  using (professional_id = auth.uid()) with check (professional_id = auth.uid());

-- Documentos de identidad: privados (dueño y admin).
create policy pro_docs_own_read on public.professional_documents for select
  using (professional_id = auth.uid() or public.is_admin());
create policy pro_docs_own_insert on public.professional_documents for insert
  with check (professional_id = auth.uid() and status = 'pending');
create policy pro_docs_admin_update on public.professional_documents for update
  using (public.is_admin()) with check (public.is_admin());
revoke delete on public.professional_documents from anon, authenticated;

create policy verif_events_read on public.verification_events for select
  using (professional_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.verification_events from anon, authenticated;

-- Las funciones de servidor no se exponen a usuarios anónimos salvo la búsqueda.
revoke execute on function public.set_active_role(public.app_role) from public, anon;
revoke execute on function public.complete_onboarding() from public, anon;
revoke execute on function public.request_account_deletion() from public, anon;
revoke execute on function public.start_professional_application() from public, anon;
revoke execute on function public.submit_professional_application() from public, anon;
revoke execute on function public.review_professional_application(uuid, public.verification_status, text) from public, anon;
revoke execute on function public.set_availability(boolean) from public, anon;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
