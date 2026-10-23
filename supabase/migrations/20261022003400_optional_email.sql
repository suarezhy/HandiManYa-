-- Correo opcional en Perfil > Información personal.
--
-- El correo es solo para recuperar la cuenta; se entra siempre con el
-- celular y un código. Supabase Auth guarda el correo nuevo en email_change
-- hasta que la persona escribe el código que le llegó: recién ahí pasa a
-- email y sirve para recuperar la cuenta (signInWithOtp no crea cuentas ni
-- usa correos sin confirmar).

-- my_account: igual que en 0013, más el correo pendiente de confirmar.
create or replace function public.my_account() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'email', u.email, 'email_confirmed', u.email_confirmed_at is not null,
    'email_pending', nullif(u.email_change, ''),
    'full_name', p.full_name, 'phone', p.phone, 'phone_verified', p.phone_verified_at is not null,
    'city_id', p.city_id, 'active_role', p.active_role,
    'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = p.id), '[]'::jsonb),
    'professional_status', coalesce((select status::text from public.professional_profiles where user_id = p.id), 'not_started'),
    'onboarding_completed', p.onboarding_completed_at is not null,
    'deletion_requested', p.deletion_requested_at is not null,
    'profile_complete', char_length(btrim(p.full_name)) >= 3 and p.city_id is not null and p.terms_accepted_at is not null
  )
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = auth.uid()
$$;

-- Quitar el correo de la propia cuenta (y cualquier cambio pendiente).
-- Solo con el celular confirmado: la cuenta nunca queda sin forma de entrar.
-- La auditoría guarda la acción, no el correo.
create function public.remove_my_email() returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'HMY_NOT_AUTHENTICATED'; end if;
  if not exists (select 1 from auth.users where id = v_uid and phone_confirmed_at is not null) then
    raise exception 'HMY_PHONE_REQUIRED';
  end if;
  update auth.users
  set email = null, email_confirmed_at = null, email_change = '', email_change_token_new = '',
      email_change_token_current = '', email_change_confirm_status = 0
  where id = v_uid;
  delete from auth.identities where user_id = v_uid and provider = 'email';
  perform public.audit('account.email_removed', 'auth.users', v_uid::text);
end $$;

revoke all on function public.remove_my_email() from public, anon;
grant execute on function public.remove_my_email() to authenticated;
