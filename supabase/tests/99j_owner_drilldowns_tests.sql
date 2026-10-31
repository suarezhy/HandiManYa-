-- Detalle de cada número del panel (0041). Corre después de 99i (usa test.grant de 99d).
-- Cuentas de prueba propias (…0d9e…); ningún dato real cambia.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000d9e0001', '59170099801', now(), '{"full_name": "Dueño Detalle"}'),
  ('00000000-0000-0000-0000-00000d9e0002', '59170099802', now(), '{"full_name": "Gerente Detalle"}'),
  ('00000000-0000-0000-0000-00000d9e0003', '59170099803', now(), '{"full_name": "Empleado Detalle"}'),
  ('00000000-0000-0000-0000-00000d9e0004', '59170099804', now(), '{"full_name": "Profesional Detalle"}'),
  ('00000000-0000-0000-0000-00000d9e0005', '59170099805', now(), '{"full_name": "Clienta Detalle Única"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-00000d9e0001', 'admin');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('00000000-0000-0000-0000-00000d9e0004', 'Profesional Detalle', 1, 1, 'approved', true);
select test.grant('00000000-0000-0000-0000-00000d9e0001', '00000000-0000-0000-0000-00000d9e0002', 'manager');
select test.grant('00000000-0000-0000-0000-00000d9e0001', '00000000-0000-0000-0000-00000d9e0003', 'employee');
select test.logout();

-- Un pedido de hoy (completado) y uno cancelado, con monto y comisión.
insert into public.bookings (id, code, customer_id, professional_id, category_id, city_id, mode, description, status,
                             final_amount, commission_captured, completed_at)
values ('00000000-0000-0000-0000-00000d9eb001', 'DET99J01', '00000000-0000-0000-0000-00000d9e0005',
        '00000000-0000-0000-0000-00000d9e0004', 1, 1, 'now', 'Arreglo de prueba del detalle', 'completed',
        150, 15, now());
insert into public.bookings (id, code, customer_id, category_id, city_id, mode, description, status, cancelled_at,
                             cancel_reason)
values ('00000000-0000-0000-0000-00000d9eb002', 'DET99J02', '00000000-0000-0000-0000-00000d9e0005', 1, 1, 'now',
        'Otro arreglo de prueba', 'cancelled', now(), 'Prueba');
insert into public.booking_addresses (booking_id, address_line, latitude, longitude)
values ('00000000-0000-0000-0000-00000d9eb001', 'Calle Secreta 123', -16.5, -68.1);
insert into public.booking_events (booking_id, from_status, to_status, actor_id)
values ('00000000-0000-0000-0000-00000d9eb001', 'in_progress', 'completed', '00000000-0000-0000-0000-00000d9e0004');

-- ---------------------------------------------------------------------------
-- Quién llega a qué
-- ---------------------------------------------------------------------------
do $$
declare u uuid; q text;
begin
  -- Empleado, profesional y cliente: ninguna de las listas.
  foreach u in array array['00000000-0000-0000-0000-00000d9e0003', '00000000-0000-0000-0000-00000d9e0004',
                           '00000000-0000-0000-0000-00000d9e0005']::uuid[] loop
    perform test.login(u);
    foreach q in array array[
      'select public.ops_bookings()', $q$select public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001')$q$,
      $q$select public.ops_open_booking_case('00000000-0000-0000-0000-00000d9eb001', 'Revisar esto')$q$,
      'select public.admin_people()', $q$select public.ops_risk_items('safety')$q$, 'select public.owner_wallets()'] loop
      perform test.expect_error(q, 'HMY_FORBIDDEN');
    end loop;
  end loop;
  -- El gerente: pedidos, personas y riesgos sí; billeteras no.
  perform test.login('00000000-0000-0000-0000-00000d9e0002');
  perform test.expect_error('select public.owner_wallets()', 'HMY_FORBIDDEN');
  perform test.expect_error($q$select * from public.owner_finance_transactions(null, null, 50,
                               '00000000-0000-0000-0000-00000d9e0004')$q$, 'HMY_FORBIDDEN');
  perform test.logout();
  foreach q in array array['select public.ops_bookings()', 'select public.admin_people()',
                           $q$select public.ops_risk_items('fraud')$q$, 'select public.owner_wallets()'] loop
    perform test.expect_error(q, 'HMY_FORBIDDEN');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Pedidos: el total coincide con el panel; montos solo para el propietario
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-00000d9e0001');
select test.eq((public.ops_bookings('hoy') ->> 'total')::int, (public.owner_dashboard() ->> 'bookings_today')::int,
               'pedidos: el total de hoy es el del panel');
select test.eq((public.ops_bookings('activos') ->> 'total')::int, (public.owner_dashboard() ->> 'active_bookings')::int,
               'pedidos: activos como en el panel');
select test.eq((public.ops_bookings('completados_hoy') ->> 'total')::int,
               (public.owner_dashboard() ->> 'completed_today')::int, 'pedidos: completados hoy como en el panel');
select test.eq((public.ops_bookings('cancelados_hoy') ->> 'total')::int,
               (public.owner_dashboard() ->> 'cancelled_today')::int, 'pedidos: cancelados hoy como en el panel');
