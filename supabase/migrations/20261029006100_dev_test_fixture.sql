-- Profesional de prueba (solo para el proyecto de desarrollo).
--
-- `test_fixture` marca un perfil profesional preparado para pruebas, sin
-- verificación de identidad real. Solo el dueño de la base (postgres, desde un
-- flujo de dev) puede ponerlo o quitarlo: la app, con su sesión, no puede.
-- Un perfil marcado nunca se muestra como "Verificado" a los clientes.
--
-- No cambia ninguna regla de aprobación: aprobar sigue exigiendo el carnet
-- aceptado (hmy_id_documents_guard) y, donde esté activa, la verificación de
-- identidad. Sin la marca (todos los perfiles, y siempre en producción) todo
-- se ve igual que antes.
alter table public.professional_profiles add column test_fixture boolean not null default false;

create function public.hmy_test_fixture_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if (tg_op = 'INSERT' and new.test_fixture)
     or (tg_op = 'UPDATE' and new.test_fixture is distinct from old.test_fixture) then
    if current_user not in ('postgres', 'supabase_admin') then
      raise exception 'HMY_FORBIDDEN';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.hmy_test_fixture_guard() from public, anon, authenticated;

create trigger professional_profiles_test_fixture_guard before insert or update of test_fixture
  on public.professional_profiles for each row execute function public.hmy_test_fixture_guard();

create function public.hmy_is_test_fixture(p_pro uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select test_fixture from public.professional_profiles where user_id = p_pro), false)
$$;
revoke execute on function public.hmy_is_test_fixture(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- "Verificado"
-- Cada función que lo muestra pasa por una capa que lo apaga para los
-- perfiles de prueba. El resto de la respuesta no cambia.

alter function public.search_professionals(smallint, int, int, text, boolean, numeric, text, int, int)
  rename to _search_professionals_base;
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
  id uuid, display_name text, photo_path text, primary_category_id int, primary_category text,
  specialties text[], city_id smallint, city text, zones text[], rating_avg numeric, rating_count int,
  completed_jobs int, is_available boolean, price_from numeric, is_verified boolean
)
language sql stable security definer set search_path = public as $$
  select s.id, s.display_name, s.photo_path, s.primary_category_id, s.primary_category, s.specialties,
         s.city_id, s.city, s.zones, s.rating_avg, s.rating_count, s.completed_jobs, s.is_available,
         s.price_from, s.is_verified and not public.hmy_is_test_fixture(s.id)
  from public._search_professionals_base(p_city_id, p_category_id, p_zone_id, p_query, p_available_now,
                                         p_min_rating, p_sort, p_limit, p_offset) s
$$;

alter function public.get_professional_public(uuid) rename to _get_professional_public_base;
create function public.get_professional_public(p_id uuid)
returns table (
  id uuid, display_name text, photo_path text, bio text, years_experience smallint,
  primary_category text, city text, zones text[], price_note text,
  rating_avg numeric, rating_count int, completed_jobs int, is_available boolean,
  is_verified boolean,
  services jsonb, portfolio jsonb, weekly_availability jsonb
)
language sql stable security definer set search_path = public as $$
  select g.id, g.display_name, g.photo_path, g.bio, g.years_experience, g.primary_category, g.city, g.zones,
         g.price_note, g.rating_avg, g.rating_count, g.completed_jobs, g.is_available,
         g.is_verified and not public.hmy_is_test_fixture(g.id), g.services, g.portfolio, g.weekly_availability
  from public._get_professional_public_base(p_id) g
$$;

alter function public.booking_detail(uuid) rename to _booking_detail_destination;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_destination(p_booking); -- valida quién puede verlo
begin
  if jsonb_typeof(v -> 'professional') = 'object'
     and public.hmy_is_test_fixture((v #>> '{professional,id}')::uuid) then
    v := jsonb_set(v, '{professional,is_verified}', 'false'::jsonb);
  end if;
  return v;
end $$;

alter function public.trip_share_view(text) rename to _trip_share_view_base;
create function public.trip_share_view(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v jsonb := public._trip_share_view_base(p_token); -- valida el enlace
  v_pro uuid;
begin
  select b.professional_id into v_pro
  from public.trip_shares s join public.bookings b on b.id = s.booking_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if public.hmy_is_test_fixture(v_pro) then
    v := jsonb_set(v, '{professional_verified}', 'false'::jsonb);
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public._search_professionals_base(smallint, int, int, text, boolean, numeric, text, int, int)
  from public, anon, authenticated;
revoke execute on function public._get_professional_public_base(uuid) from public, anon, authenticated;
revoke execute on function public._booking_detail_destination(uuid) from public, anon, authenticated;
revoke execute on function public._trip_share_view_base(text) from public, anon, authenticated;

-- search_professionals y get_professional_public quedan abiertas como antes
-- (permiso por defecto); las demás, con los mismos permisos que tenían.
revoke execute on function public.booking_detail(uuid) from public, anon;
grant execute on function public.booking_detail(uuid) to authenticated;
revoke execute on function public.trip_share_view(text) from public;
grant execute on function public.trip_share_view(text) to anon, authenticated;
