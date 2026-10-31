-- HandiMan ¡Ya! — 0048 mapa del inicio: dónde hay profesionales disponibles,
-- sin revelar dónde viven.
--
-- home_map_professionals(ciudad) devuelve los profesionales aprobados,
-- disponibles ahora y con la cuenta activa que atienden esa ciudad, cada uno
-- con un punto APROXIMADO:
-- - Con ubicación de trabajo: el centro de su cuadro de 0,02° (unos 2 km) más
--   un corrimiento fijo que sale solo de su id (no de su ubicación). Así dos
--   profesionales del mismo cuadro no quedan encimados y el punto no cambia
--   cada vez que se abre el mapa.
-- - Sin ubicación: la zona de trabajo que eligió, o el centro de la ciudad, con
--   el mismo corrimiento.
-- Nunca sale la coordenada guardada ni una dirección. Quien pide no se ve a sí
-- mismo ni a quien bloqueó (o lo bloqueó). Hasta 60 puntos.

create function public.hmy_map_jitter(p_id uuid, p_axis int) returns numeric
language sql immutable as $$
  -- Entre -0,007 y +0,007 grados, fijo por persona y eje.
  select round(((('x' || substr(md5(p_id::text || ':' || p_axis), 1, 8))::bit(32)::bigint % 1401) - 700) / 100000.0, 6)
$$;

create function public.home_map_professionals(p_city smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_city public.cities;
  v_pros jsonb;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into v_city from public.cities where id = p_city;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(x order by x.rating_avg desc, x.id), '[]'::jsonb) into v_pros
  from (
    select pp.user_id as id,
           pp.display_name,
           pp.photo_path,
           sc.name as category,
           pp.rating_avg,
           pp.rating_count,
           round(coalesce(floor(pl.base_latitude / 0.02) * 0.02 + 0.01, z.latitude, v_city.latitude)
                 + public.hmy_map_jitter(pp.user_id, 1), 4) as latitude,
           round(coalesce(floor(pl.base_longitude / 0.02) * 0.02 + 0.01, z.longitude, v_city.longitude)
                 + public.hmy_map_jitter(pp.user_id, 2), 4) as longitude
    from public.professional_profiles pp
    join public.profiles pr on pr.id = pp.user_id
    left join public.service_categories sc on sc.id = pp.primary_category_id
    left join public.professional_locations pl on pl.professional_id = pp.user_id
    left join lateral (
      select sz.latitude, sz.longitude from public.professional_zones pz
      join public.service_zones sz on sz.id = pz.zone_id
      where pz.professional_id = pp.user_id and sz.latitude is not null
      order by sz.sort_order, sz.id limit 1
    ) z on true
    where pp.status = 'approved'
      and pp.is_available
      and pr.suspended_at is null
      and pp.user_id <> v_me
      and not public.hmy_blocked_between(pp.user_id, v_me)
      and (pp.city_id = p_city
           or (pl.base_latitude is not null and v_city.latitude is not null
               and public.hmy_distance_km(v_city.latitude, v_city.longitude, pl.base_latitude, pl.base_longitude)
                   <= pl.service_radius_km))
    order by pp.rating_avg desc, pp.user_id
    limit 60
  ) x
  where x.latitude is not null and x.longitude is not null;

  return jsonb_build_object(
    'city', jsonb_build_object('id', v_city.id, 'name', v_city.name,
                               'latitude', v_city.latitude, 'longitude', v_city.longitude),
    'professionals', v_pros);
end $$;

revoke execute on function public.hmy_map_jitter(uuid, int) from public, anon, authenticated;
revoke execute on function public.home_map_professionals(smallint) from public, anon;
grant execute on function public.home_map_professionals(smallint) to authenticated;
