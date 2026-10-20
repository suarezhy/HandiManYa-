-- HandiMan ¡Ya! — 0010 "¿Qué necesitas solucionar?": problemas por categoría,
-- reglas para servicios sensibles y el problema elegido en cada solicitud.
--
-- - service_problems: opciones de cada categoría. El administrador las crea,
--   edita, desactiva y ordena desde el panel (sin cambiar la app).
-- - bookings.problem_ids / problem_labels: lo que eligió el cliente. Las
--   etiquetas se copian al crear la solicitud, así un cambio posterior en el
--   catálogo no altera solicitudes anteriores.
-- - Categorías sensibles (niñera, cerrajería, mecánica, asesoría legal): piden un
--   documento aceptado por el equipo antes de recibir pedidos de esa categoría,
--   y niñera y asesoría legal no se piden con ¡Ya! (el cliente elige a la persona).

do $$ begin
  if to_regprocedure('public.admin_dashboard()') is null then
    raise exception 'HMY: falta la migración 0009; no se aplicó nada.';
  end if;
  if to_regclass('public.service_problems') is not null then
    raise exception 'HMY: la migración 0010 ya está aplicada; no se aplicó nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Categorías: reglas de seguridad
-- ---------------------------------------------------------------------------
alter table public.service_categories
  add column allows_ya boolean not null default true,
  add column required_doc text check (required_doc in ('antecedentes', 'certificado')),
  add column safety_note text check (safety_note is null or char_length(safety_note) <= 600),
  add column pro_note text check (pro_note is null or char_length(pro_note) <= 600);

update public.service_categories set required_doc = 'antecedentes',
  safety_note = 'Por seguridad, el cerrajero te pedirá tu carnet y algo que pruebe que la casa o el vehículo es tuyo (una factura de luz, un contrato o el RUAT). Si no puedes mostrarlo, no podrá abrir.',
  pro_note = 'Para ofrecer cerrajería necesitas subir tu certificado de antecedentes (FELCC) y que el equipo lo acepte. Nunca abras una casa o un vehículo sin comprobar que es de quien te pide el servicio.'
where slug = 'cerrajeria';

update public.service_categories set required_doc = 'antecedentes', allows_ya = false,
  safety_note = 'Tú eliges a la niñera: revisa su perfil y calificaciones y conócela antes. Una persona adulta de la familia debe estar siempre localizable. Revisamos los antecedentes de cada niñera, pero la decisión de a quién dejar con tus hijos es tuya.',
  pro_note = 'Para cuidar niños necesitas subir tu certificado de antecedentes (FELCC) y que el equipo lo acepte. Solo cuida niños en servicios acordados por la app con su familia.'
where slug = 'ninera';

update public.service_categories set required_doc = 'antecedentes',
  safety_note = 'Si tu auto se quedó en la calle o la carretera, espera en un lugar seguro con las luces de emergencia encendidas y comparte tu solicitud con alguien de confianza. El mecánico no debe llevarse tu vehículo sin que lo acuerden por el chat.',
  pro_note = 'Para ofrecer mecánica a domicilio necesitas subir tu certificado de antecedentes (FELCC) y que el equipo lo acepte.'
where slug = 'mecanica';

update public.service_categories set required_doc = 'certificado', allows_ya = false,
  safety_note = 'Elige a quien te asesore y pídele su número de matrícula de abogado. La app solo los pone en contacto: los honorarios y el trabajo los acuerdas directamente con el profesional.',
  pro_note = 'Para dar asesoría legal necesitas subir tu matrícula o credencial de abogado (Registro Público de la Abogacía) y que el equipo la acepte.'
where slug = 'asesoria-legal';

-- ---------------------------------------------------------------------------
-- Problemas por categoría
-- ---------------------------------------------------------------------------
create table public.service_problems (
  id serial primary key,
  category_id int not null references public.service_categories(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 2 and 80),
  icon text not null default 'build',
  is_other boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 100,
  unique (category_id, name)
);
create index service_problems_category_idx on public.service_problems (category_id, sort_order);

insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select c.id, v.name, v.icon, v.is_other, v.sort_order
from (values
  ('plomeria', 'Fuga de agua', 'water_damage', false, 10),
  ('plomeria', 'Destapar cañería', 'plumbing', false, 20),
  ('plomeria', 'Reparar inodoro', 'wc', false, 30),
  ('plomeria', 'Reparar o instalar grifo', 'wash', false, 40),
  ('plomeria', 'Problema con la ducha', 'shower', false, 50),
  ('plomeria', 'Sin agua', 'format_color_reset', false, 60),
  ('plomeria', 'Instalar tuberías', 'hardware', false, 70),
  ('plomeria', 'Otro problema', 'other', true, 80),
  ('electricidad', 'No tengo luz', 'power_off', false, 10),
  ('electricidad', 'Cortocircuito', 'bolt', false, 20),
  ('electricidad', 'Instalar tomacorrientes', 'power', false, 30),
  ('electricidad', 'Reparar interruptores', 'toggle_on', false, 40),
  ('electricidad', 'Instalar lámparas', 'light', false, 50),
  ('electricidad', 'Problema con el tablero eléctrico', 'electric_meter', false, 60),
  ('electricidad', 'Revisar instalación eléctrica', 'fact_check', false, 70),
  ('electricidad', 'Otro problema', 'other', true, 80),
  ('limpieza', 'Limpieza de casa', 'house', false, 10),
  ('limpieza', 'Limpieza profunda', 'auto_awesome', false, 20),
  ('limpieza', 'Limpieza de departamento', 'apartment', false, 30),
  ('limpieza', 'Limpieza después de construcción', 'construction', false, 40),
  ('limpieza', 'Limpieza de cocina', 'kitchen', false, 50),
  ('limpieza', 'Limpieza de baños', 'bathtub', false, 60),
  ('limpieza', 'Limpieza de oficinas', 'business', false, 70),
  ('limpieza', 'Otro servicio', 'other', true, 80),
  ('pintura', 'Pintar paredes interiores', 'format_paint', false, 10),
  ('pintura', 'Pintar exteriores', 'home_work', false, 20),
  ('pintura', 'Pintar techo', 'roofing', false, 30),
  ('pintura', 'Reparar y pintar paredes', 'format_color_fill', false, 40),
  ('pintura', 'Pintar puertas', 'door_front_door', false, 50),
  ('pintura', 'Pintar rejas', 'fence', false, 60),
  ('pintura', 'Pintar habitación', 'bed', false, 70),
  ('pintura', 'Otro servicio', 'other', true, 80),
  ('albanileria', 'Reparar paredes', 'texture', false, 10),
  ('albanileria', 'Construir muro', 'foundation', false, 20),
  ('albanileria', 'Colocar cerámica', 'grid_on', false, 30),
  ('albanileria', 'Reparar pisos', 'layers', false, 40),
  ('albanileria', 'Reparar techo', 'roofing', false, 50),
  ('albanileria', 'Trabajos de cemento', 'construction', false, 60),
  ('albanileria', 'Remodelación', 'architecture', false, 70),
  ('albanileria', 'Otro trabajo', 'other', true, 80),
  ('carpinteria', 'Reparar muebles', 'chair', false, 10),
  ('carpinteria', 'Fabricar muebles', 'table_restaurant', false, 20),
  ('carpinteria', 'Instalar puertas', 'door_front_door', false, 30),
  ('carpinteria', 'Reparar puertas', 'door_sliding', false, 40),
  ('carpinteria', 'Instalar cerraduras', 'lock', false, 50),
  ('carpinteria', 'Reparar armarios', 'shelves', false, 60),
  ('carpinteria', 'Trabajos en madera', 'carpenter', false, 70),
  ('carpinteria', 'Otro servicio', 'other', true, 80),
  ('jardineria', 'Cortar césped', 'grass', false, 10),
  ('jardineria', 'Podar árboles', 'park', false, 20),
  ('jardineria', 'Podar plantas', 'content_cut', false, 30),
  ('jardineria', 'Limpiar jardín', 'yard', false, 40),
  ('jardineria', 'Instalar plantas', 'local_florist', false, 50),
  ('jardineria', 'Mantenimiento de jardín', 'eco', false, 60),
  ('jardineria', 'Retirar maleza', 'delete_sweep', false, 70),
  ('jardineria', 'Otro servicio', 'other', true, 80),
  ('reparaciones-hogar', 'Reparar puertas', 'door_front_door', false, 10),
  ('reparaciones-hogar', 'Reparar ventanas', 'window', false, 20),
  ('reparaciones-hogar', 'Colgar televisores', 'tv', false, 30),
  ('reparaciones-hogar', 'Instalar repisas', 'shelves', false, 40),
  ('reparaciones-hogar', 'Armar muebles', 'weekend', false, 50),
  ('reparaciones-hogar', 'Reparaciones generales', 'handyman', false, 60),
  ('reparaciones-hogar', 'Instalaciones pequeñas', 'build', false, 70),
  ('reparaciones-hogar', 'Otro problema', 'other', true, 80),
  ('mecanica', 'El auto no arranca', 'car_repair', false, 10),
  ('mecanica', 'Batería descargada', 'battery_alert', false, 20),
  ('mecanica', 'Cambio de aceite', 'oil_barrel', false, 30),
  ('mecanica', 'Problema con los frenos', 'warning_amber', false, 40),
  ('mecanica', 'Problema con el motor', 'settings', false, 50),
  ('mecanica', 'Cambio de llanta', 'tire_repair', false, 60),
  ('mecanica', 'Diagnóstico mecánico', 'search', false, 70),
  ('mecanica', 'Otro problema', 'other', true, 80),
  ('aire-acondicionado', 'No enfría', 'thermostat', false, 10),
  ('aire-acondicionado', 'No enciende', 'power_settings_new', false, 20),
  ('aire-acondicionado', 'Instalación de aire acondicionado', 'ac_unit', false, 30),
  ('aire-acondicionado', 'Limpieza y mantenimiento', 'cleaning_services', false, 40),
  ('aire-acondicionado', 'Recarga de refrigerante', 'gas_meter', false, 50),
  ('aire-acondicionado', 'Fuga de agua', 'water_drop', false, 60),
  ('aire-acondicionado', 'Reparación general', 'build', false, 70),
  ('aire-acondicionado', 'Otro problema', 'other', true, 80),
  ('cerrajeria', 'Me quedé fuera de casa', 'no_meeting_room', false, 10),
  ('cerrajeria', 'Perdí mis llaves', 'key_off', false, 20),
  ('cerrajeria', 'Cambiar cerradura', 'lock_reset', false, 30),
  ('cerrajeria', 'Reparar chapa', 'lock_open', false, 40),
  ('cerrajeria', 'Duplicar llaves', 'key', false, 50),
  ('cerrajeria', 'Abrir vehículo', 'directions_car', false, 60),
  ('cerrajeria', 'Instalar cerradura nueva', 'lock', false, 70),
  ('cerrajeria', 'Otro problema', 'other', true, 80),
  ('belleza', 'Corte de cabello', 'content_cut', false, 10),
  ('belleza', 'Peinado', 'face_retouching_natural', false, 20),
  ('belleza', 'Tinte de cabello', 'palette', false, 30),
  ('belleza', 'Maquillaje', 'brush', false, 40),
  ('belleza', 'Tratamiento capilar', 'spa', false, 50),
  ('belleza', 'Peinado para evento', 'celebration', false, 60),
  ('belleza', 'Barbería', 'face', false, 70),
  ('belleza', 'Otro servicio', 'other', true, 80),
  ('manicure', 'Manicure', 'back_hand', false, 10),
  ('manicure', 'Pedicure', 'directions_walk', false, 20),
  ('manicure', 'Uñas acrílicas', 'auto_awesome', false, 30),
  ('manicure', 'Uñas en gel', 'light_mode', false, 40),
  ('manicure', 'Esmaltado semipermanente', 'format_paint', false, 50),
  ('manicure', 'Retiro de uñas', 'remove_circle_outline', false, 60),
  ('manicure', 'Decoración de uñas', 'palette', false, 70),
  ('manicure', 'Otro servicio', 'other', true, 80),
  ('ninera', 'Cuidado por horas', 'schedule', false, 10),
  ('ninera', 'Cuidado durante el día', 'wb_sunny', false, 20),
  ('ninera', 'Cuidado por la noche', 'bedtime', false, 30),
  ('ninera', 'Cuidado ocasional', 'event_available', false, 40),
  ('ninera', 'Acompañamiento después del colegio', 'school', false, 50),
  ('ninera', 'Cuidado durante eventos', 'celebration', false, 60),
  ('ninera', 'Otro servicio', 'other', true, 70),
  ('mascotas', 'Pasear perros', 'pets', false, 10),
  ('mascotas', 'Baño de mascotas', 'bathtub', false, 20),
  ('mascotas', 'Peluquería canina', 'content_cut', false, 30),
  ('mascotas', 'Cuidado por horas', 'schedule', false, 40),
  ('mascotas', 'Cuidado durante el día', 'wb_sunny', false, 50),
  ('mascotas', 'Cuidado durante viajes', 'luggage', false, 60),
  ('mascotas', 'Visitas a domicilio', 'home', false, 70),
  ('mascotas', 'Otro servicio', 'other', true, 80),
  ('clases', 'Matemáticas', 'calculate', false, 10),
  ('clases', 'Lenguaje y lectura', 'menu_book', false, 20),
  ('clases', 'Inglés', 'translate', false, 30),
  ('clases', 'Apoyo escolar', 'school', false, 40),
  ('clases', 'Preparación para exámenes', 'quiz', false, 50),
  ('clases', 'Música', 'music_note', false, 60),
  ('clases', 'Computación', 'computer', false, 70),
  ('clases', 'Otra materia', 'other', true, 80),
  ('eventos', 'Meseros', 'room_service', false, 10),
  ('eventos', 'Decoración', 'celebration', false, 20),
  ('eventos', 'Ayudantes para eventos', 'groups', false, 30),
  ('eventos', 'Organización de fiestas', 'event', false, 40),
  ('eventos', 'Limpieza después del evento', 'cleaning_services', false, 50),
  ('eventos', 'Montaje de mesas y sillas', 'table_restaurant', false, 60),
  ('eventos', 'Atención de invitados', 'emoji_people', false, 70),
  ('eventos', 'Otro servicio', 'other', true, 80),
  ('asesoria-legal', 'Consulta legal', 'forum', false, 10),
  ('asesoria-legal', 'Contratos', 'description', false, 20),
  ('asesoria-legal', 'Trámites', 'assignment', false, 30),
  ('asesoria-legal', 'Derecho familiar', 'family_restroom', false, 40),
  ('asesoria-legal', 'Asuntos laborales', 'work', false, 50),
  ('asesoria-legal', 'Asuntos comerciales', 'storefront', false, 60),
  ('asesoria-legal', 'Documentos legales', 'gavel', false, 70),
  ('asesoria-legal', 'Otra consulta', 'other', true, 80)
) as v(slug, name, icon, is_other, sort_order)
join public.service_categories c on c.slug = v.slug;

