-- Comprueba, sin cambiar nada, que las migraciones quedaron completas en el
-- proyecto Supabase. Cada bloque falla con un mensaje claro si algo no cuadra.
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -v versions=20261019000100,... -f supabase/scripts/verify_remote.sql
-- (versions: las migraciones del repositorio, separadas por comas)
\set ON_ERROR_STOP 1
set default_transaction_read_only = on;
select set_config('hmy.versions', :'versions', false);

do $$
declare
  v_tables text[] := array['admin_audit_log','ai_agent_runs','ai_agents','ai_items','app_settings','arrival_pin_attempts','booking_addresses','booking_arrivals','booking_events','booking_offers','booking_photos',
    'booking_transitions','bookings','cities','commission_rules','daily_reports','consent_records','conversation_reads','conversations',
    'departments','disputes','messages','notifications','otp_channel_choices','otp_sends','professional_availability','professional_documents',
    'professional_locations','professional_portfolio','professional_profiles','professional_services',
    'professional_zones','profiles','promotions','reviews','security_confirmations','security_settings','service_categories','service_problems','service_zones','support_tickets',
    'topup_methods','topup_requests','trip_locations','trip_shares','user_blocks','user_reports','user_roles','verification_events','wallet_ledger','wallets'];
  v_buckets jsonb := '{"avatars":true,"portfolio":true,"booking-photos":false,"chat-images":false,"payment-qr":false,"professional-documents":false,"topup-proofs":false}';
  v_functions text[] := array['handle_new_user','create_booking','create_ya_request','claim_ya_request','ya_eligible_professionals',
    'accept_booking','cancel_booking','confirm_completion','booking_detail','can_see_booking_address','set_booking_approx_point',
    'booking_distance_for_me','wallet_post','request_topup','review_topup','_commission_reserve','_commission_capture',
    '_commission_release','commission_rule_for','admin_save_commission_rule','admin_wallet_adjustment','ledger_is_append_only',
    'send_message','submit_review','report_user','block_user','record_consent','admin_dashboard','my_status','run_booking_housekeeping',
    'hmy_problem_labels','hmy_pro_cleared','_create_booking_base','_create_ya_request_base','_booking_detail_base',
    'hmy_require_confirmation','set_biometric_enabled',
    'run_marketplace_monitors','generate_daily_report','run_daily_report_if_due','admin_ai_overview','admin_decide_ai_item','admin_set_setting',
    'complete_signup','hmy_sync_auth_phone','hmy_otp_gate','hmy_otp_result',
    'mark_arrived','verify_arrival_pin','admin_verify_arrival','booking_arrival','hmy_arrival_gate','hmy_arrival_pin',
    'share_trip_location','stop_trip_location','trip_location','create_trip_share','my_trip_shares','revoke_trip_share','trip_share_view','hmy_trip_cleanup'];
  v_missing text;
  v_count int;
  v_failed int := 0;
  r record;
