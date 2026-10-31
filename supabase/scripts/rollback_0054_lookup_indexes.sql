-- Deshace 0054: quita los índices (no cambia datos).
begin;
drop index if exists public.conversations_customer_idx, public.conversations_professional_idx,
  public.booking_photos_booking_idx, public.professional_documents_professional_idx,
  public.professional_portfolio_professional_idx, public.professional_availability_professional_idx,
  public.verification_events_professional_idx, public.reviews_customer_idx, public.support_tickets_user_idx,
  public.user_reports_reporter_idx, public.user_reports_reported_idx, public.arrival_pin_attempts_booking_idx,
  public.trip_shares_customer_idx, public.messages_sender_idx;
commit;