-- Toda categoría nueva nace con su opción "Otro servicio", para que nunca
-- quede sin la pantalla de problemas.
create function public.add_default_problem() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.service_problems (category_id, name, icon, is_other, sort_order)
  values (new.id, 'Otro servicio', 'other', true, 1000);
  return new;
end $$;
create trigger service_categories_default_problem after insert on public.service_categories
  for each row execute function public.add_default_problem();

alter table public.service_problems enable row level security;
create policy problems_read on public.service_problems for select using (is_active or public.is_admin());
create policy problems_admin on public.service_problems for all using (public.is_admin()) with check (public.is_admin());
create trigger service_problems_audit after insert or update or delete on public.service_problems
  for each row execute function public.audit_admin_change();

-- ---------------------------------------------------------------------------
-- Lo que eligió el cliente
-- ---------------------------------------------------------------------------
alter table public.bookings
  add column problem_ids int[],
  add column problem_labels text[] check (problem_labels is null or cardinality(problem_labels) between 1 and 10);

-- Valida la selección y devuelve las etiquetas que se guardan.
create function public.hmy_problem_labels(p_category int, p_problem_ids int[], p_other_text text)
returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  v_ids int[] := array(select distinct unnest(coalesce(p_problem_ids, '{}')));
  v_labels text[];
  v_other boolean;
