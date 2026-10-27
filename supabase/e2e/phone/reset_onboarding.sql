-- Deja como nuevos los dos números de prueba de primer ingreso, para repetir
-- el registro del cliente (+591 7000 0004) y el del profesional (+591 7000 0005).
-- Solo esos dos: nunca toca las cuentas del dueño ni las de prueba por rol
-- (01 cliente, 02 profesional, 03 admin). Si la cuenta tiene pedidos o
-- movimientos que la base no deja borrar, no borra nada y lo dice.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/e2e/phone/reset_onboarding.sql
\set ON_ERROR_STOP 1
begin;
do $$
declare
  v_phone text;
  v_id uuid;
begin
  foreach v_phone in array array['59170000004', '59170000005'] loop
    select id into v_id from auth.users where phone = v_phone;
    if v_id is null then
      raise notice 'HMY: …%: sin cuenta, ya está como nuevo', right(v_phone, 2);
      continue;
    end if;
    -- Por si acaso: nunca una cuenta con rol de administración.
    if exists (select 1 from public.user_roles where user_id = v_id and role = 'admin') then
      raise exception 'HMY: …% tiene un rol de administración; no se borra', right(v_phone, 2);
    end if;
    delete from public.otp_sends where phone = '+' || v_phone;
    delete from public.otp_channel_choices where phone = '+' || v_phone;
    delete from auth.users where id = v_id;
    raise notice 'HMY: …%: cuenta borrada, el próximo ingreso es de primera vez', right(v_phone, 2);
  end loop;
  if exists (select 1 from auth.users where phone in ('59170000004', '59170000005')) then
    raise exception 'HMY: quedó una cuenta de primer ingreso';
  end if;
end $$;
commit;
