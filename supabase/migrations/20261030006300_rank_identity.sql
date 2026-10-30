-- "Identidad verificada" y categorías Plata, Oro y Diamante.
--
-- Identidad verificada: solo con una verificación de identidad real aprobada
-- (identity_checks aprobado y no de prueba), en un perfil aprobado que no es de
-- prueba. Revisar el carnet a mano o aprobar al profesional no alcanza. Las
-- respuestas siguen usando `is_verified`, ahora con ese significado.
--
-- Categoría: la calcula la base con trabajos confirmados por clientes y
-- reseñas reales. Sube y baja sola; nadie la escribe ni la compra. No dice nada
-- de la identidad. Cada cambio queda en `professional_rank_events`.
--   Plata:    10 trabajos, 8 reseñas, 4,3 estrellas, 85 % cumplidos
--   Oro:      50 trabajos, 30 reseñas, 4,6 estrellas, 90 % cumplidos
--   Diamante: 150 trabajos, 100 reseñas, 4,8 estrellas, 95 % cumplidos
-- Siempre: aprobado, sin suspensión, no de prueba, sin reclamos abiertos ni
-- reportes graves (acoso, fraude, cobro indebido) sin resolver.
-- Contra el abuso: de cada cliente cuentan como mucho 3 trabajos y 3 reseñas.

create function public.hmy_identity_verified(p_pro uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.professional_profiles pp
    where pp.user_id = p_pro and pp.status = 'approved' and not pp.test_fixture
      and exists (select 1 from public.identity_checks c
                  where c.professional_id = pp.user_id and c.status = 'approved' and not c.sandbox))
$$;

