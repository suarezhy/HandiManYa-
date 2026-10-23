-- Prepara la prueba del sandbox de Didit en el proyecto de desarrollo: una
-- cuenta temporal de profesional con su postulación en borrador. No crea
-- documentos ni carnets: en el sandbox no se usa ningún carnet real.
-- cleanup.sql la borra al terminar.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v pw="$E2E_PASSWORD" -f supabase/e2e/didit/setup.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if exists (select 1 from auth.users where email = 'didit-pro@test.bo') then
    raise exception 'HMY: ya hay una cuenta de una corrida anterior; corre cleanup.sql primero.';
  end if;
end $$;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data,
                        confirmation_token, recovery_token, email_change_token_new, email_change,
                        created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', 'd1d17000-0000-4000-8000-0000000000b1', 'authenticated',
        'authenticated', 'didit-pro@test.bo', extensions.crypt(:'pw', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Profesional Prueba Didit"}'::jsonb,
        '', '', '', '', now(), now());

insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values (gen_random_uuid(), 'd1d17000-0000-4000-8000-0000000000b1', 'd1d17000-0000-4000-8000-0000000000b1',
        '{"sub":"d1d17000-0000-4000-8000-0000000000b1","email":"didit-pro@test.bo","email_verified":true}'::jsonb,
        'email', now(), now(), now());

select set_config('request.jwt.claims',
  '{"sub":"d1d17000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
select public.start_professional_application();
select set_config('request.jwt.claims', '', true);

commit;
\echo 'Cuenta de prueba de Didit lista.'
