-- 0044: cada fila de "Demanda de los últimos 30 días" abre sus pedidos
-- (Build 14). Solo lectura, con la misma definición que owner_dashboard():
-- pedidos de los últimos 30 días que no son borradores, por municipio (con
-- su departamento), departamento o categoría. Solo el propietario (las
-- filas de demanda están en su panel); el dinero lo ve solo él.
create function public.owner_demand_bookings(p_kind text, p_name text, p_department text default null,
                                             p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_30d timestamptz := now() - interval '30 days';
  v_items jsonb;
  v_total int;
  v_pros int;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_kind not in ('municipio', 'departamento', 'categoria') then raise exception 'HMY_INVALID_STATUS'; end if;
  with m as (
    select b.* from public.bookings b
    left join public.cities c on c.id = b.city_id
    left join public.departments d on d.id = c.department_id
    left join public.service_categories sc on sc.id = b.category_id
    where b.created_at >= v_30d and b.status <> 'draft'
      and case p_kind
            when 'municipio' then c.name = p_name and (p_department is null or d.name = p_department)
            when 'departamento' then d.name = p_name
            else sc.name = p_name end
  )
  select (select count(*)::int from m),
         coalesce((select jsonb_agg(public.hmy_booking_row(x, true) order by x.created_at desc)
                   from (select * from m order by created_at desc
                         limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb)
  into v_total, v_items;
  -- Profesionales aprobados con base allí (lo que mide "Sin cobertura").
  if p_kind = 'municipio' then
    select count(*)::int into v_pros from public.professional_profiles pp
    join public.cities c on c.id = pp.city_id
    left join public.departments d on d.id = c.department_id
    where pp.status = 'approved' and c.name = p_name and (p_department is null or d.name = p_department);
  end if;
  return jsonb_build_object('items', v_items, 'total', v_total, 'professionals', v_pros, 'money', true);
end $$;

revoke execute on function public.owner_demand_bookings(text, text, text, int) from public, anon;
grant execute on function public.owner_demand_bookings(text, text, text, int) to authenticated;
