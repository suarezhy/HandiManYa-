-- HandiMan ¡Ya! — 0051 publicidad propia en el inicio del cliente.
--
-- Anuncios de negocios bolivianos que HandiMan ¡Ya! vende y administra; no hay
-- redes de publicidad de terceros.
-- - Solo el Propietario (is_admin) crea, aprueba, pausa, programa y quita
--   anuncios. Las tablas no tienen permisos directos: todo pasa por funciones.
-- - Un anuncio se muestra solo si está aprobado y dentro de sus fechas. Editar
--   uno aprobado lo vuelve a borrador: hay que aprobarlo otra vez.
-- - Rotación justa: entre los que pueden salir, sale el que menos se mostró
--   hoy (empates al azar).
-- - Se cuentan vistas y toques por anuncio y por día, sin guardar quién los
--   hizo: ni usuario, ni teléfono, ni ubicación.
-- - El enlace es opcional y solo https.

create table public.ad_campaigns (
  id serial primary key,
  advertiser text not null check (char_length(btrim(advertiser)) between 2 and 60),
  title text not null check (char_length(btrim(title)) between 2 and 50),
  body text check (body is null or char_length(body) <= 120),
  -- Imágenes en el bucket público "ads", carpeta de quien las subió.
  logo_path text check (logo_path is null or logo_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$'),
  image_path text check (image_path is null or image_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$'),
  link_url text check (link_url is null or (char_length(link_url) <= 300
                       and link_url ~ '^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/[^[:space:]]*)?$')),
  label text not null default 'Publicidad' check (label in ('Publicidad', 'Patrocinado')),
  city_id smallint references public.cities(id), -- null: todas las ciudades
  status text not null default 'draft' check (status in ('draft', 'approved', 'paused', 'removed')),
  starts_at timestamptz,
  ends_at timestamptz,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (starts_at is null or ends_at is null or ends_at > starts_at),
  check (status <> 'approved' or approved_by is not null)
);
alter table public.ad_campaigns enable row level security;
revoke all on public.ad_campaigns from public, anon, authenticated;
revoke all on sequence public.ad_campaigns_id_seq from public, anon, authenticated;

-- Totales por día (hora de Bolivia). Nada que identifique a una persona.
create table public.ad_daily_stats (
  campaign_id int not null references public.ad_campaigns(id) on delete cascade,
  day date not null,
  impressions int not null default 0 check (impressions >= 0),
  clicks int not null default 0 check (clicks >= 0),
  primary key (campaign_id, day)
);
alter table public.ad_daily_stats enable row level security;
revoke all on public.ad_daily_stats from public, anon, authenticated;

create trigger ad_campaigns_audit after insert or update or delete on public.ad_campaigns
  for each row execute function public.audit_admin_change();

-- Imágenes: públicas para mostrarlas; solo el Propietario sube, en su carpeta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ads', 'ads', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
create policy "hmy ads write" on storage.objects for insert to authenticated
  with check (bucket_id = 'ads' and public.is_admin() and public.storage_owner_folder(name) = auth.uid()::text);
create policy "hmy ads delete" on storage.objects for delete to authenticated
  using (bucket_id = 'ads' and public.is_admin());

-- ---------------------------------------------------------------- Clientes
create function public.hmy_ad_day() returns date
language sql stable as $$ select (now() at time zone 'America/La_Paz')::date $$;

create function public.hmy_ad_live(a public.ad_campaigns) returns boolean
language sql stable as $$
  select a.status = 'approved' and (a.starts_at is null or a.starts_at <= now()) and (a.ends_at is null or a.ends_at > now())
$$;

-- El anuncio para el inicio (o null si no hay ninguno). Cuenta una vista.
create function public.home_ad(p_city smallint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ad public.ad_campaigns;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select a.* into v_ad
  from public.ad_campaigns a
  left join public.ad_daily_stats s on s.campaign_id = a.id and s.day = public.hmy_ad_day()
  where public.hmy_ad_live(a) and (a.city_id is null or a.city_id = p_city)
  order by coalesce(s.impressions, 0), random()
  limit 1;
  if not found then return null; end if;

  insert into public.ad_daily_stats (campaign_id, day, impressions) values (v_ad.id, public.hmy_ad_day(), 1)
  on conflict (campaign_id, day) do update set impressions = ad_daily_stats.impressions + 1;

  return jsonb_build_object('id', v_ad.id, 'advertiser', v_ad.advertiser, 'title', v_ad.title, 'body', v_ad.body,
                            'logo_path', v_ad.logo_path, 'image_path', v_ad.image_path, 'label', v_ad.label,
                            'has_link', v_ad.link_url is not null);
end $$;

-- Un toque: cuenta el clic y devuelve el enlace (solo de un anuncio vigente).
create function public.ad_click(p_id int) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ad public.ad_campaigns;
begin
  if auth.uid() is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  select * into v_ad from public.ad_campaigns where id = p_id;
  if not found or not public.hmy_ad_live(v_ad) then raise exception 'HMY_NOT_FOUND'; end if;
  insert into public.ad_daily_stats (campaign_id, day, clicks) values (v_ad.id, public.hmy_ad_day(), 1)
  on conflict (campaign_id, day) do update set clicks = ad_daily_stats.clicks + 1;
  return v_ad.link_url;
end $$;

-- ---------------------------------------------------------------- Propietario
create function public.owner_ads() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'advertiser', a.advertiser, 'title', a.title, 'body', a.body,
             'logo_path', a.logo_path, 'image_path', a.image_path, 'link_url', a.link_url, 'label', a.label,
             'city_id', a.city_id, 'city_name', c.name, 'status', a.status, 'starts_at', a.starts_at, 'ends_at', a.ends_at,
             'live', public.hmy_ad_live(a), 'approved_at', a.approved_at, 'created_at', a.created_at,
             'impressions', coalesce(t.impressions, 0), 'clicks', coalesce(t.clicks, 0),
             'impressions_today', coalesce(d.impressions, 0), 'clicks_today', coalesce(d.clicks, 0))
           order by (a.status = 'removed'), public.hmy_ad_live(a) desc, a.created_at desc)
    from public.ad_campaigns a
    left join public.cities c on c.id = a.city_id
    left join lateral (select sum(impressions)::int as impressions, sum(clicks)::int as clicks
                       from public.ad_daily_stats where campaign_id = a.id) t on true
    left join public.ad_daily_stats d on d.campaign_id = a.id and d.day = public.hmy_ad_day()), '[]'::jsonb);
