-- Correo opcional (0034). Corre después de 99b.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, phone, phone_confirmed_at, email_confirmed_at, email_change, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000099f1', 'correo-ok@test.bo', '59170099901', now(), now(), '', '{"full_name": "Con Correo"}'),
  ('00000000-0000-0000-0000-0000000099f2', null, '59170099902', now(), null, 'nuevo@test.bo', '{"full_name": "Con Pendiente"}'),
  ('00000000-0000-0000-0000-0000000099f3', 'solo-correo@test.bo', null, null, now(), '', '{"full_name": "Sin Celular"}');

-- El correo pendiente se ve como pendiente, no como correo de la cuenta.
select test.login('00000000-0000-0000-0000-0000000099f2');
select test.eq((public.my_account() ->> 'email_pending'), 'nuevo@test.bo', 'correo: el pendiente se muestra como pendiente');
select test.eq((public.my_account() ->> 'email'), null::text, 'correo: sin confirmar no es el correo de la cuenta');
select public.remove_my_email();
select test.eq((public.my_account() ->> 'email_pending'), null::text, 'correo: quitar también cancela el pendiente');

-- Quitar el correo confirmado: la cuenta sigue con su celular.
select test.login('00000000-0000-0000-0000-0000000099f1');
select test.eq((public.my_account() ->> 'email_confirmed')::boolean, true, 'correo: confirmado antes de quitarlo');
select public.remove_my_email();
select test.eq((public.my_account() ->> 'email'), null::text, 'correo: quitado');
select test.eq((public.my_account() ->> 'phone') is not null, true, 'correo: el celular no cambia');
select test.logout();
select test.eq((select count(*)::int from public.admin_audit_log
                 where action = 'account.email_removed' and target_id = '00000000-0000-0000-0000-0000000099f1'
                   and details = '{}'::jsonb), 1, 'correo: la auditoría registra la acción, sin el correo');

-- Una cuenta sin celular confirmado no puede quedarse sin forma de entrar.
select test.login('00000000-0000-0000-0000-0000000099f3');
select test.expect_error('select public.remove_my_email()', 'HMY_PHONE_REQUIRED');
select test.logout();
select test.eq((select email from auth.users where id = '00000000-0000-0000-0000-0000000099f3'), 'solo-correo@test.bo',
               'correo: sin celular, el correo se queda');

-- Sin sesión, nada.
select test.login(null);
select test.expect_error('select public.remove_my_email()', 'permission denied');
select test.logout();

\o
\echo '99c correo opcional: ok'
