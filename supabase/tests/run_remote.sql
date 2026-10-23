-- Corre las pruebas 10–80 contra el proyecto Supabase real SIN dejar rastro:
-- todo va dentro de una transacción que siempre termina en ROLLBACK.
-- Si una prueba falla, psql se detiene (ON_ERROR_STOP) y la transacción
-- abierta también se descarta. No usa 00_supabase_stub.sql (Supabase ya
-- trae auth y storage).
--
-- Uso: psql "$DB_URL" -X -f supabase/tests/run_remote.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if exists (select 1 from auth.users where email like '%@test.bo' or phone like '5916000080%') then
    raise exception 'HMY: ya existen usuarios de prueba (@test.bo o +59160000 80x); no se corrió nada.';
  end if;
end $$;
\ir 10_schema_tests.sql
\ir 20_ya_dispatch_tests.sql
\ir 30_location_photos_tests.sql
\ir 40_admin_safety_tests.sql
\ir 50_service_problems_tests.sql
\ir 60_wallet_confirmation_tests.sql
\ir 70_ai_control_center_tests.sql
\ir 80_phone_auth_tests.sql
\ir 90_arrival_pin_tests.sql
\ir 91_live_trip_tests.sql
\ir 92_operating_costs_tests.sql
\ir 93_identity_checks_tests.sql
\ir 94_rule_agents_tests.sql
\ir 95_identity_attach_tests.sql
\ir 96_bolivia_locations_tests.sql
\ir 97_customer_payment_choice_tests.sql
\ir 98_profile_photo_tests.sql
\ir 99_approval_id_tests.sql
\ir 99b_catalog_tests.sql
\ir 99c_optional_email_tests.sql
\ir 99d_management_roles_tests.sql
\ir 99e_truthful_agents_tests.sql
\ir 99f_owner_dashboard_tests.sql
\ir 99g_owner_finance_tests.sql
\ir 99h_team_directory_tests.sql
\ir 99i_ai_reports_es_tests.sql
\ir 99j_owner_drilldowns_tests.sql
\ir 99k_finance_drilldowns_tests.sql
\ir 99l_commission_lifecycle_tests.sql
\ir 99m_owner_demand_tests.sql
\ir 99n_push_notifications_tests.sql
\ir 99o_booking_deadlines_tests.sql
rollback;
\echo 'Pruebas terminadas; todo se deshizo (ROLLBACK).'
