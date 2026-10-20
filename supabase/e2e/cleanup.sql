-- Borra todo lo que dejó la prueba E2E: las tres cuentas e2e-*@test.bo y
-- todo lo que hicieron (pedidos, mensajes, recargas, movimientos de billetera,
-- avisos, registros de auditoría). Corre siempre al final, aunque la prueba falle.
--
-- El libro de la billetera no admite borrar filas (wallet_ledger_no_update).
-- Solo aquí, dentro de esta transacción, se apaga ese bloqueo para borrar los
-- movimientos de la cuenta de prueba y se vuelve a encender antes de terminar.
-- Si algo falla, se deshace todo, incluido el apagado.
--
-- Uso: psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/e2e/cleanup.sql
\set ON_ERROR_STOP 1
begin;

create temp table e2e_ids on commit drop as
  select id from auth.users where email like 'e2e-%@test.bo';
create temp table e2e_bookings on commit drop as
  select id from public.bookings
   where customer_id in (select id from e2e_ids) or professional_id in (select id from e2e_ids);

delete from public.reviews where booking_id in (select id from e2e_bookings)
   or customer_id in (select id from e2e_ids) or professional_id in (select id from e2e_ids);
delete from public.disputes where booking_id in (select id from e2e_bookings) or opened_by in (select id from e2e_ids);
delete from public.support_tickets where booking_id in (select id from e2e_bookings) or user_id in (select id from e2e_ids);
delete from public.user_reports where booking_id in (select id from e2e_bookings)
   or reporter_id in (select id from e2e_ids) or reported_id in (select id from e2e_ids);
delete from public.messages where sender_id in (select id from e2e_ids)
   or conversation_id in (select id from public.conversations
                           where customer_id in (select id from e2e_ids) or professional_id in (select id from e2e_ids));
delete from public.conversations where customer_id in (select id from e2e_ids) or professional_id in (select id from e2e_ids);
delete from public.booking_photos where booking_id in (select id from e2e_bookings);
delete from public.bookings where id in (select id from e2e_bookings);
delete from public.topup_requests where professional_id in (select id from e2e_ids);

alter table public.wallet_ledger disable trigger wallet_ledger_no_update;
delete from public.wallet_ledger where professional_id in (select id from e2e_ids);
alter table public.wallet_ledger enable trigger wallet_ledger_no_update;
delete from public.wallets where professional_id in (select id from e2e_ids);

-- Lo que el admin de prueba revisó queda sin revisor.
update public.professional_profiles set reviewed_by = null where reviewed_by in (select id from e2e_ids);
update public.topup_requests set reviewed_by = null where reviewed_by in (select id from e2e_ids);
update public.user_reports set reviewed_by = null where reviewed_by in (select id from e2e_ids);
update public.disputes set resolved_by = null where resolved_by in (select id from e2e_ids);
update public.ai_items set decided_by = null where decided_by in (select id from e2e_ids);
delete from public.verification_events where actor_id in (select id from e2e_ids)
   or professional_id in (select id from e2e_ids);
delete from public.admin_audit_log where actor_id in (select id from e2e_ids);
delete from public.otp_sends where user_id in (select id from e2e_ids);

delete from auth.users where id in (select id from e2e_ids);

do $$ begin
  if exists (select 1 from auth.users where email like 'e2e-%@test.bo') then
    raise exception 'HMY: quedaron cuentas E2E';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'wallet_ledger_no_update' and tgenabled = 'O') then
    raise exception 'HMY: el bloqueo del libro de la billetera no quedó encendido';
  end if;
end $$;

commit;
\echo 'Datos E2E borrados; el libro de la billetera sigue protegido.'