-- ---------------------------------------------------------------- Categoría
create table public.professional_ranks (
  professional_id uuid primary key references public.professional_profiles(user_id) on delete cascade,
  tier text not null default 'none' check (tier in ('none', 'plata', 'oro', 'diamante')),
  metrics jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create table public.professional_rank_events (
  id bigint generated always as identity primary key,
  professional_id uuid not null references public.professional_profiles(user_id) on delete cascade,
  old_tier text not null,
  new_tier text not null,
  metrics jsonb not null,
  created_at timestamptz not null default now()
);
create index professional_rank_events_pro on public.professional_rank_events (professional_id, created_at desc);
alter table public.professional_ranks enable row level security;
alter table public.professional_rank_events enable row level security;
revoke all on public.professional_ranks, public.professional_rank_events from public, anon, authenticated;

create function public.hmy_rank_metrics(p_pro uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with done as (
    select b.id, b.customer_id,
           row_number() over (partition by b.customer_id order by b.completed_at desc nulls last) as n
    from public.bookings b
    where b.professional_id = p_pro and b.status = 'completed' and b.customer_id <> p_pro
  ), rated as (
    select r.rating,
           row_number() over (partition by r.customer_id order by r.created_at desc) as n
    from public.reviews r join public.bookings b on b.id = r.booking_id
    where r.professional_id = p_pro and not r.is_hidden and b.status = 'completed' and r.customer_id = b.customer_id
  ), dropped as (
    select count(*) as n from public.bookings b
    where b.professional_id = p_pro and b.status = 'cancelled' and b.cancelled_by = p_pro
  )
  select jsonb_build_object(
    'jobs', (select count(*) from done where n <= 3),
    'reviews', (select count(*) from rated where n <= 3),
    'rating', (select round(avg(rating)::numeric, 2) from rated where n <= 3),
    'completion', (select case when (select count(*) from done) + d.n = 0 then null
                               else round((select count(*) from done)::numeric / ((select count(*) from done) + d.n), 3) end
                   from dropped d),
    'good_standing', exists (
      select 1 from public.professional_profiles pp
      where pp.user_id = p_pro and pp.status = 'approved' and not pp.test_fixture and not public.is_suspended(p_pro))
      and not exists (
        select 1 from public.disputes x join public.bookings b on b.id = x.booking_id
        where b.professional_id = p_pro and x.status = 'open')
      and not exists (
        select 1 from public.user_reports u
        where u.reported_id = p_pro and u.status in ('open', 'reviewing')
          and u.reason in ('acoso', 'fraude', 'cobro_indebido'))
  )
$$;

create function public.hmy_rank_tier(m jsonb) returns text
language sql immutable as $$
  select case
    when not coalesce((m ->> 'good_standing')::boolean, false) or m ->> 'rating' is null then 'none'
    when (m ->> 'jobs')::int >= 150 and (m ->> 'reviews')::int >= 100 and (m ->> 'rating')::numeric >= 4.8
         and coalesce((m ->> 'completion')::numeric, 0) >= 0.95 then 'diamante'
    when (m ->> 'jobs')::int >= 50 and (m ->> 'reviews')::int >= 30 and (m ->> 'rating')::numeric >= 4.6
         and coalesce((m ->> 'completion')::numeric, 0) >= 0.90 then 'oro'
    when (m ->> 'jobs')::int >= 10 and (m ->> 'reviews')::int >= 8 and (m ->> 'rating')::numeric >= 4.3
         and coalesce((m ->> 'completion')::numeric, 0) >= 0.85 then 'plata'
    else 'none'
  end
$$;

create function public.hmy_recompute_rank(p_pro uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  m jsonb;
  v_new text;
  v_old text;
begin
  if p_pro is null or not exists (select 1 from public.professional_profiles where user_id = p_pro) then
    return null;
  end if;
  m := public.hmy_rank_metrics(p_pro);
  v_new := public.hmy_rank_tier(m);
  select tier into v_old from public.professional_ranks where professional_id = p_pro for update;
  if not found then
    insert into public.professional_ranks (professional_id, tier, metrics) values (p_pro, v_new, m);
    v_old := 'none';
  else
    update public.professional_ranks set tier = v_new, metrics = m, updated_at = now() where professional_id = p_pro;
  end if;
  if v_old <> v_new then
    insert into public.professional_rank_events (professional_id, old_tier, new_tier, metrics)
    values (p_pro, v_old, v_new, m);
  end if;
  return v_new;
end $$;

create function public.hmy_rank_tier_of(p_pro uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select tier from public.professional_ranks where professional_id = p_pro), 'none')
$$;

-- Lo que mueve la categoría.
create function public.hmy_rank_on_booking() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('completed', 'cancelled', 'disputed') or old.status in ('completed', 'disputed') then
    perform public.hmy_recompute_rank(new.professional_id);
  end if;
  return null;
end $$;
create trigger bookings_rank after update of status on public.bookings
  for each row when (old.status is distinct from new.status) execute function public.hmy_rank_on_booking();

create function public.hmy_rank_on_review() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_recompute_rank(case when tg_op = 'DELETE' then old.professional_id else new.professional_id end);
  return null;
end $$;
create trigger reviews_rank after insert or update or delete on public.reviews
  for each row execute function public.hmy_rank_on_review();

create function public.hmy_rank_on_dispute() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_recompute_rank((select professional_id from public.bookings where id = new.booking_id));
  return null;
end $$;
create trigger disputes_rank after insert or update of status on public.disputes
  for each row execute function public.hmy_rank_on_dispute();

create function public.hmy_rank_on_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_recompute_rank(new.reported_id);
  return null;
end $$;
create trigger user_reports_rank after insert or update of status, reason on public.user_reports
  for each row execute function public.hmy_rank_on_report();

create function public.hmy_rank_on_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_recompute_rank(new.user_id);
  return null;
end $$;
create trigger professional_profiles_rank after update of status, test_fixture on public.professional_profiles
  for each row execute function public.hmy_rank_on_profile();

create function public.hmy_rank_on_suspension() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.hmy_recompute_rank(new.id);
  return null;
end $$;
create trigger profiles_rank after update of suspended_at on public.profiles
  for each row when (old.suspended_at is distinct from new.suspended_at)
  execute function public.hmy_rank_on_suspension();

-- Todos los profesionales empiezan con su categoría calculada.
select public.hmy_recompute_rank(user_id) from public.professional_profiles;

-- ---------------------------------------------------------------- Respuestas
-- Mismas columnas que antes y `rank_tier` al final; el perfil suma
-- `primary_category_id` para que "Programar" abra con su servicio elegido.
drop function public.search_professionals(smallint, int, int, text, boolean, numeric, text, int, int);
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
  completed_jobs int, is_available boolean, price_from numeric, is_verified boolean, rank_tier text
)
language sql stable security definer set search_path = public as $$
  select s.id, s.display_name, s.photo_path, s.primary_category_id, s.primary_category, s.specialties,
         s.city_id, s.city, s.zones, s.rating_avg, s.rating_count, s.completed_jobs, s.is_available,
         s.price_from, public.hmy_identity_verified(s.id), public.hmy_rank_tier_of(s.id)
  from public._search_professionals_base(p_city_id, p_category_id, p_zone_id, p_query, p_available_now,
                                         p_min_rating, p_sort, p_limit, p_offset) s
$$;

drop function public.get_professional_public(uuid);
create function public.get_professional_public(p_id uuid)
returns table (
  id uuid, display_name text, photo_path text, bio text, years_experience smallint,
  primary_category text, city text, zones text[], price_note text,
  rating_avg numeric, rating_count int, completed_jobs int, is_available boolean,
  is_verified boolean,
  services jsonb, portfolio jsonb, weekly_availability jsonb,
  primary_category_id int, rank_tier text
)
language sql stable security definer set search_path = public as $$
  select g.id, g.display_name, g.photo_path, g.bio, g.years_experience, g.primary_category, g.city, g.zones,
         g.price_note, g.rating_avg, g.rating_count, g.completed_jobs, g.is_available,
         public.hmy_identity_verified(g.id), g.services, g.portfolio, g.weekly_availability,
         (select pp.primary_category_id from public.professional_profiles pp where pp.user_id = g.id),
         public.hmy_rank_tier_of(g.id)
  from public._get_professional_public_base(p_id) g
$$;

alter function public.booking_detail(uuid) rename to _booking_detail_unranked;
create function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := public._booking_detail_unranked(p_booking); -- valida quién puede verlo
  v_offers jsonb;
  v_pro uuid;
begin
  if jsonb_typeof(v -> 'professional') = 'object' then
    v_pro := (v #>> '{professional,id}')::uuid;
    v := jsonb_set(v, '{professional,is_verified}', to_jsonb(public.hmy_identity_verified(v_pro)));
    v := jsonb_set(v, '{professional,rank_tier}', to_jsonb(public.hmy_rank_tier_of(v_pro)));
  end if;
  if jsonb_typeof(v #> '{price,offers}') = 'array' then
    select coalesce(jsonb_agg(case when jsonb_typeof(o -> 'professional') = 'object' then
             jsonb_set(jsonb_set(o, '{professional,is_verified}',
                                 to_jsonb(public.hmy_identity_verified((o #>> '{professional,id}')::uuid))),
                       '{professional,rank_tier}', to_jsonb(public.hmy_rank_tier_of((o #>> '{professional,id}')::uuid)))
             else o end order by ord), '[]'::jsonb)
    into v_offers
    from jsonb_array_elements(v #> '{price,offers}') with ordinality as t(o, ord);
    v := jsonb_set(v, '{price,offers}', v_offers);
  end if;
  return v;
end $$;

alter function public.trip_share_view(text) rename to _trip_share_view_fixture;
create function public.trip_share_view(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v jsonb := public._trip_share_view_fixture(p_token); -- valida el enlace
  v_pro uuid;
begin
  select b.professional_id into v_pro
  from public.trip_shares s join public.bookings b on b.id = s.booking_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if v ? 'professional_verified' then
    v := jsonb_set(v, '{professional_verified}', to_jsonb(public.hmy_identity_verified(v_pro)));
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_identity_verified(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_rank_metrics(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_rank_tier(jsonb) from public, anon, authenticated;
revoke execute on function public.hmy_recompute_rank(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_rank_tier_of(uuid) from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_booking() from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_review() from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_dispute() from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_report() from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_profile() from public, anon, authenticated;
revoke execute on function public.hmy_rank_on_suspension() from public, anon, authenticated;
grant execute on function public.hmy_recompute_rank(uuid) to service_role;
revoke execute on function public._booking_detail_unranked(uuid) from public, anon, authenticated;
revoke execute on function public._trip_share_view_fixture(text) from public, anon, authenticated;

-- search_professionals y get_professional_public quedan abiertas como antes.
revoke execute on function public.booking_detail(uuid) from public, anon;
grant execute on function public.booking_detail(uuid) to authenticated;
revoke execute on function public.trip_share_view(text) from public;
grant execute on function public.trip_share_view(text) to anon, authenticated;
