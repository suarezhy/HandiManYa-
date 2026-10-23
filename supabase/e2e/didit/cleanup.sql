-- Borra la cuenta temporal de la prueba del sandbox de Didit y lo que creó
-- (su postulación y sus verificaciones de prueba se borran en cascada).
-- Los registros de uso del sandbox (cost_usage, USD 0) quedan: son el historial
-- real de lo que se usó. Corre siempre al final, aunque la prueba falle.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/e2e/didit/cleanup.sql
\set ON_ERROR_STOP 1
begin;
delete from public.notifications where user_id = 'd1d17000-0000-4000-8000-0000000000b1';
delete from public.verification_events where professional_id = 'd1d17000-0000-4000-8000-0000000000b1';
delete from public.admin_audit_log where actor_id = 'd1d17000-0000-4000-8000-0000000000b1';
delete from auth.users where id = 'd1d17000-0000-4000-8000-0000000000b1';
do $$ begin
  if exists (select 1 from auth.users where email = 'didit-pro@test.bo') then
    raise exception 'HMY: quedó la cuenta de prueba de Didit';
  end if;
  if exists (select 1 from public.identity_checks where professional_id = 'd1d17000-0000-4000-8000-0000000000b1') then
    raise exception 'HMY: quedaron verificaciones de prueba';
  end if;
end $$;
commit;
