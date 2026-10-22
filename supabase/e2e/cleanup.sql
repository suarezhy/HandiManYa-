-- Borra todo lo que dejó la prueba E2E: las cuentas e2e-*@test.bo y
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

-- Casos del equipo que abrieron los datos de la prueba (soporte, reportes,
-- disputas y la postulación del profesional de prueba) y sus notas.
create temp table e2e_cases on commit drop as
  select c.id from public.ops_cases c
   where (c.kind = 'support' and c.ref_id in (select t.id::text from public.support_tickets t
                                               where t.user_id in (select id from e2e_ids)
                                                  or t.booking_id in (select id from e2e_bookings)))
      or (c.kind = 'report' and c.ref_id in (select r.id::text from public.user_reports r
                                              where r.reporter_id in (select id from e2e_ids)
                                                 or r.reported_id in (select id from e2e_ids)
                                                 or r.booking_id in (select id from e2e_bookings)))
      or (c.kind = 'dispute' and c.ref_id in (select id::text from e2e_bookings))
      or (c.kind = 'application' and c.ref_id in (select id::text from e2e_ids));
delete from public.ops_case_notes where case_id in (select id from e2e_cases) or author_id in (select id from e2e_ids);
delete from public.ops_cases where id in (select id from e2e_cases);
-- Un caso real nunca se borra: si el equipo de prueba lo tocó, solo se le quita.
update public.ops_cases set assigned_to = null, assigned_at = null where assigned_to in (select id from e2e_ids);
update public.ops_cases set assigned_by = null where assigned_by in (select id from e2e_ids);
update public.professional_documents set flagged_at = null, flagged_by = null, flag_note = null
 where flagged_by in (select id from e2e_ids);
delete from public.staff_members where user_id in (select id from e2e_ids) or granted_by in (select id from e2e_ids);

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
  if exists (select 1 from public.staff_members where user_id::text like 'e2e00000-%') then
    raise exception 'HMY: quedaron roles de equipo de prueba';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'wallet_ledger_no_update' and tgenabled = 'O') then
    raise exception 'HMY: el bloqueo del libro de la billetera no quedó encendido';
  end if;
end $$;

commit;
\echo 'Datos E2E borrados; el libro de la billetera sigue protegido.'
