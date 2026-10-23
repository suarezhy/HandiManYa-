-- HandiMan ¡Ya! — 0005 reseñas, soporte y promociones.

create table public.reviews (
  id bigserial primary key,
  booking_id uuid not null unique references public.bookings(id),
  customer_id uuid not null references public.profiles(id),
  professional_id uuid not null references public.professional_profiles(user_id),
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 1000),
  is_hidden boolean not null default false,
  hidden_reason text,
  professional_reply text check (professional_reply is null or char_length(professional_reply) <= 1000),
  created_at timestamptz not null default now()
);
create index reviews_professional_idx on public.reviews (professional_id, created_at desc);

-- La calificación del profesional se calcula solo con reseñas reales y visibles.
create function public.refresh_professional_rating() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pro uuid := coalesce(new.professional_id, old.professional_id);
begin
  update public.professional_profiles pp
  set rating_avg = coalesce((select round(avg(rating)::numeric, 2) from public.reviews
                             where professional_id = v_pro and not is_hidden), 0),
      rating_count = (select count(*) from public.reviews where professional_id = v_pro and not is_hidden)
  where pp.user_id = v_pro;
  return null;
end $$;

create trigger reviews_refresh_rating after insert or update or delete on public.reviews
  for each row execute function public.refresh_professional_rating();

create function public.submit_review(p_booking uuid, p_rating int, p_comment text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_id bigint;
begin
  select * into b from public.bookings where id = p_booking;
  if not found or b.customer_id <> auth.uid() then raise exception 'HMY_FORBIDDEN'; end if;
  if b.status <> 'completed' then raise exception 'HMY_REVIEW_NOT_ALLOWED'; end if;
  if p_rating not between 1 and 5 then raise exception 'HMY_INVALID_RATING'; end if;
  insert into public.reviews (booking_id, customer_id, professional_id, rating, comment)
  values (b.id, b.customer_id, b.professional_id, p_rating, nullif(trim(p_comment), ''))
  returning id into v_id;
  perform public.notify(b.professional_id, 'review', 'Recibiste una reseña',
                        p_rating || ' de 5 estrellas', jsonb_build_object('booking_id', b.id));
  return v_id;
end $$;

create function public.reply_to_review(p_review bigint, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.reviews set professional_reply = nullif(trim(p_reply), '')
  where id = p_review and professional_id = auth.uid();
  if not found then raise exception 'HMY_FORBIDDEN'; end if;
end $$;

create function public.moderate_review(p_review bigint, p_hidden boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_hidden and coalesce(trim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  update public.reviews set is_hidden = p_hidden, hidden_reason = p_reason where id = p_review;
  perform public.audit('review.moderate', 'reviews', p_review::text,
                       jsonb_build_object('hidden', p_hidden, 'reason', p_reason));
end $$;

-- Reseñas públicas: sin datos personales del cliente salvo su primer nombre.
create function public.professional_reviews(p_professional uuid, p_limit int default 20, p_offset int default 0)
returns table (id bigint, rating smallint, comment text, author_first_name text,
               professional_reply text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.rating, r.comment,
         coalesce(nullif(split_part(p.full_name, ' ', 1), ''), 'Cliente'),
         r.professional_reply, r.created_at
  from public.reviews r
  join public.profiles p on p.id = r.customer_id
  where r.professional_id = p_professional and not r.is_hidden
    and public.is_approved_professional(p_professional)
  order by r.created_at desc
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;

-- ---------------------------------------------------------------------------
-- Soporte
-- ---------------------------------------------------------------------------
create table public.support_tickets (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id),
  booking_id uuid references public.bookings(id),
  subject text not null check (char_length(subject) between 3 and 120),
  body text not null check (char_length(body) between 5 and 3000),
  status text not null default 'open' check (status in ('open', 'in_progress', 'closed')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger support_tickets_touch before update on public.support_tickets
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Promociones del inicio (las administra el administrador)
-- ---------------------------------------------------------------------------
create table public.promotions (
  id serial primary key,
  city_id smallint references public.cities(id),
  title text not null,
  subtitle text,
  cta_label text not null default '¡Encuéntrala Ya!',
  cta_route text not null default '/buscar',
  image_path text,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  sort_order int not null default 100
);

insert into public.promotions (title, subtitle, cta_label, cta_route, sort_order)
values ('¿Necesitas ayuda?', 'Profesionales verificados cerca de ti, cuando los necesitas.',
        '¡Encuéntrala Ya!', '/buscar?ahora=1', 1);

alter table public.reviews enable row level security;
alter table public.support_tickets enable row level security;
alter table public.promotions enable row level security;

create policy reviews_participants on public.reviews for select
  using (customer_id = auth.uid() or professional_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.reviews from anon, authenticated;

create policy tickets_own_read on public.support_tickets for select using (user_id = auth.uid() or public.is_admin());
create policy tickets_own_insert on public.support_tickets for insert
  with check (user_id = auth.uid() and status = 'open' and admin_note is null
              and (booking_id is null or public.is_booking_participant(booking_id)));
create policy tickets_admin_update on public.support_tickets for update
  using (public.is_admin()) with check (public.is_admin());
revoke delete on public.support_tickets from anon, authenticated;

create policy promotions_read on public.promotions for select
  using ((is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()))
         or public.is_admin());
create policy promotions_admin on public.promotions for all using (public.is_admin()) with check (public.is_admin());

revoke execute on function public.refresh_professional_rating() from public, anon, authenticated;
revoke execute on function public.submit_review(uuid, int, text) from public, anon;
revoke execute on function public.reply_to_review(bigint, text) from public, anon;
revoke execute on function public.moderate_review(bigint, boolean, text) from public, anon;
