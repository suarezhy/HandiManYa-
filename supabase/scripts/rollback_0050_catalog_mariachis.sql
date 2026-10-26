-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0050
-- (20261026005000_catalog_mariachis) en el proyecto de DESARROLLO.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0050_catalog_mariachis.sql
\set ON_ERROR_STOP 1
begin;
-- Si ya hay pedidos con Mariachis, la opción se desactiva en vez de borrarse.
update public.service_problems set is_active = false
where name = 'Mariachis' and category_id = (select id from public.service_categories where slug = 'eventos')
  and exists (select 1 from public.bookings b where (select id from public.service_problems
              where name = 'Mariachis' and category_id = b.category_id) = any (b.problem_ids));
delete from public.service_problems
where name = 'Mariachis' and is_active and category_id = (select id from public.service_categories where slug = 'eventos');
update public.service_categories set description = 'Meseros, churrasqueros, bandas, decoración y ayuda para fiestas'
where slug = 'eventos';
delete from supabase_migrations.schema_migrations where version = '20261026005000';
commit;
