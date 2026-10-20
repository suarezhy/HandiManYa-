-- Comprueba, sin cambiar nada, que las migraciones quedaron completas en el
-- proyecto Supabase. Cada bloque falla con un mensaje claro si algo no cuadra.
-- Uso: psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/scripts/verify_remote.sql
\set ON_ERROR_STOP 1
set default_transaction_read_only = on;

do $$
declare
  v_tables text[] := array['admin_audit_log','booking_addresses','booking_events','booking_offers','booking_photos',
    'booking_transitions','bookings','cities','commission_rules','consent_records','conversation_reads','conversations',
    'departments','disputes','messages','notifications','professional_availability','professional_documents',
    'professional_locations','professional_portfolio','professional_profiles','professional_services',
    'professional_zones','profiles','promotions','reviews','service_categories','service_zones','support_tickets',
    'topup_methods','topup_requests','user_blocks','user_reports','user_roles','verification_events','wallet_ledger','wallets'];
  v_buckets jsonb := '{"avatars":true,"portfolio":true,"booking-photos":false,"chat-images":false,"payment-qr":false,"professional-documents":false,"topup-proofs":false}';
  v_functions text[] := array['handle_new_user','create_booking','create_ya_request','claim_ya_request','ya_eligible_professionals',
    'accept_booking','cancel_booking','confirm_completion','booking_detail','can_see_booking_address','set_booking_approx_point',
    'booking_distance_for_me','wallet_post','request_topup','review_topup','_commission_reserve','_commission_capture',
    '_commission_release','commission_rule_for','admin_save_commission_rule','admin_wallet_adjustment','ledger_is_append_only',
    'send_message','submit_review','report_user','block_user','record_consent','admin_dashboard','my_status','run_booking_housekeeping'];
  v_missing text;
  v_count int;
  v_failed int := 0;
  r record;
begin
  -- 1. Las nueve migraciones quedaron anotadas.
  select count(*) into v_count from supabase_migrations.schema_migrations
    where version in ('20261019000100','20261019000200','20261019000300','20261019000400','20261019000500',
                      '20261019000600','20261019000700','20261020000800','20261020000900');
  raise notice 'Migraciones registradas: % de 9', v_count;
  if v_count <> 9 then raise exception 'HMY: faltan migraciones registradas'; end if;

  -- 2. Las 37 tablas.
  select string_agg(t, ', ') into v_missing from unnest(v_tables) t
    where not exists (select 1 from pg_tables where schemaname = 'public' and tablename = t);
  select count(*) into v_count from pg_tables where schemaname = 'public';
  raise notice 'Tablas en public: % (se esperan 37)', v_count;
  if v_missing is not null then raise exception 'HMY: faltan tablas: %', v_missing; end if;
  if v_count <> 37 then raise exception 'HMY: hay % tablas, se esperaban 37', v_count; end if;

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
    (not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('create_booking', 'create_ya_request') and has_function_privilege('anon', oid, 'EXECUTE')), 'pedidos: anónimos no crean pedidos')
  ) as v(ok, what) loop
    raise notice '%  %', case when r.ok then 'ok -' else 'FALLA -' end, r.what;
    if not r.ok then v_failed := v_failed + 1; end if;
  end loop;
  if v_failed > 0 then
    raise exception 'HMY: % protección(es) no están como se esperaba', v_failed;
  end if;
end $$;
\echo 'COMPROBACIÓN COMPLETA: todo en orden.'
