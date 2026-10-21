-- HandiMan ¡Ya! — 0019 enlazar sesiones de Didit sin duplicar ni borrar la de otro intento.
--
-- Didit devuelve la misma sesión abierta (Not Started, In Progress,
-- Resubmitted o Awaiting User) si se pide otra para el mismo vendor_data y la
-- misma versión del flujo. Antes eso chocaba con session_id único y el intento
-- fallaba. Ahora:
-- - Una sesión nueva se enlaza al intento.
-- - Una sesión que ya tenía otro intento abierto del mismo profesional (mismo
--   entorno) se reutiliza: se guarda el enlace nuevo en ese intento y se quita
--   el intento vacío recién creado.
-- - Una sesión de otro profesional, de otro entorno o ya cerrada nunca se acepta.
-- - Un enlace guardado que no es de Didit se descarta para no volver a entregarlo.

create function public.hmy_identity_attach(p_check bigint, p_session_id text, p_url text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.identity_checks;
  e public.identity_checks;
begin
  if p_session_id is null or length(p_session_id) > 80 or p_url is null or length(p_url) > 500
     or p_url !~ '^https://verify\.didit\.me/' then
    raise exception 'HMY_INVALID_SESSION';
  end if;
  select * into c from public.identity_checks where id = p_check for update;
  if not found or c.session_id is not null or c.status <> 'created' then
    return jsonb_build_object('saved', false, 'reason', 'check_not_open');
  end if;
  select * into e from public.identity_checks where session_id = p_session_id for update;
  if not found then
    update public.identity_checks set session_id = p_session_id, verification_url = p_url where id = c.id;
    return jsonb_build_object('saved', true, 'check', c.id, 'reused', false);
  end if;
  if e.professional_id = c.professional_id and e.sandbox = c.sandbox
     and e.status in ('created', 'in_progress', 'resubmitted') then
    update public.identity_checks set verification_url = p_url where id = e.id;
    delete from public.identity_checks where id = c.id;
    return jsonb_build_object('saved', true, 'check', e.id, 'reused', true);
  end if;
  return jsonb_build_object('saved', false, 'reason', 'session_conflict');
end $$;

-- ¿Se puede borrar esta sesión en Didit? Solo si ningún otro intento la usa.
create function public.hmy_identity_session_free(p_check bigint, p_session_id text)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_session_id is not null and not exists (
    select 1 from public.identity_checks where session_id = p_session_id and id is distinct from p_check)
$$;

-- Enlace guardado que no pasó la revisión: se borra para que no se vuelva a entregar.
create function public.hmy_identity_forget_link(p_check bigint)
returns void
language sql security definer set search_path = public as $$
  update public.identity_checks set verification_url = null
  where id = p_check and status in ('created', 'in_progress', 'resubmitted')
$$;

revoke execute on function public.hmy_identity_attach(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.hmy_identity_session_free(bigint, text) from public, anon, authenticated;
revoke execute on function public.hmy_identity_forget_link(bigint) from public, anon, authenticated;
grant execute on function public.hmy_identity_attach(bigint, text, text), public.hmy_identity_session_free(bigint, text),
  public.hmy_identity_forget_link(bigint) to service_role;
