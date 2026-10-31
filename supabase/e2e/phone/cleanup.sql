-- Borra la cuenta del número de prueba y sus registros de envío. Corre siempre
-- al final, aunque la prueba falle. El número llega como variable de psql.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v phone="+5917xxxxxxx" -f supabase/e2e/phone/cleanup.sql
\set ON_ERROR_STOP 1
begin;
select set_config('hmy.e2e_phone', :'phone', true);
do $$
declare v_phone text := current_setting('hmy.e2e_phone');
begin
  if v_phone !~ '^\+591[67][0-9]{7}$' then raise exception 'HMY: número de prueba inválido'; end if;
  -- Nunca borrar las cuentas de prueba por rol que usa el dueño en sus teléfonos.
  if v_phone in ('+59170000001', '+59170000002', '+59170000003') then
    raise exception 'HMY: E2E_TEST_PHONE debe ser otro número, no uno de los de prueba por rol';
  end if;
  delete from public.otp_sends where phone in (v_phone, '+15555550123', '15555550123');
  delete from public.otp_channel_choices where phone = v_phone;
  delete from auth.users where phone = ltrim(v_phone, '+');
  if exists (select 1 from auth.users where phone = ltrim(v_phone, '+')) then
    raise exception 'HMY: quedó la cuenta del número de prueba';
  end if;
end $$;
commit;
