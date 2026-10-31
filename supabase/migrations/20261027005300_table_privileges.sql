-- HandiMan ¡Ya! — 0053 Las cuentas de la app no pueden vaciar tablas.
--
-- Supabase da a anon y authenticated todos los permisos sobre las tablas
-- nuevas, incluido TRUNCATE, que se salta las políticas RLS. La API no lo
-- usa, pero se quita igual (con REFERENCES y TRIGGER, que la app tampoco usa).
-- SELECT, INSERT, UPDATE y DELETE quedan como estaban, siempre bajo RLS.

revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;
