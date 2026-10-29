-- "Lo necesito ahora" en DESARROLLO, solo lectura: qué cuentas de prueba (01,
-- 02, 03) podrían recibir un pedido ¡Ya!, quién más lo recibiría, y si están
-- la limpieza cada minuto y el tiempo real. Nunca muestra tokens, nombres,
-- teléfonos completos ni ubicaciones.
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/e2e/ya_status.sql
\set ON_ERROR_STOP 1
begin read only;

\echo '== Cuentas de prueba =='
select '…' || right(u.phone, 2)
       || ' · roles: ' || coalesce((select string_agg(r.role::text, ',' order by r.role) from public.user_roles r where r.user_id = u.id), 'ninguno')
       || ' · modo ' || coalesce(p.active_role::text, '?')
       || ' · profesional: ' || coalesce(pp.status::text, 'no')
       || coalesce(' · disponible=' || pp.is_available::text, '')
       || coalesce(' · suspendida=' || (p.suspended_at is not null)::text, '')
       || coalesce(' · ciudad ' || (select name from public.cities where id = pp.city_id), '')
       || coalesce(' · servicios: ' || (select string_agg(c.name || case when public.hmy_pro_cleared(pp.user_id, c.id) then '' else ' (sin habilitar)' end
                                                          || case when c.allows_ya then '' else ' (sin ¡Ya!)' end, ', ' order by c.name)
                                         from public.service_categories c
                                         where c.id = pp.primary_category_id
                                            or exists (select 1 from public.professional_services s where s.professional_id = pp.user_id and s.category_id = c.id)), '')
       || coalesce(' · zonas: ' || nullif((select count(*) from public.professional_zones z where z.professional_id = pp.user_id), 0)::text, '')
       || case when pp.user_id is null then ''
               when exists (select 1 from public.professional_locations l where l.professional_id = pp.user_id)
               then ' · base en el mapa, radio ' || (select service_radius_km from public.professional_locations where professional_id = pp.user_id) || ' km'
               else ' · sin base en el mapa' end
       || ' · teléfonos con avisos: ' || (select count(*) from public.push_devices d where d.user_id = u.id and d.disabled_at is null)
from auth.users u
join public.profiles p on p.id = u.id
left join public.professional_profiles pp on pp.user_id = u.id
where u.phone in ('59170000001', '59170000002', '59170000003', '59170000004', '59170000005')
order by u.phone;

\echo '== Otros profesionales que podrían recibir pedidos ¡Ya! (sin nombres) =='
select 'Aprobados y disponibles fuera de 01–05: ' || count(*)
       || ' · con teléfono con avisos: ' || count(*) filter (where exists (select 1 from public.push_devices d where d.user_id = pp.user_id and d.disabled_at is null))
from public.professional_profiles pp
join auth.users u on u.id = pp.user_id
where pp.status = 'approved' and pp.is_available
  and coalesce(u.phone, '') not in ('59170000001', '59170000002', '59170000003', '59170000004', '59170000005');
select 'Cuentas en total: ' || count(*) || ' · de prueba E2E que quedaron: ' || count(*) filter (where email like 'e2e-%@test.bo')
from auth.users;

\echo '== Pedidos ¡Ya! abiertos ahora =='
select 'Esperando profesional: ' || count(*) || ' · vencidos sin cerrar: '
       || count(*) filter (where public.hmy_response_deadline(b) < now())
from public.bookings b where b.status = 'awaiting_response' and b.mode = 'now';

\echo '== Limpieza cada minuto (vence pedidos sin respuesta) =='
select to_regclass('cron.job') is not null as hay_cron \gset
\if :hay_cron
select 'Tarea ' || jobname || ' · ' || schedule || ' · activa=' || active::text from cron.job
where jobname = 'hmy-booking-housekeeping';
select 'Última corrida: ' || coalesce(to_char(max(start_time) at time zone 'America/La_Paz', 'DD-MM HH24:MI'), 'nunca')
       || ' · fallidas en 24 h: ' || count(*) filter (where status = 'failed' and start_time > now() - interval '24 hours')
from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'hmy-booking-housekeeping');
\else
\echo 'pg_cron no está instalado: los pedidos vencen solo cuando alguien abre la app.'
\endif

\echo '== Tiempo real (la app se entera sin recargar) =='
select 'Tablas en supabase_realtime: ' || coalesce(string_agg(tablename, ', ' order by tablename), 'ninguna')
from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
  and tablename in ('bookings', 'notifications', 'messages', 'booking_offers');

commit;
