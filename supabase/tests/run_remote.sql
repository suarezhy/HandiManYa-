-- Corre las pruebas 10–60 contra el proyecto Supabase real SIN dejar rastro:
-- todo va dentro de una transacción que siempre termina en ROLLBACK.
-- Si una prueba falla, psql se detiene (ON_ERROR_STOP) y la transacción
-- abierta también se descarta. No usa 00_supabase_stub.sql (Supabase ya
-- trae auth y storage).
--
-- Uso: psql "$DB_URL" -X -f supabase/tests/run_remote.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if exists (select 1 from auth.users where email like '%@test.bo') then
    raise exception 'HMY: ya existen usuarios de prueba (@test.bo); no se corrió nada.';
  end if;
end $$;
\ir 10_schema_tests.sql
\ir 20_ya_dispatch_tests.sql
\ir 30_location_photos_tests.sql
\ir 40_admin_safety_tests.sql
\ir 50_service_problems_tests.sql
\ir 60_wallet_confirmation_tests.sql
rollback;
\echo 'Pruebas terminadas; todo se deshizo (ROLLBACK).'