begin
  if cardinality(v_ids) = 0 then
    if coalesce(trim(p_other_text), '') <> '' then raise exception 'HMY_INVALID_PROBLEM'; end if;
    return null;
  end if;
  if cardinality(v_ids) > 8 then raise exception 'HMY_TOO_MANY_PROBLEMS'; end if;
  if (select count(*) from public.service_problems
      where id = any (v_ids) and category_id = p_category and is_active) <> cardinality(v_ids) then
    raise exception 'HMY_INVALID_PROBLEM';
  end if;
  v_other := exists (select 1 from public.service_problems where id = any (v_ids) and is_other);
  if v_other and char_length(coalesce(trim(p_other_text), '')) < 3 then
    raise exception 'HMY_OTHER_REQUIRED';
  end if;
  if not v_other and coalesce(trim(p_other_text), '') <> '' then raise exception 'HMY_INVALID_PROBLEM'; end if;
  select array_agg(case when is_other then name || ': ' || left(trim(p_other_text), 200) else name end
                   order by is_other, sort_order, id)
    into v_labels
  from public.service_problems where id = any (v_ids);
  return v_labels;
end $$;

-- ¿Puede este profesional atender esta categoría? Las sensibles piden un
-- documento aceptado y vigente.
create function public.hmy_pro_cleared(p_pro uuid, p_category int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.required_doc is null or exists (
      select 1 from public.professional_documents d
      where d.professional_id = p_pro and d.doc_type = c.required_doc and d.status = 'accepted'
        and (d.expires_on is null or d.expires_on >= current_date))
    from public.service_categories c where c.id = p_category), false)
