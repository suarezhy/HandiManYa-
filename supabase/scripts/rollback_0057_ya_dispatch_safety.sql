-- Deshace 0057: vuelven create_ya_request, claim_ya_request y la lista de
-- profesionales de ¡Ya! como estaban en 0055/0020. No toca pedidos ni ofertas.
begin;
drop function public.claim_ya_request(uuid);
alter function public._claim_ya_request_scheduled(uuid) rename to claim_ya_request;
revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;

drop function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric,
  int[], text, text);
alter function public._create_ya_request_extras(int, smallint, text, text, text, int, public.payment_method, numeric,
  numeric, int[], text, text) rename to create_ya_request;
revoke execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text) from public, anon;
grant execute on function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method,
  numeric, numeric, int[], text, text) to authenticated;

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
    and not public.hmy_blocked_between(pp.user_id, p_customer)
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and public.hmy_pro_cleared(pp.user_id, p_category)
    and case
      when p_latitude is not null and pl.base_latitude is not null then
        public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) <= pl.service_radius_km
      else
        pp.city_id = p_city
        and (p_zone is null
             or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
             or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone))
    end
  order by public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) asc nulls last,
           pp.rating_avg desc, pp.available_since asc nulls last
$$;
revoke execute on function public.ya_eligible_professionals(int, smallint, int, uuid, numeric, numeric)
  from public, anon, authenticated;

drop function public.hmy_pro_busy_now(uuid);
commit;
