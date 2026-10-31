-- Un aviso de prueba para la cuenta de prueba …01 en DESARROLLO, por el mismo
-- camino que el botón "Enviar aviso de prueba" (send_test_push, con su límite de
-- uno por minuto). Sirve para probar con el teléfono ya bloqueado. Se niega si
-- hay un teléfono activo de otra cuenta. No muestra tokens.
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/e2e/push_test_delayed.sql
\set ON_ERROR_STOP 1
begin;
-- Sin la cuenta …01, \gset no recibe fila y psql se detiene.
select id as uid from auth.users where phone = '59170000001' \gset
do $$
begin
  if exists (select 1 from public.push_devices d join auth.users u on u.id = d.user_id
             where d.disabled_at is null and u.phone <> '59170000001') then
    raise exception 'Hay teléfonos activos de otras cuentas: no se manda nada';
  end if;
end $$;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'role', 'authenticated')::text, true) is not null as claims_ok \gset
select 'Aviso de prueba creado para …01 · teléfonos que lo reciben: ' || public.send_test_push();
commit;
