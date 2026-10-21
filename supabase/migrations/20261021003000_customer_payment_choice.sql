-- HandiMan ¡Ya! — el cliente dice cómo pagó (efectivo o QR) al marcar "Ya pagué".
-- El pago es directo al profesional; la plataforma solo guarda cómo fue.
-- El profesional sigue sin poder cambiar el método que eligió el cliente.
create or replace function public.acknowledge_payment(p_booking uuid, p_method public.payment_method)
returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status not in ('work_finished', 'completed') then raise exception 'HMY_INVALID_TRANSITION'; end if;
  if b.customer_id = auth.uid() then
    update public.bookings set customer_paid_ack_at = coalesce(customer_paid_ack_at, now()),
           payment_method = case when customer_paid_ack_at is null then coalesce(p_method, payment_method)
                                 else payment_method end
     where id = p_booking;
  elsif b.professional_id = auth.uid() then
    update public.bookings set professional_paid_ack_at = coalesce(professional_paid_ack_at, now()),
           payment_method = coalesce(payment_method, p_method) where id = p_booking;
  else
    raise exception 'HMY_FORBIDDEN';
  end if;
end $$;

revoke execute on function public.acknowledge_payment(uuid, public.payment_method) from public, anon;
grant execute on function public.acknowledge_payment(uuid, public.payment_method) to authenticated;