select test.eq((select coalesce(sum((i ->> 'final_amount')::numeric), 0)
                from jsonb_array_elements(public.ops_bookings('completados_mes', null, 200) -> 'items') i),
               (public.owner_dashboard() ->> 'revenue_month')::numeric,
               'pedidos: lo pagado este mes suma lo del panel');
select test.eq((public.ops_bookings('hoy', 'det99j01') -> 'items' -> 0 ->> 'code'), 'DET99J01',
               'pedidos: busca por código sin importar mayúsculas');
select test.eq((public.ops_bookings('hoy', 'clienta detalle') ->> 'total')::int, 2,
               'pedidos: busca por el nombre del cliente');
select test.eq((public.ops_bookings('completados_hoy', 'DET99J01') -> 'items' -> 0 ->> 'commission_captured')::numeric,
               15::numeric, 'pedidos: el propietario ve la comisión');
select test.expect_error($$select public.ops_bookings('cualquiera')$$, 'HMY_INVALID_STATUS');

select test.login('00000000-0000-0000-0000-00000d9e0002');
select test.eq((public.ops_bookings('hoy', 'DET99J01') ->> 'total')::int, 1, 'pedidos: el gerente los ve');
select test.eq((public.ops_bookings('hoy') ->> 'total')::int, (public.ops_dashboard() ->> 'bookings_today')::int,
               'pedidos: el total de hoy es el del panel del gerente');
select test.eq((public.ops_bookings('activos') ->> 'total')::int, (public.ops_dashboard() ->> 'active_bookings')::int,
               'pedidos: activos como en el panel del gerente');
select test.eq((public.ops_bookings('completados_hoy') ->> 'total')::int,
               (public.ops_dashboard() ->> 'completed_today')::int, 'pedidos: completados hoy como en el panel del gerente');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_bookings('recientes', null, 200) -> 'items') i
                where i ? 'final_amount' or i ? 'commission_captured' or i ? 'commission_reserved'
                   or i ? 'quote_amount'), 0, 'pedidos: el gerente no ve montos');
select test.eq(public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001') ? 'final_amount', false,
               'pedidos: el detalle del gerente tampoco trae montos');
select test.eq(position('Secreta' in public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001')::text), 0,
               'pedidos: el detalle nunca trae la dirección');
select test.eq(position('-68.1' in public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001')::text), 0,
               'pedidos: ni la ubicación');
select test.eq((public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001') -> 'events' -> 0 ->> 'actor'),
               'profesional', 'pedidos: el historial dice quién hizo cada cambio, sin nombres');

-- Abrir un caso desde un pedido: con motivo, una vez, auditado.
select test.expect_error($$select public.ops_open_booking_case('00000000-0000-0000-0000-00000d9eb001', 'no')$$,
                         'HMY_REASON_REQUIRED');
create temp table opened as
  select public.ops_open_booking_case('00000000-0000-0000-0000-00000d9eb001', 'El cliente dice que cobró de más',
                                      'fraud') as id;
grant select on opened to authenticated;
select test.eq(public.ops_open_booking_case('00000000-0000-0000-0000-00000d9eb001', 'Otra vez el mismo pedido'),
               (select id from opened), 'caso del pedido: si ya hay uno abierto, devuelve ese');
select test.eq((select priority || '/' || category from public.ops_cases where id = (select id from opened)),
               'urgent/fraud', 'caso del pedido: fraude entra urgente');
select test.eq((public.ops_booking_detail('00000000-0000-0000-0000-00000d9eb001') ->> 'open_case_id')::bigint,
               (select id from opened), 'caso del pedido: el pedido muestra su caso abierto');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log
                where action = 'case.open_booking' and target_id = (select id from opened)::text
                  and actor_id = '00000000-0000-0000-0000-00000d9e0002'), 1,
               'caso del pedido: queda en la auditoría con quién lo abrió');
select test.login('00000000-0000-0000-0000-00000d9e0002');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_cases_list('urgent')) c
                where (c ->> 'id')::bigint = (select id from opened)), 1, 'casos: aparece en Urgentes');
select test.eq(((public.ops_case_detail((select id from opened)) -> 'source') ->> 'code'), 'DET99J01',
               'caso del pedido: el caso muestra el pedido');
select test.eq(((public.ops_case_detail((select id from opened)) -> 'source') ? 'final_amount'), false,
               'caso del pedido: sin montos');

-- El empleado asignado ve el caso, pero no puede cerrarlo (lo escala).
select public.ops_assign_case((select id from opened), '00000000-0000-0000-0000-00000d9e0003');
select test.login('00000000-0000-0000-0000-00000d9e0003');
select test.eq(((public.ops_case_detail((select id from opened)) -> 'source') ->> 'code'), 'DET99J01',
               'caso del pedido: el empleado asignado lo ve');
