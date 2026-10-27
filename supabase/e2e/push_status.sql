-- Estado de los avisos push en DESARROLLO, solo lectura. Nunca muestra tokens:
-- solo cuántos teléfonos hay, su plataforma, cuándo se registraron, si el token
-- tiene la forma de un token de FCM y cómo va la cola de envíos.
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/e2e/push_status.sql
\set ON_ERROR_STOP 1
begin read only;

\echo '== Teléfonos registrados (por cuenta; números de prueba por sus 2 últimos dígitos) =='
select coalesce('…' || right(u.phone, 2), 'otra cuenta') || ' · ' || d.platform
       || ' · activo=' || (d.disabled_at is null)::text
       || coalesce(' (' || d.disabled_reason || ')', '')
       || ' · registrado ' || to_char(d.created_at at time zone 'America/La_Paz', 'DD-MM HH24:MI')
       || ' · visto ' || to_char(d.last_seen_at at time zone 'America/La_Paz', 'DD-MM HH24:MI')
       || ' · largo del token ' || length(d.token)
       || ' · forma de FCM=' || (d.token ~ '^[A-Za-z0-9_-]{10,}:[A-Za-z0-9_-]{100,}$')::text
from public.push_devices d
left join auth.users u on u.id = d.user_id and u.phone in ('59170000001', '59170000002', '59170000003')
order by d.created_at;
select 'Teléfonos activos en total: ' || count(*) from public.push_devices where disabled_at is null;

\echo '== Cola de envíos (últimos 7 días) =='
select n.kind || ' · ' || o.status || ' · ' || count(*)
       || coalesce(' · último error: ' || max(o.last_error), '')
from public.push_outbox o join public.notifications n on n.id = o.notification_id
where o.created_at > now() - interval '7 days'
group by n.kind, o.status order by n.kind, o.status;
select 'Pendientes que saldrían al activar send-push (menos de 24 h): ' || count(*)
       || ' · de cuántas cuentas: ' || count(distinct d.user_id)
from public.push_outbox o join public.push_devices d on d.id = o.device_id
where o.status in ('pending', 'sending') and o.created_at > now() - interval '24 hours' and d.disabled_at is null;

\echo '== ¿Hay un webhook que llame a send-push? =='
select 'Disparadores de webhook en push_outbox: ' || count(*)
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where c.relname = 'push_outbox' and not t.tgisinternal;

commit;
