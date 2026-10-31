-- HandiMan ¡Ya! — 0054 Índices para las búsquedas que hacen la app y las políticas RLS.
--
-- Estas columnas se usan para filtrar (la lista de chats, las fotos de un
-- pedido, los documentos de un profesional, los permisos de RLS) y no tenían
-- índice. Con pocos datos no se nota; con miles de pedidos, sí. Solo agrega
-- índices: no cambia datos ni permisos.

create index if not exists conversations_customer_idx on public.conversations (customer_id);
create index if not exists conversations_professional_idx on public.conversations (professional_id);
create index if not exists booking_photos_booking_idx on public.booking_photos (booking_id);
create index if not exists professional_documents_professional_idx on public.professional_documents (professional_id);
create index if not exists professional_portfolio_professional_idx on public.professional_portfolio (professional_id);
create index if not exists professional_availability_professional_idx on public.professional_availability (professional_id);
create index if not exists verification_events_professional_idx on public.verification_events (professional_id);
create index if not exists reviews_customer_idx on public.reviews (customer_id);
create index if not exists support_tickets_user_idx on public.support_tickets (user_id);
create index if not exists user_reports_reporter_idx on public.user_reports (reporter_id);
create index if not exists user_reports_reported_idx on public.user_reports (reported_id);
create index if not exists arrival_pin_attempts_booking_idx on public.arrival_pin_attempts (booking_id);
create index if not exists trip_shares_customer_idx on public.trip_shares (customer_id);
create index if not exists messages_sender_idx on public.messages (sender_id);
