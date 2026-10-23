-- Huella de los datos que NO son de la prueba E2E: una línea por tabla con la
-- cantidad de filas y un md5 de las columnas que importan. Solo muestra
-- conteos y hashes, nunca datos personales. El flujo e2e-dev la toma antes y
-- después de la prueba y falla si algo cambió.
-- No incluye lo que cambia solo con las tareas programadas (avisos de los
-- agentes, notificaciones, historial de ejecuciones, auditoría).
--
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/e2e/fingerprint.sql
\set ON_ERROR_STOP 1
create temp view e2e_ids as select id from auth.users where email like 'e2e-%@test.bo' or id::text like 'e2e00000-%';
-- Desde aquí, solo lectura.
set default_transaction_read_only = on;
select 'auth.users|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, email, phone, email_confirmed_at, phone_confirmed_at), ';' order by id), ''))
  from auth.users where id not in (select id from e2e_ids);
select 'profiles|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, full_name, phone, phone_verified_at, city_id, avatar_path, active_role, terms_accepted_at, deletion_requested_at, suspended_at), ';' order by id), ''))
  from public.profiles where id not in (select id from e2e_ids);
select 'user_roles|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', user_id, role), ';' order by user_id, role), ''))
  from public.user_roles where user_id not in (select id from e2e_ids);
select 'staff_members|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', user_id, role, status), ';' order by user_id), ''))
  from public.staff_members where user_id not in (select id from e2e_ids);
select 'professional_profiles|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', user_id, status, display_name, city_id), ';' order by user_id), ''))
  from public.professional_profiles where user_id not in (select id from e2e_ids);
select 'professional_documents|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, doc_type, status, flagged_at), ';' order by id), ''))
  from public.professional_documents where professional_id not in (select id from e2e_ids);
select 'wallets|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', professional_id, available, reserved), ';' order by professional_id), ''))
  from public.wallets where professional_id not in (select id from e2e_ids);
select 'wallet_ledger|' || count(*) || '|' || md5(coalesce(string_agg(id::text, ';' order by id), ''))
  from public.wallet_ledger where professional_id not in (select id from e2e_ids);
select 'topup_requests|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, status, to_jsonb(t) ->> 'bank_status',
                                                                          to_jsonb(t) ->> 'bank_reference'), ';' order by id), ''))
  from public.topup_requests t where professional_id not in (select id from e2e_ids);
-- Cuentas de cobro (desde 0038; antes no existe y no se imprime nada).
select format($f$select 'receiving_accounts|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, label, bank_name,
  holder_name, account_number, qr_path, verification, is_active), ';' order by id), '')) from public.receiving_accounts
  where created_by not in (select id from e2e_ids)$f$)
where to_regclass('public.receiving_accounts') is not null \gexec
select 'bookings|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, status), ';' order by id), ''))
  from public.bookings where customer_id not in (select id from e2e_ids)
   and coalesce(professional_id, customer_id) not in (select id from e2e_ids);
select 'support_tickets|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, status), ';' order by id), ''))
  from public.support_tickets where user_id not in (select id from e2e_ids);
select 'user_reports|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, status), ';' order by id), ''))
  from public.user_reports where reporter_id not in (select id from e2e_ids) and reported_id not in (select id from e2e_ids);
select 'disputes|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, status), ';' order by id), ''))
  from public.disputes where opened_by not in (select id from e2e_ids);
select 'ops_cases|' || count(*) || '|' || md5(coalesce(string_agg(concat_ws(',', id, kind, status, assigned_to), ';' order by id), ''))
  from public.ops_cases c
 where not (c.kind = 'application' and c.ref_id in (select id::text from e2e_ids))
   and not (c.kind = 'support' and c.ref_id in (select t.id::text from public.support_tickets t where t.user_id in (select id from e2e_ids)))
   and not (c.kind = 'report' and c.ref_id in (select r.id::text from public.user_reports r
                                                where r.reporter_id in (select id from e2e_ids) or r.reported_id in (select id from e2e_ids)))
   and not (c.kind = 'dispute' and c.ref_id in (select b.id::text from public.bookings b
                                                 where b.customer_id in (select id from e2e_ids) or b.professional_id in (select id from e2e_ids)));
