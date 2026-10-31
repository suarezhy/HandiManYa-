-- La "otra mitad" de la prueba ¡Ya! con un solo teléfono, en DESARROLLO.
-- Mientras el Samsung tiene abierta una cuenta de prueba, esto hace lo de la
-- otra cuenta por el mismo camino que la app (las mismas funciones, con la
-- sesión de esa cuenta):
--   cliente-pide  la cuenta …01 pide Plomería ¡Ya! en la ciudad de …02
--   pro-acepta    la cuenta …02 acepta el último pedido ¡Ya! abierto de …01
--   pro-en-camino la cuenta …02 marca "Voy en camino" en ese pedido
--   estado        solo lectura: el último pedido de …01 y sus avisos
-- Se niega si el pedido llegaría a otro profesional o si hay teléfonos activos
-- de otras cuentas. Nunca muestra tokens ni el código de llegada.
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -v action=estado -f supabase/e2e/samsung_ya.sql
\set ON_ERROR_STOP 1
begin;
-- Sin las cuentas de prueba, \gset no recibe fila y psql se detiene.
select id as c_id from auth.users where phone = '59170000001' \gset
select id as p_id from auth.users where phone = '59170000002' \gset
select :'action' in ('cliente-pide', 'pro-acepta', 'pro-en-camino', 'estado') as action_ok \gset
\if :action_ok
\else
  \echo 'Acción desconocida: usa cliente-pide, pro-acepta, pro-en-camino o estado.'
  \quit
\endif

do $$
begin
  if exists (select 1 from public.push_devices d join auth.users u on u.id = d.user_id
             where d.disabled_at is null and u.phone not in ('59170000001', '59170000002', '59170000003')) then
    raise exception 'Hay teléfonos activos de otras cuentas: no se hace nada';
  end if;
end $$;

select :'action' = 'cliente-pide' as do_request, :'action' = 'pro-acepta' as do_accept,
       :'action' = 'pro-en-camino' as do_trip \gset

\if :do_request
  select (select id from public.service_categories where slug = 'plomeria') as cat,
         (select city_id from public.professional_profiles where user_id = :'p_id') as city \gset
  select coalesce(string_agg(case when e = :'p_id'::uuid then '…02' else 'otra cuenta' end, ', '), 'nadie') as who
    from public.ya_eligible_professionals(:'cat', :'city', null, :'c_id') e \gset
  select :'who' = '…02' as only_02 \gset
  \if :only_02
    select set_config('request.jwt.claims', json_build_object('sub', :'c_id', 'role', 'authenticated')::text, true)
      is not null as claims_ok \gset
    select 'Pedido ¡Ya! de …01 creado: ' || left(public.create_ya_request(:'cat', :'city', 'Prueba Samsung: gotea el caño',
      'Calle de prueba 1', null, null, 'cash')::text, 8) || '…';
  \else
    \echo 'No se pide nada. El pedido le llegaría a:' :who
    \echo 'Tiene que llegarle solo a …02: aprobado, disponible para ¡Ya!, con Plomería y sin un trabajo en curso.'
  \endif
\endif

\if :do_accept
  select id as b_id from public.bookings
   where customer_id = :'c_id' and mode = 'now' and status = 'awaiting_response'
   order by created_at desc limit 1 \gset
  select set_config('request.jwt.claims', json_build_object('sub', :'p_id', 'role', 'authenticated')::text, true)
    is not null as claims_ok \gset
  select '…02 aceptó el pedido ' || left(:'b_id', 8) || '…: ' || public.claim_ya_request(:'b_id');
\endif

\if :do_trip
  select id as b_id from public.bookings
   where customer_id = :'c_id' and professional_id = :'p_id' and status = 'confirmed'
   order by created_at desc limit 1 \gset
  select set_config('request.jwt.claims', json_build_object('sub', :'p_id', 'role', 'authenticated')::text, true)
    is not null as claims_ok \gset
  select '…02 va en camino al pedido ' || left(:'b_id', 8) || '…: ' || public.update_job_progress(:'b_id', 'on_the_way');
\endif

-- Estado (siempre): el último pedido de …01 y los avisos de ese pedido.
select 'Último pedido de …01: ' || left(b.id::text, 8) || '… · ' || b.mode || ' · ' || b.status
       || ' · profesional: ' || case when b.professional_id = :'p_id' then '…02' when b.professional_id is null then 'ninguno'
                                     else 'otra cuenta' end
  from public.bookings b where b.customer_id = :'c_id' order by b.created_at desc limit 1;
select 'Aviso a ' || case when n.user_id = :'c_id' then '…01' else '…02' end || ': ' || n.kind || ' · "' || n.title || '" · '
       || to_char(n.created_at at time zone 'America/La_Paz', 'HH24:MI:SS') || ' · al teléfono: '
       || coalesce((select string_agg(o.status, ', ') from public.push_outbox o where o.notification_id = n.id), 'sin teléfono')
  from public.notifications n
 where n.data ->> 'booking_id' = (select b.id::text from public.bookings b where b.customer_id = :'c_id'
                                   order by b.created_at desc limit 1)
 order by n.created_at;
commit;
