-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0048
-- (20261026004800_home_map) en el proyecto de DESARROLLO. El inicio de la app
-- muestra el aviso de error del mapa hasta volver a aplicarla.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0048_home_map.sql
\set ON_ERROR_STOP 1
begin;
drop function public.home_map_professionals(smallint);
drop function public.hmy_map_jitter(uuid, int);
delete from supabase_migrations.schema_migrations where version = '20261026004800';
commit;
