-- Índices de búsqueda (0054).
\set ON_ERROR_STOP 1
\o /dev/null

select test.eq((select count(*)::int from pg_indexes where schemaname = 'public' and indexname in (
                 'conversations_customer_idx', 'conversations_professional_idx', 'booking_photos_booking_idx',
                 'professional_documents_professional_idx', 'professional_portfolio_professional_idx',
                 'professional_availability_professional_idx', 'verification_events_professional_idx',
                 'reviews_customer_idx', 'support_tickets_user_idx', 'user_reports_reporter_idx',
                 'user_reports_reported_idx', 'arrival_pin_attempts_booking_idx', 'trip_shares_customer_idx',
                 'messages_sender_idx')), 14, 'los 14 índices existen');
select test.eq((select count(*)::int from pg_index i join pg_class c on c.oid = i.indexrelid
                join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'public' and c.relname like '%\_idx' and not i.indisvalid), 0, 'ningún índice inválido');

\o
\echo 'PRUEBAS DE ÍNDICES DE BÚSQUEDA PASARON'
