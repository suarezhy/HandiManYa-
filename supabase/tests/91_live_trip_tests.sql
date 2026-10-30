-- Pruebas de la ubicación en vivo y el viaje compartido (0015). Corre después
-- de 90 y usa sus cuentas (arr-*@test.bo).
\set ON_ERROR_STOP 1
\o /dev/null

create temp table t_tr (k text primary key, v text);
grant all on t_tr to authenticated, anon;

-- Pedido en camino, con la dirección del cliente en Santa Cruz.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_tr select 'b', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Gotea el tanque', 'Calle Viaje 1');
select test.logout();
update public.booking_addresses set latitude = -17.783300, longitude = -63.182100 where booking_id = (select v from t_tr where k = 'b')::uuid;
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.agree((select v from t_tr where k = 'b')::uuid);

-- 1. Solo mientras está "en camino".
select test.expect_error(format('select public.share_trip_location(%L, -17.79, -63.19)', (select v from t_tr where k = 'b')),
                         'HMY_TRIP_NOT_ACTIVE');
select public.update_job_progress((select v from t_tr where k = 'b')::uuid, 'on_the_way');
select test.expect_error(format('select public.share_trip_location(%L, 40.71, -74.0)', (select v from t_tr where k = 'b')),
                         'HMY_INVALID_LOCATION');
select test.eq(public.share_trip_location((select v from t_tr where k = 'b')::uuid, -17.800000, -63.200000, 15), true,
               'viaje: el profesional comparte su ubicación');
select test.eq(public.share_trip_location((select v from t_tr where k = 'b')::uuid, -17.799000, -63.199000, 15), false,
               'viaje: más de una vez cada 5 segundos se ignora');

-- 2. Solo el profesional asignado la manda; solo el cliente (y el equipo) la ve.
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.share_trip_location(%L, -17.79, -63.19)', (select v from t_tr where k = 'b')),
                         'HMY_FORBIDDEN');
do $$
declare t jsonb := public.trip_location((select v from t_tr where k = 'b')::uuid);
begin
  perform test.eq((t ->> 'live')::boolean, true, 'viaje: el cliente ve la ubicación en vivo');
  perform test.eq((t ->> 'latitude')::numeric, -17.800000::numeric, 'viaje: el cliente ve el último punto');
  perform test.eq((t ->> 'distance_km')::numeric > 0, true, 'viaje: con la distancia a su dirección');
  perform test.eq((t ->> 'eta_minutes')::int >= 1, true, 'viaje: y un tiempo estimado');
end $$;
select test.expect_error('select * from public.trip_locations', 'permission denied');
select test.login('00000000-0000-0000-0000-0000000009c2');
select test.expect_error(format('select public.trip_location(%L)', (select v from t_tr where k = 'b')), 'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-00000000000a');
select test.eq((public.trip_location((select v from t_tr where k = 'b')::uuid) ->> 'live')::boolean, true,
               'viaje: el equipo también la ve');

