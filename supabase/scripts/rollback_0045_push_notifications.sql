-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0045
-- (20261023004500_push_notifications) en el proyecto de DESARROLLO. Se pierden
-- los tokens de los teléfonos y la cola de envíos; los avisos dentro de la app
-- (tabla notifications) quedan intactos. Antes, apagar el webhook de push_outbox.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0045_push_notifications.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if to_regclass('public.push_outbox') is null then
    raise exception 'HMY: 0045 no está aplicada; no se revirtió nada.';
  end if;
end $$;
drop trigger notifications_push on public.notifications;
drop function public.hmy_push_enqueue();
drop function public.register_push_device(text, text);
drop function public.unregister_push_device(text);
drop function public.my_push_status();
drop function public.send_test_push();
drop function public.hmy_push_claim(int);
drop function public.hmy_push_report(jsonb);
drop function public.owner_push_overview();
drop function public.hmy_push_text(text);
drop table public.push_outbox;
drop table public.push_devices;
delete from public.notifications where kind = 'push_test';
delete from supabase_migrations.schema_migrations where version = '20261023004500';
commit;