end $$;

-- Crea (p_id null) o cambia un anuncio. Siempre queda en borrador.
create function public.owner_save_ad(
  p_id int,
  p_advertiser text,
  p_title text,
  p_body text default null,
  p_logo_path text default null,
  p_image_path text default null,
  p_link_url text default null,
  p_label text default 'Publicidad',
  p_city smallint default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_id is null then
    insert into public.ad_campaigns (advertiser, title, body, logo_path, image_path, link_url, label, city_id,
                                     starts_at, ends_at, created_by)
    values (btrim(p_advertiser), btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), p_logo_path, p_image_path,
            nullif(btrim(coalesce(p_link_url, '')), ''), coalesce(p_label, 'Publicidad'), p_city, p_starts_at, p_ends_at,
            auth.uid())
    returning id into v_id;
  else
    update public.ad_campaigns set
      advertiser = btrim(p_advertiser), title = btrim(p_title), body = nullif(btrim(coalesce(p_body, '')), ''),
      logo_path = p_logo_path, image_path = p_image_path, link_url = nullif(btrim(coalesce(p_link_url, '')), ''),
      label = coalesce(p_label, 'Publicidad'), city_id = p_city, starts_at = p_starts_at, ends_at = p_ends_at,
      status = 'draft', approved_by = null, approved_at = null, updated_at = now()
    where id = p_id and status <> 'removed'
    returning id into v_id;
    if v_id is null then raise exception 'HMY_NOT_FOUND'; end if;
  end if;
  return v_id;
end $$;

-- approve: borrador o pausado → aprobado; pause: aprobado → pausado;
-- remove: cualquiera → quitado (se guarda para las cuentas, ya no sale).
create function public.owner_set_ad_status(p_id int, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_ad public.ad_campaigns;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  select * into v_ad from public.ad_campaigns where id = p_id for update;
  if not found or v_ad.status = 'removed' then raise exception 'HMY_NOT_FOUND'; end if;
  if p_action = 'approve' then
    if v_ad.status not in ('draft', 'paused') then raise exception 'HMY_INVALID_STATE'; end if;
    if v_ad.ends_at is not null and v_ad.ends_at <= now() then raise exception 'HMY_AD_EXPIRED'; end if;
    update public.ad_campaigns set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
    where id = p_id;
  elsif p_action = 'pause' then
    if v_ad.status <> 'approved' then raise exception 'HMY_INVALID_STATE'; end if;
    update public.ad_campaigns set status = 'paused', updated_at = now() where id = p_id;
  elsif p_action = 'remove' then
    update public.ad_campaigns set status = 'removed', updated_at = now() where id = p_id;
  else
    raise exception 'HMY_INVALID_STATE';
  end if;
end $$;

-- ---------------------------------------------------------------- Permisos
revoke execute on function public.hmy_ad_day() from public, anon, authenticated;
revoke execute on function public.hmy_ad_live(public.ad_campaigns) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.home_ad(smallint)', 'public.ad_click(int)', 'public.owner_ads()',
    'public.owner_save_ad(int, text, text, text, text, text, text, text, smallint, timestamptz, timestamptz)',
    'public.owner_set_ad_status(int, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
