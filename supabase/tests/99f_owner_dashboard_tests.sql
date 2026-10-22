-- Panel del Propietario (0037). Corre después de 99d.
-- Cuentas de prueba propias (…99f0…); ninguna cuenta real recibe un rol.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000099f0001', '59170099301', now(), '{"full_name": "Dueño Panel"}'),
  ('00000000-0000-0000-0000-0000099f0002', '59170099302', now(), '{"full_name": "Gerente Panel"}'),
  ('00000000-0000-0000-0000-0000099f0003', '59170099303', now(), '{"full_name": "Empleado Panel"}'),
  ('00000000-0000-0000-0000-0000099f0004', '59170099304', now(), '{"full_name": "Cliente Panel"}'),
  ('00000000-0000-0000-0000-0000099f0005', '59170099305', now(), '{"full_name": "Otra Persona"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000099f0001', 'admin');

select test.login('00000000-0000-0000-0000-0000099f0001');
select public.owner_grant_staff('00000000-0000-0000-0000-0000099f0002', 'manager');
select public.owner_grant_staff('00000000-0000-0000-0000-0000099f0003', 'employee');

-- Solo el propietario lo abre.
select test.login('00000000-0000-0000-0000-0000099f0002');
select test.expect_error('select public.owner_dashboard()', 'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-0000099f0003');
select test.expect_error('select public.owner_dashboard()', 'HMY_FORBIDDEN');
select test.login('00000000-0000-0000-0000-0000099f0004');
select test.expect_error('select public.owner_dashboard()', 'HMY_FORBIDDEN');
select test.logout();
select test.expect_error('select public.owner_dashboard()', 'HMY_FORBIDDEN');

-- Tiene todas las secciones del panel.
select test.login('00000000-0000-0000-0000-0000099f0001');
select test.eq((select count(*)::int from jsonb_object_keys(public.owner_dashboard()) k
                where k in ('bookings_today', 'active_bookings', 'completed_today', 'cancelled_today', 'customers',
                            'approved_professionals', 'available_professionals', 'pending_applications',
                            'pending_documents', 'identity_in_review', 'revenue_month', 'commission_month',
                            'wallet_available', 'wallet_reserved', 'pending_topups', 'open_disputes',
                            'safety_incidents', 'fraud_alerts', 'urgent_cases', 'demand_municipality',
                            'demand_department', 'demand_category', 'coverage_gaps', 'ai_pending',
                            'costs_month_usd', 'unread_notifications', 'audit_24h', 'active_commission_rules')),
               28, 'propietario: el panel trae todas sus secciones');

-- Los números salen de la base, no se inventan.
select test.logout();
create temp table expected as select
  (select count(*)::int from public.profiles) as users,
  (select count(*)::int from public.professional_profiles where status in ('submitted', 'under_review')) as pending,
  (select count(*)::int from public.professional_profiles where status = 'approved') as approved,
  (select count(*)::int from public.bookings where status not in ('draft', 'completed', 'cancelled')) as active,
  (select coalesce(sum(available), 0) from public.wallets) as available,
  (select count(*)::int from public.topup_requests where status = 'pending') as topups,
  (select count(*)::int from public.disputes where status = 'open') as disputes,
  (select count(*)::int from public.staff_members where role = 'employee' and status = 'active') as employees;
grant select on expected to authenticated;
select test.login('00000000-0000-0000-0000-0000099f0001');
select test.eq((public.owner_dashboard() ->> 'users')::int, (select users from expected), 'propietario: usuarios reales');
select test.eq((public.owner_dashboard() ->> 'pending_applications')::int, (select pending from expected),
               'propietario: postulaciones pendientes reales');
select test.eq((public.owner_dashboard() ->> 'approved_professionals')::int, (select approved from expected),
               'propietario: profesionales aprobados reales');
select test.eq((public.owner_dashboard() ->> 'active_bookings')::int, (select active from expected),
               'propietario: pedidos activos reales');
select test.eq((public.owner_dashboard() ->> 'wallet_available')::numeric, (select available from expected),
               'propietario: saldos reales');
select test.eq((public.owner_dashboard() ->> 'pending_topups')::int, (select topups from expected),
               'propietario: recargas pendientes reales');
select test.eq((public.owner_dashboard() ->> 'open_disputes')::int, (select disputes from expected),
               'propietario: disputas abiertas reales');
select test.eq((public.owner_dashboard() ->> 'active_employees')::int, (select employees from expected),
               'propietario: empleados activos reales');

-- Un reporte de acoso suma un incidente de seguridad (una sola vez, aunque
-- también abra un caso) y uno de fraude suma una alerta de fraude.
create temp table before_counts as
  select (public.owner_dashboard() ->> 'safety_incidents')::int as safety,
         (public.owner_dashboard() ->> 'fraud_alerts')::int as fraud;
select test.login('00000000-0000-0000-0000-0000099f0004');
select public.report_user('00000000-0000-0000-0000-0000099f0005', 'acoso');
select public.report_user('00000000-0000-0000-0000-0000099f0005', 'fraude');
select test.login('00000000-0000-0000-0000-0000099f0001');
select test.eq((public.owner_dashboard() ->> 'safety_incidents')::int, (select safety + 1 from before_counts),
               'propietario: el acoso cuenta como incidente de seguridad, una vez');
select test.eq((public.owner_dashboard() ->> 'fraud_alerts')::int, (select fraud + 1 from before_counts),
               'propietario: el fraude cuenta como alerta de fraude, una vez');
select test.eq((public.owner_dashboard() ->> 'urgent_cases')::int >= 0, true, 'propietario: casos urgentes');

-- Las listas de demanda son listas, aunque estén vacías.
select test.eq(jsonb_typeof(public.owner_dashboard() -> 'demand_municipality'), 'array', 'propietario: demanda por municipio');
select test.eq(jsonb_typeof(public.owner_dashboard() -> 'coverage_gaps'), 'array', 'propietario: brechas de cobertura');
select test.logout();

drop table expected;
drop table before_counts;
\o
\echo 'PRUEBAS DEL PANEL DEL PROPIETARIO PASARON'
