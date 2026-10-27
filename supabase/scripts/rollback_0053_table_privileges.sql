-- Deshace 0053: devuelve TRUNCATE, REFERENCES y TRIGGER a anon y authenticated.
begin;
grant truncate, references, trigger on all tables in schema public to anon, authenticated;
alter default privileges in schema public grant truncate, references, trigger on tables to anon, authenticated;
commit;
