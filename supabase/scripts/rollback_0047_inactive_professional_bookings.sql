-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0047
-- (20261026004700_inactive_professional_bookings) en el proyecto de DESARROLLO.
-- Los pedidos que ya se cancelaron quedan cancelados. Después de revertir, un
-- profesional suspendido vuelve a poder seguir con sus pedidos abiertos.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0047_inactive_professional_bookings.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if to_regprocedure('public.hmy_cancel_unstarted_bookings(uuid, text)') is null then
    raise exception 'HMY: 0047 no está aplicada; no se revirtió nada.';
  end if;
end $$;
drop trigger bookings_pro_active_guard on public.bookings;
drop trigger professional_profiles_inactive_cleanup on public.professional_profiles;
drop trigger profiles_suspension_cleanup on public.profiles;
drop function public.hmy_booking_pro_active_guard();
drop function public.hmy_pro_inactive_cleanup();
drop function public.hmy_suspension_cleanup();
drop function public.hmy_cancel_unstarted_bookings(uuid, text);
-- La dirección vuelve a la regla de 0003.
create or replace function public.can_see_booking_address(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bookings b
    where b.id = p_booking and (
      b.customer_id = auth.uid()
      or public.is_admin()
      or (b.professional_id = auth.uid()
          and b.status in ('confirmed', 'on_the_way', 'in_progress', 'work_finished', 'disputed'))
    )
  )
$$;
drop function public.hmy_professional_active(uuid);
delete from public.booking_transitions where actor = 'system' and to_status = 'cancelled'
  and from_status in ('quote_sent', 'confirmed', 'on_the_way');
delete from supabase_migrations.schema_migrations where version = '20261026004700';
commit;
\echo 'Reversión de 0047 aplicada.'