begin
  -- 1. Todas las migraciones del repositorio quedaron anotadas.
  select string_agg(v, ', ') into v_missing from unnest(string_to_array(current_setting('hmy.versions'), ',')) v
    where not exists (select 1 from supabase_migrations.schema_migrations m where m.version = v);
  select count(*) into v_count from supabase_migrations.schema_migrations;
  raise notice 'Migraciones registradas: % de %', v_count, cardinality(string_to_array(current_setting('hmy.versions'), ','));
  if v_missing is not null then raise exception 'HMY: faltan migraciones: %', v_missing; end if;

  -- 2. Todas las tablas esperadas.
  select string_agg(t, ', ') into v_missing from unnest(v_tables) t
    where not exists (select 1 from pg_tables where schemaname = 'public' and tablename = t);
  select count(*) into v_count from pg_tables where schemaname = 'public';
  raise notice 'Tablas en public: % (se esperan %)', v_count, cardinality(v_tables);
  if v_missing is not null then raise exception 'HMY: faltan tablas: %', v_missing; end if;
  if v_count <> cardinality(v_tables) then raise exception 'HMY: hay % tablas, se esperaban %', v_count, cardinality(v_tables); end if;

  -- 3. RLS en todas las tablas, y políticas.
  select string_agg(tablename, ', ') into v_missing from pg_tables where schemaname = 'public' and not rowsecurity;
  raise notice 'Tablas sin RLS: %', coalesce(v_missing, 'ninguna');
  if v_missing is not null then raise exception 'HMY: tablas sin RLS: %', v_missing; end if;
  select count(*) into v_count from pg_policies where schemaname = 'public';
  raise notice 'Políticas en tablas: %', v_count;
  select count(*) into v_count from pg_policies where schemaname = 'storage' and tablename = 'objects';
  raise notice 'Políticas de archivos (storage): %', v_count;
  if v_count < 11 then raise exception 'HMY: faltan políticas de storage (hay %)', v_count; end if;

  -- 4. Buckets con su privacidad.
  select string_agg(k, ', ') into v_missing from jsonb_each(v_buckets) b(k, pub)
    where not exists (select 1 from storage.buckets where id = k and public = pub::text::boolean);
  raise notice 'Buckets: %', (select string_agg(id || case when public then ' (pública)' else ' (privada)' end, ', ' order by id) from storage.buckets);
  if v_missing is not null then raise exception 'HMY: buckets faltantes o con privacidad incorrecta: %', v_missing; end if;

  -- 5. Funciones del servidor y el disparador de nuevos usuarios.
  select string_agg(f, ', ') into v_missing from unnest(v_functions) f
    where not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = f);
  select count(*) into v_count from pg_proc where pronamespace = 'public'::regnamespace;
  raise notice 'Funciones en public: %', v_count;
  if v_missing is not null then raise exception 'HMY: faltan funciones: %', v_missing; end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created') then
    raise exception 'HMY: falta el disparador on_auth_user_created en auth.users';
  end if;
  raise notice 'Disparador de nuevos usuarios: on_auth_user_created';

  -- 5b. Problemas por categoría: cada categoría activa tiene su lista y un "Otro".
  select string_agg(c.name, ', ') into v_missing from public.service_categories c
    where c.is_active and (
      (select count(*) from public.service_problems p where p.category_id = c.id and p.is_active) < 2
      or (select count(*) from public.service_problems p where p.category_id = c.id and p.is_active and p.is_other) <> 1);
  raise notice 'Problemas activos: % en % categorías', (select count(*) from public.service_problems where is_active),
    (select count(distinct category_id) from public.service_problems where is_active);
  if v_missing is not null then raise exception 'HMY: categorías sin lista de problemas completa: %', v_missing; end if;
  raise notice 'Categorías sensibles: %', (select string_agg(name || ' (' || required_doc || case when allows_ya then '' else ', sin ¡Ya!' end || ')', ', ' order by sort_order)
    from public.service_categories where required_doc is not null);

  -- 6. Protecciones: billetera, comisiones, pedidos y ubicación.
  for r in select * from (values
    (not has_table_privilege('authenticated', 'public.wallets', 'UPDATE'), 'billetera: la app no puede cambiar saldos'),
    (not has_table_privilege('authenticated', 'public.wallet_ledger', 'INSERT'), 'billetera: la app no puede escribir el libro mayor'),
    (not has_table_privilege('authenticated', 'public.wallet_ledger', 'UPDATE'), 'billetera: el libro mayor no se edita'),
    (exists (select 1 from pg_trigger where tgrelid = 'public.wallet_ledger'::regclass and not tgisinternal), 'billetera: el libro mayor solo acepta nuevas líneas'),
    (not has_function_privilege('authenticated', 'public.wallet_post(uuid, public.ledger_entry_type, numeric, numeric, text, uuid, bigint, text)', 'EXECUTE'), 'billetera: wallet_post es interna'),
    (not has_table_privilege('authenticated', 'public.topup_requests', 'UPDATE'), 'recargas: solo el admin las aprueba'),
    (not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'commission_rules' and cmd <> 'SELECT' and coalesce(with_check, qual) not like '%is_admin()%'), 'comisiones: solo el admin crea o cambia reglas'),
    (not has_function_privilege('authenticated', 'public.commission_rule_for(int, smallint)', 'EXECUTE'), 'comisiones: el cálculo es interno'),
    (not has_function_privilege('authenticated', 'public._commission_capture(uuid)', 'EXECUTE'), 'comisiones: el cobro es interno'),
    (not has_table_privilege('authenticated', 'public.bookings', 'UPDATE'), 'pedidos: los estados cambian solo por funciones'),
    (not has_table_privilege('authenticated', 'public.booking_events', 'INSERT'), 'pedidos: el historial no se escribe a mano'),
    (not has_table_privilege('anon', 'public.bookings', 'SELECT') or exists (select 1 from pg_class where oid = 'public.bookings'::regclass and relrowsecurity), 'pedidos: anónimos no ven pedidos'),
    (not has_table_privilege('authenticated', 'public.booking_addresses', 'INSERT'), 'ubicación: la dirección exacta se guarda solo por funciones'),
    (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'booking_addresses'), 'ubicación: la dirección exacta tiene política propia'),
    (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'professional_locations'), 'ubicación: la base del profesional tiene política propia'),
    (not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('create_booking', 'create_ya_request') and has_function_privilege('anon', oid, 'EXECUTE')), 'pedidos: anónimos no crean pedidos'),
    (not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_create_booking_base', '_create_ya_request_base', '_booking_detail_base') and has_function_privilege('authenticated', oid, 'EXECUTE')), 'pedidos: las funciones internas no se llaman desde la app'),
    (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'service_problems' and cmd = 'ALL' and qual like '%is_admin()%'), 'problemas: solo el admin los cambia'),
    (not exists (select 1 from public.service_categories where slug in ('ninera', 'asesoria-legal') and allows_ya), 'sensibles: niñera y asesoría legal no van por ¡Ya!'),
    ((select count(*) from public.service_categories where slug in ('ninera', 'cerrajeria', 'mecanica', 'asesoria-legal') and required_doc is not null) = 4, 'sensibles: piden documento aceptado'),
    (not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'request_topup' and pronargs < 6), 'recargas: no queda la versión sin confirmación'),
    (not has_table_privilege('authenticated', 'public.topup_requests', 'INSERT'), 'recargas: solo se piden con confirmación (por función)'),
    (not has_function_privilege('authenticated', 'public.hmy_require_confirmation(text, text)', 'EXECUTE'), 'confirmación: la regla es interna'),
    (not has_table_privilege('authenticated', 'public.security_settings', 'UPDATE') and not has_table_privilege('authenticated', 'public.security_settings', 'INSERT'), 'seguridad: huella o rostro se activan solo con contraseña (por función)'),
    (not has_table_privilege('authenticated', 'public.security_confirmations', 'SELECT') and not has_table_privilege('authenticated', 'public.security_confirmations', 'INSERT'), 'confirmación: el registro de usos es interno'),
    (not has_table_privilege('authenticated', 'public.ai_items', 'INSERT') and not has_table_privilege('authenticated', 'public.ai_items', 'UPDATE'), 'agentes IA: la app no escribe avisos directamente'),
    (not has_function_privilege('authenticated', 'public.run_marketplace_monitors()', 'EXECUTE') and not has_function_privilege('authenticated', 'public.generate_daily_report(date, text)', 'EXECUTE'), 'agentes IA: monitores y reporte son internos'),
    ((select count(*) from pg_policies where schemaname = 'public' and tablename in ('ai_agents','ai_agent_runs','ai_items','daily_reports','app_settings') and qual like '%is_admin()%') = 5, 'agentes IA: solo el administrador ve el centro de control'),
    ((select (value ->> 'monthly_usd')::numeric from public.app_settings where key = 'ai_budget') is not null, 'agentes IA: hay un presupuesto (gasto en IA solo con aprobación)'),
    (not has_column_privilege('authenticated', 'public.profiles', 'phone', 'UPDATE'), 'celular: solo Supabase Auth cambia el número (después del código)'),
    (exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'profiles_phone_unique'), 'celular: un número, una cuenta'),
    (exists (select 1 from pg_trigger where tgname = 'on_auth_user_phone' and tgrelid = 'auth.users'::regclass), 'celular: el número verificado pasa al perfil'),
    (not has_function_privilege('authenticated', 'public.hmy_otp_gate(text, text, uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.hmy_otp_gate(text, text, uuid)', 'EXECUTE'), 'códigos: los límites de envío solo los usa el servicio de envío'),
    (exists (select 1 from pg_trigger where tgname = 'bookings_arrival_gate' and tgrelid = 'public.bookings'::regclass), 'llegada: sin llegada verificada no se empieza el trabajo'),
    (not has_table_privilege('authenticated', 'public.booking_arrivals', 'SELECT') and not has_table_privilege('anon', 'public.booking_arrivals', 'SELECT'), 'llegada: nadie lee los códigos guardados'),
    (not has_table_privilege('authenticated', 'public.trip_locations', 'SELECT') and not has_table_privilege('anon', 'public.trip_shares', 'SELECT'), 'viaje: la ubicación y los enlaces solo se leen por las funciones'),
    (exists (select 1 from pg_trigger where tgname = 'bookings_trip_cleanup'), 'viaje: la ubicación se borra al salir de "en camino"')
  ) as v(ok, what) loop
    raise notice '%  %', case when r.ok then 'ok -' else 'FALLA -' end, r.what;
    if not r.ok then v_failed := v_failed + 1; end if;
  end loop;
  if v_failed > 0 then
    raise exception 'HMY: % protección(es) no están como se esperaba', v_failed;
  end if;
end $$;
do $$ begin
  if to_regclass('cron.job') is not null then
    raise notice 'Tareas programadas: %', (select string_agg(jobname || ' (' || schedule || ')', ', ') from cron.job where jobname like 'hmy-%');
  else
    raise notice 'Tareas programadas: pg_cron no está instalado';
  end if;
end $$;
\echo 'COMPROBACIÓN COMPLETA: todo en orden.'
