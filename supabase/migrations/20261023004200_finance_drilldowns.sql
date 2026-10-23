-- 0042: cada tarjeta de Finanzas y Bancos abre su lista (Build 14).
--
-- Dos funciones de solo lectura, solo para el Propietario (is_admin), con las
-- MISMAS definiciones que owner_finance_summary (0038), para que el total de
-- la lista sea el número de la tarjeta:
--   owner_finance_ledger: movimientos del libro de billeteras por tipo y mes
--     (comisiones cobradas, devoluciones, ajustes, recargas), con el pedido;
--   owner_finance_topups: recargas por estado (acreditadas, conciliadas, sin
--     verificar, no encontradas, por revisar) y mes de acreditación.
-- Devuelven {"items", "total", "sum_bs", "month"}: total y sum_bs cuentan todo,
-- aunque la lista traiga solo las primeras filas. Nada se escribe.

-- ---------------------------------------------------------------------------
-- Libro de billeteras, filtrado
-- ---------------------------------------------------------------------------
create function public.owner_finance_ledger(p_kind text default null, p_month date default null,
                                            p_query text default '', p_professional uuid default null,
                                            p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz constant text := 'America/La_Paz';
  v_month date := case when p_month is null then null else date_trunc('month', p_month)::date end;
  v_from timestamptz := v_month::timestamp at time zone v_tz;
  v_to timestamptz := (v_month + interval '1 month')::timestamp at time zone v_tz;
  v_q text := public.hmy_norm(btrim(coalesce(p_query, '')));
  v_items jsonb;
  v_total int;
  v_sum numeric;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_kind is not null and p_kind not in ('topup', 'commission_capture', 'adjustment', 'refund',
                                           'commission_reserve', 'commission_release') then
    raise exception 'HMY_INVALID_STATUS';
  end if;

  with r as (
  select l.id,
         -- Lo mismo que suma el resumen: la comisión cobrada en positivo; el
         -- resto, lo que cambió el saldo disponible del profesional.
         case when l.entry_type = 'commission_capture' then -(l.available_delta + l.reserved_delta)
              else l.available_delta end as amount,
         jsonb_build_object(
           'id', l.id, 'professional_id', l.professional_id,
           'professional_name', coalesce(pp.display_name, p.full_name),
           'entry_type', l.entry_type, 'available_delta', l.available_delta, 'reserved_delta', l.reserved_delta,
           'booking_id', b.id, 'booking_code', b.code, 'booking_status', b.status,
           'category_name', c.name, 'booking_final_amount', b.final_amount,
           'topup_id', l.topup_id, 'topup_bank_status', t.bank_status,
           'reference', coalesce(t.bank_reference, t.reference), 'note', l.note, 'created_at', l.created_at) as row
  from public.wallet_ledger l
  left join public.professional_profiles pp on pp.user_id = l.professional_id
  left join public.profiles p on p.id = l.professional_id
  left join public.bookings b on b.id = l.booking_id
  left join public.service_categories c on c.id = b.category_id
  left join public.topup_requests t on t.id = l.topup_id
  where (p_kind is null or l.entry_type::text = p_kind)
    and (v_month is null or (l.created_at >= v_from and l.created_at < v_to))
    and (p_professional is null or l.professional_id = p_professional)
    and (v_q = '' or public.hmy_norm(concat_ws(' ', pp.display_name, p.full_name, b.code, t.reference,
                                               t.bank_reference, l.note)) like '%' || v_q || '%'))
  select count(*), coalesce(sum(r.amount), 0),
         coalesce((select jsonb_agg(x.row order by x.id desc)
                   from (select r2.row, r2.id from r r2 order by r2.id desc
                         limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb)
  into v_total, v_sum, v_items
  from r;
  return jsonb_build_object('items', v_items, 'total', v_total, 'sum_bs', v_sum,
                            'month', to_char(v_month, 'YYYY-MM'), 'timezone', v_tz);
end $$;

-- ---------------------------------------------------------------------------
-- Recargas, filtradas por estado y mes de acreditación
-- ---------------------------------------------------------------------------
create function public.owner_finance_topups(p_status text default 'sin_verificar', p_month date default null,
                                            p_query text default '', p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz constant text := 'America/La_Paz';
  v_month date := case when p_month is null then null else date_trunc('month', p_month)::date end;
  v_from timestamptz := v_month::timestamp at time zone v_tz;
  v_to timestamptz := (v_month + interval '1 month')::timestamp at time zone v_tz;
  v_q text := public.hmy_norm(btrim(coalesce(p_query, '')));
  v_items jsonb;
  v_total int;
  v_sum numeric;
begin
  if not public.is_admin() then raise exception 'HMY_FORBIDDEN'; end if;
  if p_status not in ('acreditadas', 'sin_verificar', 'conciliada', 'no_encontrada', 'pendiente', 'todas') then
    raise exception 'HMY_INVALID_STATUS';
  end if;

  with r as (
  select t.id, t.amount,
         jsonb_build_object(
           'id', t.id, 'professional_id', t.professional_id, 'professional_name', pp.display_name,
           'amount', t.amount, 'method_name', m.name, 'reference', t.reference,
           'has_proof', t.proof_path is not null, 'status', t.status, 'bank_status', t.bank_status,
           'bank_reference', t.bank_reference, 'bank_account_id', t.bank_account_id,
           'bank_account_label', a.label, 'bank_checked_at', t.bank_checked_at,
           'reviewed_at', t.reviewed_at, 'created_at', t.created_at) as row
  from public.topup_requests t
  join public.professional_profiles pp on pp.user_id = t.professional_id
  left join public.topup_methods m on m.id = t.method_id
  left join public.receiving_accounts a on a.id = t.bank_account_id
  where case p_status
          when 'todas' then true
          when 'pendiente' then t.status = 'pending'
          when 'acreditadas' then t.status = 'approved'
          else t.status = 'approved' and t.bank_status = p_status end
    -- Como el resumen: el mes de una recarga acreditada es el de su
    -- acreditación; el de una por revisar, el de su pedido.
    and (v_month is null
         or (case when t.status = 'approved' then t.reviewed_at else t.created_at end) >= v_from
            and (case when t.status = 'approved' then t.reviewed_at else t.created_at end) < v_to)
    and (v_q = '' or public.hmy_norm(concat_ws(' ', pp.display_name, t.reference, t.bank_reference, t.id::text))
                     like '%' || v_q || '%'))
  select count(*), coalesce(sum(r.amount), 0),
         coalesce((select jsonb_agg(x.row order by x.id desc)
                   from (select r2.row, r2.id from r r2 order by r2.id desc
                         limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb)
  into v_total, v_sum, v_items
  from r;
  return jsonb_build_object('items', v_items, 'total', v_total, 'sum_bs', v_sum,
                            'month', to_char(v_month, 'YYYY-MM'), 'timezone', v_tz);
end $$;

revoke execute on function public.owner_finance_ledger(text, date, text, uuid, int) from public, anon;
revoke execute on function public.owner_finance_topups(text, date, text, int) from public, anon;
grant execute on function public.owner_finance_ledger(text, date, text, uuid, int) to authenticated;
grant execute on function public.owner_finance_topups(text, date, text, int) to authenticated;
