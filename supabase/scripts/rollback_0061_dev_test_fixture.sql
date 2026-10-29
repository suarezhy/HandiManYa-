-- Deshace 0061: quita las capas de "Verificado", la marca y su guarda.
-- Antes, en dev: correr la acción "revertir" del profesional de prueba
-- (supabase/e2e/dev_fixture_pro.sql), para que ningún perfil quede marcado.
begin;
do $$ begin
  if exists (select 1 from public.professional_profiles where test_fixture) then
    raise exception 'HMY: hay perfiles de prueba marcados; revertirlos primero';
  end if;
end $$;
drop function public.search_professionals(smallint, int, int, text, boolean, numeric, text, int, int);
alter function public._search_professionals_base(smallint, int, int, text, boolean, numeric, text, int, int)
  rename to search_professionals;
grant execute on function public.search_professionals(smallint, int, int, text, boolean, numeric, text, int, int)
  to public;
drop function public.get_professional_public(uuid);
alter function public._get_professional_public_base(uuid) rename to get_professional_public;
grant execute on function public.get_professional_public(uuid) to public;
drop function public.booking_detail(uuid);
alter function public._booking_detail_destination(uuid) rename to booking_detail;
grant execute on function public.booking_detail(uuid) to authenticated;
drop function public.trip_share_view(text);
alter function public._trip_share_view_base(text) rename to trip_share_view;
grant execute on function public.trip_share_view(text) to anon, authenticated;
drop trigger professional_profiles_test_fixture_guard on public.professional_profiles;
drop function public.hmy_test_fixture_guard();
drop function public.hmy_is_test_fixture(uuid);
alter table public.professional_profiles drop column test_fixture;
delete from supabase_migrations.schema_migrations where version = '20261029006100';
commit;
