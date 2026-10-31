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
-- Los profesionales que ya están en la base (en dev, la cuenta de prueba …02
-- aprobada) no deben aparecer en las búsquedas ni recibir pedidos de las
-- pruebas: dentro de esta transacción, que se deshace, quedan en borrador y
-- no disponibles. Sin disparadores, para no crear avisos ni historial.
set session_replication_role = replica;
update public.professional_profiles set status = 'draft', is_available = false
where user_id::text not like '00000000-%';
set session_replication_role = origin;
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
\ir 99p_inactive_professional_tests.sql
\ir 99q_home_map_tests.sql
\ir 99r_catalog_grua_banda_tests.sql
\ir 99s_catalog_mariachis_tests.sql
\ir 99t_home_ads_tests.sql
\ir 99u_grua_single_entry_tests.sql
\ir 99v_table_privileges_tests.sql
\ir 99w_lookup_indexes_tests.sql
\ir 99x_open_scheduled_requests_tests.sql
\ir 99y_cancel_without_reason_tests.sql
\ir 99z_ya_dispatch_safety_tests.sql
\ir 99z1_ya_claim_order_tests.sql
\ir 99z2_ya_retry_validates_tests.sql
\ir 99z3_claim_lock_review_once_tests.sql
\ir 99z4_dev_test_fixture_tests.sql
\ir 99z5_price_agreement_tests.sql
\ir 99z6_agreed_commission_tests.sql
\ir 99z7_rank_identity_tests.sql
\ir 99z8_commission_settlement_tests.sql
\ir 99z9_job_cards_tests.sql
\ir 99za_qr_recharges_tests.sql
\ir 99zb_commission_on_payment_tests.sql
\ir 99zc_counteroffer_cancel_penalty_tests.sql
rollback;
\echo 'Pruebas terminadas; todo se deshizo (ROLLBACK).'
