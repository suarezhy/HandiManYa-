-- HandiMan ¡Ya! — 0049 catálogo: Grúa (dentro de Mecánica) y Banda (Eventos).
--
-- Grúa es su propia categoría, así solo la reciben profesionales aprobados
-- para grúa (la misma regla de siempre: hmy_pro_cleared por categoría). En
-- Mecánica aparece como una opción más, "Grúa", que lleva a esa categoría
-- (service_problems.opens_category_id); esa opción no se puede pedir como
-- mecánica.
--
-- Para habilitarse en Grúa se piden dos documentos aceptados y vigentes: los
-- de la grúa (licencia de conducir, RUAT y SOAT) y el certificado de
-- antecedentes, como en Mecánica: la persona se lleva el vehículo del cliente.
--
-- El destino del remolque es privado como la dirección: va en
-- booking_addresses y solo lo ve quien puede ver la dirección.

-- ---------------------------------------------------------------- Documentos
alter table public.professional_documents drop constraint professional_documents_doc_type_check;
alter table public.professional_documents add constraint professional_documents_doc_type_check
  check (doc_type in ('ci_anverso', 'ci_reverso', 'certificado', 'antecedentes', 'nombramiento_notarial',
                      'documentos_grua', 'otro'));

alter table public.service_categories drop constraint service_categories_required_doc_check;
alter table public.service_categories add constraint service_categories_required_doc_check
  check (required_doc in ('antecedentes', 'certificado', 'nombramiento_notarial', 'documentos_grua'));

-- Grúa pide además antecedentes.
create or replace function public.hmy_pro_cleared(p_pro uuid, p_category int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.required_doc is null or not exists (
      select 1 from unnest(case when c.required_doc = 'documentos_grua'
                                then array['documentos_grua', 'antecedentes']
                                else array[c.required_doc] end) as need(doc)
      where not exists (
        select 1 from public.professional_documents d
        where d.professional_id = p_pro and d.doc_type = need.doc and d.status = 'accepted'
          and (d.expires_on is null or d.expires_on >= current_date)))
    from public.service_categories c where c.id = p_category), false)
$$;
revoke execute on function public.hmy_pro_cleared(uuid, int) from public, anon, authenticated;

-- ---------------------------------------------------------------- Grúa
alter table public.service_problems
  add column opens_category_id int references public.service_categories(id);

insert into public.service_categories (slug, name, icon, description, sort_order, required_doc, allows_ya, safety_note, pro_note)
values ('grua', 'Grúa', 'local_shipping', 'Remolque, auxilio en carretera y traslado al taller', 9,
  'documentos_grua', true,
  'Antes de que se lleven tu vehículo, mira la placa de la grúa y confirma por el chat el destino y el precio. Espera en un lugar seguro con las luces de emergencia encendidas.',
  'Para ofrecer grúa necesitas subir tu licencia de conducir con el RUAT y el SOAT vigentes de la grúa, y tu certificado de antecedentes (FELCC). El equipo los revisa antes de enviarte pedidos.')
on conflict (slug) do nothing;

insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select c.id, p.name, p.icon, p.is_other, p.sort_order
from public.service_categories c
cross join (values
  ('Remolque de vehículo', 'local_shipping', false, 10),
  ('Auxilio en carretera', 'car_repair', false, 20),
  ('Traslado al taller', 'build', false, 30)
) as p(name, icon, is_other, sort_order)
where c.slug = 'grua'
on conflict (category_id, name) do nothing;

-- La opción "Otro" que trae toda categoría nueva va al final.
update public.service_problems set name = 'Otro servicio', sort_order = 80
where is_other and name = 'Otro servicio' and sort_order = 1000
  and category_id = (select id from public.service_categories where slug = 'grua');

-- En Mecánica, "Grúa" lleva a la categoría Grúa.
insert into public.service_problems (category_id, name, icon, is_other, sort_order, opens_category_id)
select m.id, 'Grúa', 'local_shipping', false, 75, g.id
from public.service_categories m, public.service_categories g
where m.slug = 'mecanica' and g.slug = 'grua'
on conflict (category_id, name) do nothing;

