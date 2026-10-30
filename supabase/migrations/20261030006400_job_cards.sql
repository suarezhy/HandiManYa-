-- Tarjetas de "Mis trabajos" y "Mis solicitudes" (pedido del dueño, 30-10-2026):
-- cada tarjeta muestra el número de solicitud, el precio acordado (o "Precio
-- pendiente"), la otra persona, la hora y la zona.
--
-- 1. my_bookings devuelve el precio acordado y los montos aparte aceptados.
-- 2. Los trabajos en curso y los pedidos abiertos salen siempre; el límite de
--    100 filas solo recorta el historial más viejo. Antes un trabajo activo
--    podía quedar fuera si había muchos pedidos más nuevos.
--
-- Solo reemplaza la función (cambia sus columnas); no toca datos.

drop function public.my_bookings(text);
create function public.my_bookings(p_as text default 'customer')
returns table (
  id uuid, code text, status public.booking_status, mode public.booking_mode,
  category_id int, category text, city text, zone text,
  description text, scheduled_start timestamptz, created_at timestamptz,
  other_user_id uuid, other_name text, other_photo_path text,
  quote_amount numeric, final_amount numeric, has_review boolean, is_offer boolean, distance_km numeric,
  problems text[], agreed_amount numeric, extras_amount numeric
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
         coalesce(b.problem_labels, '{}'),
         b.agreed_amount, b.extras_amount
  from public.bookings b
  join public.service_categories sc on sc.id = b.category_id
  join public.cities c on c.id = b.city_id
  left join public.service_zones z on z.id = b.zone_id
  left join public.professional_profiles pp on pp.user_id = b.professional_id
  left join public.profiles cp on cp.id = b.customer_id
  where (p_as = 'customer' and b.customer_id = auth.uid())
     or (p_as = 'professional' and (b.professional_id = auth.uid() or public.has_pending_offer(b.id)))
  order by b.status in ('completed', 'cancelled'), b.created_at desc
  limit 100 + (select count(*) from public.bookings x
               where x.status not in ('completed', 'cancelled')
                 and ((p_as = 'customer' and x.customer_id = auth.uid())
                      or (p_as = 'professional' and x.professional_id = auth.uid())))
$$;

revoke execute on function public.my_bookings(text) from public, anon;
grant execute on function public.my_bookings(text) to authenticated;
