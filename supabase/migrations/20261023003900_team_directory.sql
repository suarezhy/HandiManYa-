-- HandiMan ¡Ya! — 0039 Equipo: buscar cuentas, dar roles con confirmación.
--
-- - Buscar por nombre o celular. El celular se compara solo por sus dígitos
--   (con o sin +591, espacios o guiones) y se muestra enmascarado.
-- - Cada resultado dice si se le puede dar un rol y, si no, por qué (ya es del
--   equipo, es el Propietario, está suspendida, no confirmó su celular).
-- - Dar un rol o reactivar a alguien exige un código nuevo (o la contraseña)
--   del Propietario. El rol se da por el id de la cuenta, nunca por un número.
-- - Suspender o quitar el acceso no pide código: es la acción de seguridad y
--   tiene que ser rápida. Todo queda en la auditoría.

-- "+591 7••• ••05"
create function public.hmy_mask_phone(p_phone text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_phone is null or char_length(regexp_replace(p_phone, '\D', '', 'g')) < 6 then null
    when regexp_replace(p_phone, '\D', '', 'g') like '591%' and char_length(regexp_replace(p_phone, '\D', '', 'g')) = 11
      then '+591 ' || substr(regexp_replace(p_phone, '\D', '', 'g'), 4, 1) || '••• ••'
           || right(regexp_replace(p_phone, '\D', '', 'g'), 2)
    else '••• ' || right(regexp_replace(p_phone, '\D', '', 'g'), 2) end
$$;

-- Cuentas para el equipo. Solo el Propietario.
create function public.owner_staff_candidates(p_query text)
returns table (id uuid, full_name text, phone_masked text, city_name text, staff_role text, staff_status text,
               eligible boolean, reason text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_text text := public.hmy_norm(coalesce(btrim(p_query), ''));
  v_digits text := regexp_replace(coalesce(p_query, ''), '\D', '', 'g');
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if char_length(btrim(coalesce(p_query, ''))) < 2 then return; end if;
  -- 8 dígitos de un celular boliviano: también con el 591 adelante.
  if char_length(v_digits) = 8 then v_digits := '591' || v_digits; end if;
  return query
  select p.id, p.full_name, public.hmy_mask_phone(coalesce(u.phone, p.phone)), c.name, s.role, s.status,
         r.reason is null, r.reason
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.cities c on c.id = p.city_id
  left join public.staff_members s on s.user_id = p.id
  cross join lateral (select case
      when p.id = auth.uid() then 'self'
      when public.has_role('admin', p.id) then 'owner'
      when p.suspended_at is not null then 'suspended'
      when u.phone_confirmed_at is null then 'phone_unconfirmed'
      when s.status = 'active' then 'already_staff'
    end as reason) r
  where (char_length(v_text) >= 2 and public.hmy_norm(p.full_name) like '%' || v_text || '%')
     or (char_length(v_digits) >= 4
         and regexp_replace(coalesce(u.phone, p.phone, ''), '\D', '', 'g') like '%' || v_digits || '%')
  order by (r.reason is null) desc, p.full_name
  limit 20;
end $$;

-- Dar un rol: con confirmación fuerte del Propietario.
drop function public.owner_grant_staff(uuid, text);
create function public.owner_grant_staff(p_user uuid, p_role text, p_auth_method text) returns void
language plpgsql security definer set search_path = public as $$
declare v_old public.staff_members;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_role not in ('manager', 'employee') then raise exception 'HMY_INVALID_ROLE'; end if;
  if p_user is null or p_user = auth.uid() or public.has_role('admin', p_user) then
    raise exception 'HMY_FORBIDDEN';
  end if;
  if not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                 where u.id = p_user and u.phone_confirmed_at is not null and p.suspended_at is null) then
    raise exception 'HMY_STAFF_ACCOUNT_REQUIRED';
  end if;
  select * into v_old from public.staff_members where user_id = p_user;
  if v_old.status = 'active' and v_old.role = p_role then raise exception 'HMY_ALREADY_STAFF'; end if;
  perform public.hmy_require_strong_confirmation(p_auth_method, 'staff.grant');
  insert into public.staff_members (user_id, role, status, granted_by)
  values (p_user, p_role, 'active', auth.uid())
  on conflict (user_id) do update
    set role = excluded.role, status = 'active', status_reason = null, granted_by = auth.uid(), updated_at = now();
  perform public.audit('staff.grant', 'staff_members', p_user::text,
                       jsonb_strip_nulls(jsonb_build_object('role', p_role, 'previous_role', v_old.role,
                                                            'previous_status', v_old.status,
                                                            'auth_method', p_auth_method)));
end $$;

-- Suspender, quitar o reactivar. Reactivar devuelve acceso: pide confirmación.
drop function public.owner_set_staff_status(uuid, text, text);
create function public.owner_set_staff_status(p_user uuid, p_status text, p_reason text default null,
                                              p_auth_method text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_released int := 0;
  v_old public.staff_members;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('active', 'suspended', 'revoked') then raise exception 'HMY_INVALID_STATUS'; end if;
  if p_status <> 'active' and coalesce(btrim(p_reason), '') = '' then raise exception 'HMY_REASON_REQUIRED'; end if;
  select * into v_old from public.staff_members where user_id = p_user for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if p_status = 'active' then
    if exists (select 1 from public.profiles where id = p_user and suspended_at is not null) then
      raise exception 'HMY_STAFF_ACCOUNT_REQUIRED';
    end if;
    perform public.hmy_require_strong_confirmation(p_auth_method, 'staff.reactivate');
  end if;
  update public.staff_members set status = p_status, status_reason = nullif(btrim(p_reason), ''), updated_at = now()
  where user_id = p_user;
  if p_status <> 'active' then
    update public.ops_cases set assigned_to = null, assigned_by = auth.uid(), assigned_at = now(), updated_at = now()
    where assigned_to = p_user and status <> 'resolved';
    get diagnostics v_released = row_count;
  end if;
  perform public.audit('staff.' || p_status, 'staff_members', p_user::text,
                       jsonb_strip_nulls(jsonb_build_object('reason', nullif(btrim(p_reason), ''),
                                                            'previous_status', v_old.status,
                                                            'released_cases', nullif(v_released, 0),
                                                            'auth_method', p_auth_method)));
end $$;

-- Directorio del equipo: igual que antes, más el celular enmascarado.
create or replace function public.ops_staff_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hmy_can('staff.view') then raise exception 'HMY_FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', s.user_id, 'full_name', p.full_name, 'role', s.role, 'status', s.status,
      'status_reason', s.status_reason, 'granted_at', s.granted_at,
      'phone_masked', public.hmy_mask_phone(coalesce(u.phone, p.phone)),
      'open_cases', (select count(*) from public.ops_cases c where c.assigned_to = s.user_id and c.status <> 'resolved'),
      'resolved_7d', (select count(*) from public.ops_cases c where c.assigned_to = s.user_id and c.status = 'resolved'
                        and c.resolved_at > now() - interval '7 days'),
      'avg_first_response_min', (select round(avg(extract(epoch from (c.first_response_at
                                                   - coalesce(c.assigned_at, c.created_at))) / 60))
                                 from public.ops_cases c where c.assigned_to = s.user_id
                                   and c.first_response_at is not null
                                   and c.created_at > now() - interval '30 days'))
      order by s.status, s.role, p.full_name)
    from public.staff_members s join public.profiles p on p.id = s.user_id
    left join auth.users u on u.id = s.user_id), '[]'::jsonb);
end $$;

revoke execute on function public.hmy_mask_phone(text) from public, anon, authenticated;
revoke execute on function public.owner_staff_candidates(text) from public, anon;
revoke execute on function public.owner_grant_staff(uuid, text, text) from public, anon;
revoke execute on function public.owner_set_staff_status(uuid, text, text, text) from public, anon;
grant execute on function public.owner_staff_candidates(text), public.owner_grant_staff(uuid, text, text),
  public.owner_set_staff_status(uuid, text, text, text) to authenticated;
