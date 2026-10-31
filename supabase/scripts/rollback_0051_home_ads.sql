-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0051
-- (20261027005100_home_ads) en el proyecto de DESARROLLO.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0051_home_ads.sql
-- Borra los anuncios y sus cuentas. Las imágenes del bucket "ads" se borran
-- aparte desde el panel de Supabase (Storage no permite borrarlas por SQL).
\set ON_ERROR_STOP 1
begin;
drop function public.owner_set_ad_status(int, text);
drop function public.owner_save_ad(int, text, text, text, text, text, text, text, smallint, timestamptz, timestamptz);
drop function public.owner_ads();
drop function public.ad_click(int);
drop function public.home_ad(smallint);
drop function public.hmy_ad_live(public.ad_campaigns);
drop function public.hmy_ad_day();
drop policy "hmy ads write" on storage.objects;
drop policy "hmy ads delete" on storage.objects;
drop table public.ad_daily_stats;
drop table public.ad_campaigns;
delete from supabase_migrations.schema_migrations where version = '20261027005100';
commit;