-- 3. Viaje compartido: enlace para un contacto de confianza.
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.expect_error(format('select public.create_trip_share(%L)', (select v from t_tr where k = 'b')), 'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_tr select 'tok', public.create_trip_share((select v from t_tr where k = 'b')::uuid, 'Mamá') ->> 'token';
select test.logout();
do $$ begin
  perform test.eq((select count(*)::int from public.trip_shares
                    where token_hash = (select v from t_tr where k = 'tok')), 0, 'compartir: no se guarda el enlace tal cual');
end $$;
select test.login(null);
do $$
declare v jsonb := public.trip_share_view((select v from t_tr where k = 'tok'));
begin
  perform test.eq(v ->> 'professional_name', 'Luis Llegada', 'compartir: el contacto ve quién va');
  perform test.eq((v ->> 'professional_verified')::boolean, true, 'compartir: y si está verificado');
  perform test.eq((v -> 'trip' ->> 'latitude')::numeric, -17.800000::numeric, 'compartir: ve la ubicación en vivo');
  perform test.eq(v::text ~* 'Calle Viaje|address|phone|telefono|celular', false,
                  'compartir: nunca la dirección ni los teléfonos');
end $$;
select test.expect_error($$select public.trip_share_view('noexiste-noexiste-noexiste')$$, 'HMY_SHARE_NOT_FOUND');
select test.expect_error($$select public.trip_share_view('mal')$$, 'HMY_SHARE_NOT_FOUND');
select test.expect_error('select * from public.trip_shares', 'permission denied');
select test.logout();

-- Máximo 3 enlaces activos; el cliente puede anular uno.
select test.login('00000000-0000-0000-0000-0000000009c1');
select public.create_trip_share((select v from t_tr where k = 'b')::uuid);
select public.create_trip_share((select v from t_tr where k = 'b')::uuid);
select test.expect_error(format('select public.create_trip_share(%L)', (select v from t_tr where k = 'b')), 'HMY_TOO_MANY_SHARES');
do $$ begin
  perform test.eq(jsonb_array_length(public.my_trip_shares((select v from t_tr where k = 'b')::uuid)), 3,
                  'compartir: el cliente ve sus enlaces activos');
end $$;
select public.revoke_trip_share((public.my_trip_shares((select v from t_tr where k = 'b')::uuid) -> 0 ->> 'id')::bigint);
select test.logout();
insert into t_tr select 'share', max(id)::text from public.trip_shares
 where booking_id = (select v from t_tr where k = 'b')::uuid and revoked_at is null;
select test.login('00000000-0000-0000-0000-0000000009c2');
select test.expect_error(format('select public.revoke_trip_share(%s)', (select v from t_tr where k = 'share')), 'HMY_NOT_FOUND');

-- 4. Al verificar la llegada, la ubicación se borra y ya no se comparte.
select test.arrive((select v from t_tr where k = 'b')::uuid, '00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c1');
select test.expect_error(format('select public.share_trip_location(%L, -17.79, -63.19)', (select v from t_tr where k = 'b')),
                         'HMY_TRIP_NOT_ACTIVE');
select test.login('00000000-0000-0000-0000-0000000009c1');
select test.eq((public.trip_location((select v from t_tr where k = 'b')::uuid) ->> 'live')::boolean, false,
               'viaje: con la llegada verificada se deja de compartir');
select test.logout();
select test.eq((select count(*)::int from public.trip_locations where booking_id = (select v from t_tr where k = 'b')::uuid), 0,
               'viaje: la ubicación se borra (sin historial)');
select test.login(null);
select test.eq(public.trip_share_view((select v from t_tr where k = 'tok')) ->> 'arrival_verified_at' is not null, true,
               'compartir: el contacto ve que la llegada se verificó');
select test.logout();

-- 5. Al terminar el trabajo, los enlaces dejan de servir.
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.update_job_progress((select v from t_tr where k = 'b')::uuid, 'in_progress');
select public.update_job_progress((select v from t_tr where k = 'b')::uuid, 'work_finished', 120);
select test.login('00000000-0000-0000-0000-0000000009c1');
select public.confirm_completion((select v from t_tr where k = 'b')::uuid);
select test.login(null);
select test.expect_error(format('select public.trip_share_view(%L)', (select v from t_tr where k = 'tok')), 'HMY_SHARE_NOT_FOUND');
select test.logout();

-- 6. Pausar: el profesional borra su punto.
select test.login('00000000-0000-0000-0000-0000000009c1');
insert into t_tr select 'b2', public.create_booking('00000000-0000-0000-0000-0000000009b1', 1, 'now', 'Cambiar la llave', 'Calle Viaje 2');
select test.login('00000000-0000-0000-0000-0000000009b1');
select test.agree((select v from t_tr where k = 'b2')::uuid);
select public.update_job_progress((select v from t_tr where k = 'b2')::uuid, 'on_the_way');
select public.share_trip_location((select v from t_tr where k = 'b2')::uuid, -17.8, -63.2);
select public.stop_trip_location((select v from t_tr where k = 'b2')::uuid);
select test.logout();
select test.eq((select count(*)::int from public.trip_locations where booking_id = (select v from t_tr where k = 'b2')::uuid), 0,
               'viaje: pausar borra la ubicación');
-- Cancelar también la borra.
select test.login('00000000-0000-0000-0000-0000000009b1');
select public.share_trip_location((select v from t_tr where k = 'b2')::uuid, -17.8, -63.2);
select public.cancel_booking((select v from t_tr where k = 'b2')::uuid, 'Se me pinchó la llanta');
select test.logout();
select test.eq((select count(*)::int from public.trip_locations where booking_id = (select v from t_tr where k = 'b2')::uuid), 0,
               'viaje: cancelar borra la ubicación');

\o
\echo 'PRUEBAS DE UBICACIÓN EN VIVO Y VIAJE COMPARTIDO PASARON'
