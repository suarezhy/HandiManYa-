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

\echo '== Cada envío de las últimas 3 horas (hora de La Paz) =='
select '#' || o.id || ' · ' || n.kind || ' · ' || coalesce('…' || right(u.phone, 2), 'otra cuenta')
       || ' · ' || o.status || ' · intentos ' || o.attempts
       || ' · creado ' || to_char(o.created_at at time zone 'America/La_Paz', 'HH24:MI:SS')
       || coalesce(' · tomado ' || to_char(o.claimed_at at time zone 'America/La_Paz', 'HH24:MI:SS'), '')
       || coalesce(' · enviado ' || to_char(o.sent_at at time zone 'America/La_Paz', 'HH24:MI:SS'), '')
       || coalesce(' · error: ' || left(o.last_error, 100), '')
from public.push_outbox o
join public.notifications n on n.id = o.notification_id
join public.push_devices d on d.id = o.device_id
left join auth.users u on u.id = d.user_id and u.phone in ('59170000001', '59170000002', '59170000003')
where o.created_at > now() - interval '3 hours'
order by o.id;
select 'Avisos de prueba creados en 3 h (en la app): ' || count(*)
from public.notifications where kind = 'push_test' and created_at > now() - interval '3 hours';

\echo '== ¿Hay un webhook que llame a send-push? =='
select 'Disparadores de webhook en push_outbox: ' || count(*)
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where c.relname = 'push_outbox' and not t.tgisinternal;
-- Cada webhook: tabla, momento, eventos, función y adónde llama. Del encabezado
-- secreto solo se dice si está y si mide al menos 32; nunca su valor.
with t as (
  select t.tgname, n.nspname || '.' || c.relname as tabla, t.tgenabled, t.tgtype,
         pn.nspname || '.' || p.proname as funcion,
         string_to_array(encode(t.tgargs, 'escape'), '\000') as args
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
  where c.relname = 'push_outbox' and not t.tgisinternal
), h as (
  select t.*, case when args[3] ~ '^\s*\{' then args[3]::jsonb end as headers from t
)
select 'Webhook ' || tgname || ' · tabla ' || tabla
       || ' · ' || case when tgtype & 2 = 2 then 'antes' else 'después' end
       || ' · eventos: ' || concat_ws(',', case when tgtype & 4 = 4 then 'INSERT' end,
            case when tgtype & 16 = 16 then 'UPDATE' end, case when tgtype & 8 = 8 then 'DELETE' end,
            case when tgtype & 32 = 32 then 'TRUNCATE' end)
       || ' · ' || case when tgtype & 1 = 1 then 'por fila' else 'por sentencia' end
       || ' · activo=' || (tgenabled <> 'D')::text
       || ' · función ' || funcion
       || ' · método ' || coalesce(args[2], '?')
       || ' · dirección ' || coalesce(args[1], '?')
       || ' · es la de send-push en dev=' || (args[1] = 'https://yldqopeldibwgbwmdnzy.supabase.co/functions/v1/send-push')::text
       || ' · encabezados: ' || coalesce((select string_agg(k, ', ' order by k) from jsonb_object_keys(headers) k), 'ninguno')
       || ' · x-hmy-push-secret presente=' || (headers ? 'x-hmy-push-secret')::text
       || ' · mide 32 o más=' || coalesce((length(headers ->> 'x-hmy-push-secret') >= 32)::text, 'false')
       || ' · sin espacios=' || coalesce(((headers ->> 'x-hmy-push-secret') !~ '\s')::text, 'false')
       || ' · espera ' || coalesce(args[5], '?') || ' ms'
from h order by tgname;
select 'pg_net instalado: ' || exists (select 1 from pg_extension where extname = 'pg_net')::text;

\echo '== Últimas respuestas a los webhooks, 24 h (solo estado; el texto solo si es de send-push) =='
select to_regclass('net._http_response') is not null as hay_net \gset
\if :hay_net
select to_char(r.created at time zone 'America/La_Paz', 'DD-MM HH24:MI:SS') || ' · HTTP '
       || coalesce(r.status_code::text, 'sin respuesta')
       || case when r.content ~ '^\{"(error|sent)"' then ' · ' || left(r.content, 80)
               when r.error_msg is not null then ' · error de pg_net: ' || left(r.error_msg, 100) else '' end
from net._http_response r
where r.created > now() - interval '24 hours'
order by r.created desc limit 10;
\else
\echo 'No hay registro de respuestas (pg_net no está instalado).'
\endif

commit;
