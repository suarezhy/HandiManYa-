-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0044
-- (20261023004400_owner_demand) en el proyecto de DESARROLLO. Solo agrega una
-- función de lectura; no se pierde ningún dato. La app vuelve a mostrar las
-- filas de demanda sin abrir la lista.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0044_owner_demand.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if to_regprocedure('public.owner_demand_bookings(text, text, text, integer)') is null then
    raise exception 'HMY: 0044 no está aplicada; no se revirtió nada.';
  end if;
end $$;
drop function public.owner_demand_bookings(text, text, text, integer);
delete from supabase_migrations.schema_migrations where version = '20261023004400';
commit;
