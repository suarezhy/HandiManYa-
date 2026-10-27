-- Prepara las cuentas temporales de la prueba de punta a punta (E2E) en el
-- proyecto de desarrollo. La app real las usa por la API de Supabase, como
-- lo haría un teléfono: cliente, profesional, propietario (admin), gerente y
-- dos empleados.
--
-- Solo crea lo que la app no puede crear sola: las cuentas con contraseña
-- (así no se gastan códigos por WhatsApp o SMS), el rol de admin y la fila
-- del carnet del profesional (sin archivo; subir documentos se prueba aparte).
-- Todo lo demás (postular, aprobar, pedir, cotizar, pagar, calificar) lo hace
-- la prueba por la API. cleanup.sql borra todo al terminar.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v pw="$E2E_PASSWORD" -f supabase/e2e/setup.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if exists (select 1 from auth.users where email like 'e2e-%@test.bo') then
    raise exception 'HMY: ya hay cuentas E2E de una corrida anterior; corre cleanup.sql primero.';
  end if;
end $$;

create temp table e2e_users (id uuid, email text, phone text, name text, admin boolean) on commit drop;
insert into e2e_users values
  ('e2e00000-0000-4000-8000-0000000000c1', 'e2e-cliente@test.bo', '59160000901', 'Cliente Prueba E2E', false),
  ('e2e00000-0000-4000-8000-0000000000b1', 'e2e-pro@test.bo', '59160000902', 'Profesional Prueba E2E', false),
  ('e2e00000-0000-4000-8000-00000000000a', 'e2e-admin@test.bo', '59160000903', 'Equipo Prueba E2E', true),
  -- Gerente y empleados de prueba: entran sin rol; el propietario de prueba
  -- se lo da por la API (owner_grant_staff), como en la app.
  ('e2e00000-0000-4000-8000-0000000000e0', 'e2e-gerente@test.bo', '59160000904', 'Gerente Prueba E2E', false),
  ('e2e00000-0000-4000-8000-0000000000e1', 'e2e-empleado1@test.bo', '59160000905', 'Empleado Uno E2E', false),
  ('e2e00000-0000-4000-8000-0000000000e2', 'e2e-empleado2@test.bo', '59160000906', 'Empleado Dos E2E', false);

-- Como una cuenta creada por Supabase Auth con correo confirmado. Las columnas
-- de tokens van vacías (no nulas) porque Auth las lee como texto.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        confirmation_token, recovery_token, email_change_token_new, email_change,
                        created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
       extensions.crypt(:'pw', extensions.gen_salt('bf')), now(), phone, now(),
       '{"provider":"email","providers":["email","phone"]}'::jsonb,
       jsonb_build_object('full_name', name),
       '', '', '', '', now(), now()
  from e2e_users;

insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), id::text, id,
       jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
       'email', now(), now(), now()
  from e2e_users;

insert into public.user_roles (user_id, role) select id, 'admin' from e2e_users where admin;

-- El carnet del profesional, frente y reverso, y los documentos de Mecánica y Grúa
-- (solo las filas; la revisión la hace el admin por la API).
select set_config('request.jwt.claims',
  '{"sub":"e2e00000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
select public.start_professional_application();
insert into public.professional_documents (professional_id, doc_type, storage_path)
values ('e2e00000-0000-4000-8000-0000000000b1', 'ci_anverso', 'e2e00000-0000-4000-8000-0000000000b1/e2e-ci.jpg'),
       ('e2e00000-0000-4000-8000-0000000000b1', 'ci_reverso', 'e2e00000-0000-4000-8000-0000000000b1/e2e-ci-r.jpg'),
       -- Para Mecánica y Grúa (el equipo los acepta recién en la última prueba).
       ('e2e00000-0000-4000-8000-0000000000b1', 'antecedentes', 'e2e00000-0000-4000-8000-0000000000b1/e2e-ant.jpg'),
       ('e2e00000-0000-4000-8000-0000000000b1', 'documentos_grua', 'e2e00000-0000-4000-8000-0000000000b1/e2e-grua.jpg');
select set_config('request.jwt.claims', '', true);

-- Un método de recarga temporal: dev no tiene ninguno configurado y sin
-- recarga no se pueden probar la billetera ni la conciliación. cleanup.sql lo borra.
insert into public.topup_methods (name, instructions, sort_order)
select 'Prueba E2E (temporal)', 'Solo para la prueba automática; se borra al terminar.', 999
 where not exists (select 1 from public.topup_methods where name = 'Prueba E2E (temporal)');

commit;
\echo 'Cuentas E2E listas.'
