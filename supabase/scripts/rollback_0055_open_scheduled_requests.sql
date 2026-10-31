-- Deshace 0055: vuelve "Programar" solo con profesional elegido. Las solicitudes
-- programadas pendientes que ya existan se quedan como están (se cancelan solas
-- al vencer su plazo).
begin;
drop trigger if exists professional_profiles_offer_pending on public.professional_profiles;
drop trigger if exists professional_services_offer_pending on public.professional_services;
drop function if exists public.hmy_offer_pending_on_profile();
drop function if exists public.hmy_offer_pending_on_service();
drop function if exists public._hmy_offer_pending_to(uuid);
drop function if exists public.create_scheduled_request(int, smallint, text, text, timestamptz, int, text, int,
  public.payment_method, numeric, numeric, int[], text, text);
drop function if exists public._hmy_offer_scheduled(uuid);
drop function if exists public.hmy_scheduled_eligible_professionals(int, smallint, int, uuid, numeric, numeric);
drop function public.claim_ya_request(uuid);
alter function public._claim_ya_request_base(uuid) rename to claim_ya_request;
revoke execute on function public.claim_ya_request(uuid) from public, anon;
grant execute on function public.claim_ya_request(uuid) to authenticated;
commit;
