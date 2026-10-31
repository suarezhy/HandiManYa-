-- Da el rol de administrador a UNA cuenta de prueba del proyecto de
-- DESARROLLO, identificada por su id exacto (no por el número). Lo corre el
-- flujo roles-dev, que el dueño aprueba. La app nunca puede dar roles:
-- user_roles no acepta escrituras de anon ni authenticated.
--
-- Antes de dar el rol comprueba que ese id es la cuenta de +591 7000 0003,
-- que su teléfono está confirmado y que ya entró con su código al menos una
-- vez. No toca 01 ni 02: el profesional se aprueba por el proceso normal.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v user_id="<uuid>" -f supabase/e2e/phone/grant_test_admin.sql
\set ON_ERROR_STOP 1
begin;
select set_config('hmy.admin_user', :'user_id', true);
do $$
declare
  v_id uuid := current_setting('hmy.admin_user')::uuid;
  u auth.users;
begin
  select * into u from auth.users where id = v_id;
  if not found then raise exception 'HMY: no existe una cuenta con ese id'; end if;
  if u.phone is distinct from '59170000003' then raise exception 'HMY: ese id no es la cuenta de prueba de administrador (03)'; end if;
  if u.phone_confirmed_at is null or u.last_sign_in_at is null then
    raise exception 'HMY: la cuenta 03 todavía no entró con su código; entra una vez en la app y vuelve a correr';
  end if;
  if u.banned_until is not null and u.banned_until > now() then raise exception 'HMY: la cuenta está bloqueada'; end if;
  insert into public.user_roles (user_id, role) values (v_id, 'admin') on conflict do nothing;
  insert into public.admin_audit_log (actor_id, action, target_table, target_id, details)
  values (null, 'role.admin_granted', 'user_roles', v_id::text,
          jsonb_build_object('source', 'roles-dev', 'note', 'cuenta de prueba de administrador (desarrollo)'));
end $$;
do $$ begin
  if exists (select 1 from public.user_roles r join auth.users u on u.id = r.user_id
             where r.role = 'admin' and u.phone in ('59170000001', '59170000002', '59170000009')) then
    raise exception 'HMY: otra cuenta de prueba tiene rol de administrador';
  end if;
end $$;
commit;