$$;

-- ¡Ya! solo ofrece el pedido a profesionales habilitados para la categoría.
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
    and public.hmy_pro_cleared(pp.user_id, p_category)
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
$$;

-- La búsqueda por categoría tampoco muestra a quien no está habilitado.
create or replace function public.search_professionals(
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
      and (p_category_id is null or public.hmy_pro_cleared(pp.user_id, p_category_id))
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

-- ---------------------------------------------------------------------------
-- Crear solicitudes con los problemas elegidos
-- ---------------------------------------------------------------------------
-- Las funciones anteriores quedan como internas y las nuevas las envuelven:
-- validan la selección, crean la solicitud con la lógica ya probada y guardan
-- los problemas.
alter function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int,
                                     public.payment_method, numeric, numeric)
  rename to _create_booking_base;
alter function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric)
  rename to _create_ya_request_base;

create function public.create_booking(
  p_professional uuid,
  p_category int,
  p_mode public.booking_mode,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_scheduled_start timestamptz default null,
  p_duration_minutes int default 120,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_problem_ids int[] default null,
  p_other_text text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_labels text[] := public.hmy_problem_labels(p_category, p_problem_ids, p_other_text);
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not public.hmy_pro_cleared(p_professional, p_category) then raise exception 'HMY_PRO_NOT_CLEARED'; end if;
  v_id := public._create_booking_base(
    p_professional, p_category, p_mode,
    coalesce(nullif(trim(p_description), ''), array_to_string(v_labels, '. ')),
    p_address, p_address_reference, p_zone_id, p_scheduled_start, p_duration_minutes,
    p_payment_method, p_latitude, p_longitude);
  if v_labels is not null then
    update public.bookings set problem_ids = p_problem_ids, problem_labels = v_labels where id = v_id;
  end if;
  return v_id;
end $$;

create function public.create_ya_request(
  p_category int,
  p_city smallint,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_problem_ids int[] default null,
  p_other_text text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_labels text[] := public.hmy_problem_labels(p_category, p_problem_ids, p_other_text);
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  if not coalesce((select allows_ya from public.service_categories where id = p_category and is_active), false) then
    raise exception 'HMY_YA_NOT_ALLOWED';
  end if;
  v_id := public._create_ya_request_base(
    p_category, p_city,
    coalesce(nullif(trim(p_description), ''), array_to_string(v_labels, '. ')),
    p_address, p_address_reference, p_zone_id, p_payment_method, p_latitude, p_longitude);
  if v_labels is not null then
    update public.bookings set problem_ids = p_problem_ids, problem_labels = v_labels where id = v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Mostrar los problemas (al profesional antes de aceptar, y al cliente)
-- ---------------------------------------------------------------------------
alter function public.booking_detail(uuid) rename to _booking_detail_base;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_base(p_booking); -- valida quién puede verlo
begin
  return v || jsonb_build_object(
    'problems', (select to_jsonb(coalesce(problem_labels, '{}')) from public.bookings where id = p_booking),
    'safety_note', (select c.safety_note from public.bookings b
                    join public.service_categories c on c.id = b.category_id where b.id = p_booking));
end $$;

drop function public.my_bookings(text);
create function public.my_bookings(p_as text default 'customer')
returns table (
  id uuid, code text, status public.booking_status, mode public.booking_mode,
  category_id int, category text, city text, zone text,
  description text, scheduled_start timestamptz, created_at timestamptz,
  other_user_id uuid, other_name text, other_photo_path text,
  quote_amount numeric, final_amount numeric, has_review boolean, is_offer boolean, distance_km numeric,
  problems text[]
)
language sql stable security definer set search_path = public as $$
  select b.id, b.code, b.status, b.mode, b.category_id, sc.name, c.name, z.name,
         b.description, b.scheduled_start, b.created_at,
         case when p_as = 'customer' then b.professional_id else b.customer_id end,
         case when p_as = 'customer' then pp.display_name
              else coalesce(nullif(split_part(cp.full_name, ' ', 1), ''), 'Cliente') end,
         case when p_as = 'customer' then pp.photo_path end,
         b.quote_amount, b.final_amount,
         exists (select 1 from public.reviews r where r.booking_id = b.id),
         b.professional_id is null,
         case when p_as = 'professional' then public.booking_distance_for_me(b.id) end,
         coalesce(b.problem_labels, '{}')
  from public.bookings b
  join public.service_categories sc on sc.id = b.category_id
  join public.cities c on c.id = b.city_id
  left join public.service_zones z on z.id = b.zone_id
  left join public.professional_profiles pp on pp.user_id = b.professional_id
  left join public.profiles cp on cp.id = b.customer_id
  where (p_as = 'customer' and b.customer_id = auth.uid())
     or (p_as = 'professional' and (b.professional_id = auth.uid() or public.has_pending_offer(b.id)))
  order by b.created_at desc
  limit 100
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public._create_booking_base(uuid, int, public.booking_mode, text, text, text, int, timestamptz,
  int, public.payment_method, numeric, numeric) from public, anon, authenticated;
revoke execute on function public._create_ya_request_base(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric) from public, anon, authenticated;
revoke execute on function public._booking_detail_base(uuid) from public, anon, authenticated;
revoke execute on function public.add_default_problem() from public, anon, authenticated;
revoke execute on function public.hmy_problem_labels(int, int[], text) from public, anon, authenticated;
revoke execute on function public.hmy_pro_cleared(uuid, int) from public, anon, authenticated;
revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int, public.payment_method, numeric, numeric, int[], text)',
    'public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric, int[], text)',
    'public.booking_detail(uuid)', 'public.my_bookings(text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