update public.service_categories set description = 'Mecánico a domicilio, auxilio y grúa'
where slug = 'mecanica' and description = 'Mecánico a domicilio y auxilio';

-- ---------------------------------------------------------------- Banda
insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select id, 'Banda', 'music_note', false, 67 from public.service_categories where slug = 'eventos'
on conflict (category_id, name) do nothing;

update public.service_categories set description = 'Meseros, churrasqueros, bandas, decoración y ayuda para fiestas'
where slug = 'eventos' and description = 'Meseros, churrasqueros, decoración y ayuda para fiestas';

-- ---------------------------------------------------------------- Destino
alter table public.booking_addresses
  add column destination text check (destination is null or char_length(destination) between 3 and 300);

-- Pedido con destino: Grúa lo exige; las demás categorías no lo aceptan. Una
-- opción que solo lleva a otra categoría no se puede pedir.
create function public.hmy_check_booking_extras(p_category int, p_problem_ids int[], p_destination text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_dest text := nullif(trim(coalesce(p_destination, '')), '');
  v_tow boolean := exists (select 1 from public.service_categories where id = p_category and slug = 'grua');
begin
  if exists (select 1 from public.service_problems where id = any (coalesce(p_problem_ids, '{}'))
             and opens_category_id is not null) then
    raise exception 'HMY_INVALID_PROBLEM';
  end if;
  if v_tow and (v_dest is null or char_length(v_dest) < 3) then raise exception 'HMY_DESTINATION_REQUIRED'; end if;
  if not v_tow and v_dest is not null then raise exception 'HMY_INVALID_PROBLEM'; end if;
  return left(v_dest, 300);
end $$;

alter function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int,
  public.payment_method, numeric, numeric, int[], text) rename to _create_booking_problems;
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
  p_other_text text default null,
  p_destination text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_dest text := public.hmy_check_booking_extras(p_category, p_problem_ids, p_destination);
  v_id uuid;
begin
  v_id := public._create_booking_problems(p_professional, p_category, p_mode, p_description, p_address,
    p_address_reference, p_zone_id, p_scheduled_start, p_duration_minutes, p_payment_method, p_latitude, p_longitude,
    p_problem_ids, p_other_text);
  if v_dest is not null then update public.booking_addresses set destination = v_dest where booking_id = v_id; end if;
  return v_id;
end $$;

alter function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric,
  int[], text) rename to _create_ya_request_problems;
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
  p_other_text text default null,
  p_destination text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_dest text := public.hmy_check_booking_extras(p_category, p_problem_ids, p_destination);
  v_id uuid;
begin
  v_id := public._create_ya_request_problems(p_category, p_city, p_description, p_address, p_address_reference,
    p_zone_id, p_payment_method, p_latitude, p_longitude, p_problem_ids, p_other_text);
  if v_dest is not null then update public.booking_addresses set destination = v_dest where booking_id = v_id; end if;
  return v_id;
end $$;

-- El destino sale junto a la dirección, con la misma regla.
alter function public.booking_detail(uuid) rename to _booking_detail_problems;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_problems(p_booking); -- valida quién puede verlo
begin
  if jsonb_typeof(v -> 'address') = 'object' then
    v := jsonb_set(v, '{address,destination}',
                   coalesce((select to_jsonb(destination) from public.booking_addresses where booking_id = p_booking),
                            'null'::jsonb));
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public._create_booking_problems(uuid, int, public.booking_mode, text, text, text, int,
  timestamptz, int, public.payment_method, numeric, numeric, int[], text) from public, anon, authenticated;
revoke execute on function public._create_ya_request_problems(int, smallint, text, text, text, int,
  public.payment_method, numeric, numeric, int[], text) from public, anon, authenticated;
revoke execute on function public._booking_detail_problems(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_check_booking_extras(int, int[], text) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int, public.payment_method, numeric, numeric, int[], text, text)',
    'public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric, int[], text, text)',
    'public.booking_detail(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
