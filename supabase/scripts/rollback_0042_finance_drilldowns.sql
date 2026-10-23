-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0042
-- (20261023004200_finance_drilldowns) en el proyecto de DESARROLLO.
--
-- 0042 solo agrega dos funciones de lectura; no crea tablas ni cambia datos.
-- Al revertir no se pierde nada: la app vuelve a mostrar las listas de
-- Finanzas con las funciones de 0038 ("Lista parcial").
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0042_finance_drilldowns.sql
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if to_regprocedure('public.owner_finance_ledger(text, date, text, uuid, integer)') is null
     or to_regprocedure('public.owner_finance_topups(text, date, text, integer)') is null then
    raise exception 'HMY: 0042 no está aplicada; no se revirtió nada.';
  end if;
end $$;

drop function public.owner_finance_ledger(text, date, text, uuid, integer);
drop function public.owner_finance_topups(text, date, text, integer);
delete from supabase_migrations.schema_migrations where version = '20261023004200';

commit;