select test.expect_error(format('select public.ops_set_case_status(%s, %L, %L)', (select id from opened), 'resolved',
                                'Listo'), 'HMY_ESCALATE_REQUIRED');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_cases_list('all')) c
                where (c ->> 'assigned_to') is distinct from '00000000-0000-0000-0000-00000d9e0003'), 0,
               'casos: el empleado sigue viendo solo los suyos aunque pida todos');

-- ---------------------------------------------------------------------------
-- Casos urgentes y escalados al propietario: como en el panel
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-00000d9e0001');
select test.eq(jsonb_array_length(public.ops_cases_list('urgent')), (public.owner_dashboard() ->> 'urgent_cases')::int,
               'casos: Urgentes tiene lo que dice el panel');
select test.eq(jsonb_array_length(public.ops_cases_list('escalated_owner')),
               (public.owner_dashboard() ->> 'escalated_to_owner')::int,
               'casos: Escalados a ti tiene lo que dice el panel');
select test.eq(jsonb_array_length(public.ops_cases_list('unassigned')),
               (public.owner_dashboard() ->> 'unassigned_cases')::int,
               'casos: Sin asignar tiene lo que dice el panel');

-- ---------------------------------------------------------------------------
-- Personas
-- ---------------------------------------------------------------------------
select test.eq((public.admin_people('clientes') ->> 'total')::int, (public.owner_dashboard() ->> 'customers')::int,
               'personas: clientes como en el panel');
select test.eq((public.admin_people('profesionales') ->> 'total')::int,
               (public.owner_dashboard() ->> 'approved_professionals')::int, 'personas: aprobados como en el panel');
select test.eq((public.admin_people('disponibles') ->> 'total')::int,
               (public.owner_dashboard() ->> 'available_professionals')::int,
               'personas: disponibles como en el panel');
select test.eq((public.admin_people('disponibles', 'profesional detalle') -> 'items' -> 0 ->> 'is_available')::boolean,
               true, 'personas: busca entre los disponibles');
select test.eq((public.admin_people('profesionales', 'Clienta Detalle') ->> 'total')::int, 0,
               'personas: una clienta no sale entre profesionales');

-- ---------------------------------------------------------------------------
-- Seguridad y fraude: mismas fuentes que el panel
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-00000d9e0005');
select public.report_user('00000000-0000-0000-0000-00000d9e0004', 'acoso');
select test.login('00000000-0000-0000-0000-00000d9e0001');
select test.eq((public.ops_risk_items('safety') ->> 'total')::int, (public.owner_dashboard() ->> 'safety_incidents')::int,
               'riesgos: seguridad tiene lo que dice el panel');
select test.eq((public.ops_risk_items('fraud') ->> 'total')::int, (public.owner_dashboard() ->> 'fraud_alerts')::int,
               'riesgos: fraude tiene lo que dice el panel');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_risk_items('safety') -> 'items') i
                where i ->> 'source' = 'report' and (i ->> 'case_id') is not null
                  and i ->> 'person_id' = '00000000-0000-0000-0000-00000d9e0004'), 1,
               'riesgos: el reporte trae su caso para abrirlo');
select test.login('00000000-0000-0000-0000-00000d9e0002');
select test.eq((select count(*)::int from jsonb_array_elements(public.ops_risk_items('fraud') -> 'items') i
                where i ->> 'source' = 'ai'), 0, 'riesgos: el gerente no ve el Centro IA');

-- ---------------------------------------------------------------------------
-- Billeteras (solo propietario): suman lo del panel; los movimientos se filtran
-- ---------------------------------------------------------------------------
select test.login('00000000-0000-0000-0000-00000d9e0001');
select test.eq((public.owner_wallets() ->> 'available')::numeric, (public.owner_dashboard() ->> 'wallet_available')::numeric,
               'billeteras: el total disponible es el del panel');
select test.eq((public.owner_wallets() ->> 'reserved')::numeric, (public.owner_dashboard() ->> 'wallet_reserved')::numeric,
               'billeteras: el total reservado es el del panel');
select test.eq((public.owner_wallets('profesional detalle') -> 'items' -> 0 ->> 'professional_id')::uuid,
               '00000000-0000-0000-0000-00000d9e0004'::uuid, 'billeteras: busca por nombre');
select test.eq((select count(*)::int from public.owner_finance_transactions(null, null, 200,
                                                                           '00000000-0000-0000-0000-00000d9e0004')
                where professional_id <> '00000000-0000-0000-0000-00000d9e0004'), 0,
               'billeteras: los movimientos de una sola persona');
select test.expect_error($$select public.owner_wallets(null, 'otro')$$, 'HMY_INVALID_STATUS');
select test.logout();

-- Las funciones internas siguen cerradas.
select test.eq(has_function_privilege('authenticated', 'public.hmy_booking_row(public.bookings, boolean)', 'EXECUTE'),
               false, 'internas: hmy_booking_row no se llama desde la app');
select test.eq(has_function_privilege('authenticated', 'public.hmy_case_source(public.ops_cases)', 'EXECUTE'),
               false, 'internas: hmy_case_source sigue cerrada');
select test.eq(has_function_privilege('anon', 'public.ops_bookings(text, text, int)', 'EXECUTE'), false,
               'anon: no llega a los pedidos');
