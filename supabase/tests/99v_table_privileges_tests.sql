-- Las cuentas de la app no pueden vaciar tablas (0053).
\set ON_ERROR_STOP 1
\o /dev/null

select test.eq((select count(*)::int from pg_tables t, (values ('anon'), ('authenticated')) r(role)
                where t.schemaname = 'public'
                  and (has_table_privilege(r.role, format('public.%I', t.tablename), 'TRUNCATE')
                       or has_table_privilege(r.role, format('public.%I', t.tablename), 'REFERENCES')
                       or has_table_privilege(r.role, format('public.%I', t.tablename), 'TRIGGER'))), 0,
               'anon y authenticated: sin TRUNCATE, REFERENCES ni TRIGGER en ninguna tabla');
select test.eq(has_table_privilege('authenticated', 'public.bookings', 'SELECT'), true,
               'authenticated: sigue leyendo sus pedidos (bajo RLS)');
select test.eq(has_table_privilege('anon', 'public.service_categories', 'SELECT'), true,
               'anon: sigue viendo el catálogo');

-- Las tablas nuevas tampoco reciben esos permisos.
create table public.hmy_test_0053 (id int);
select test.eq(has_table_privilege('anon', 'public.hmy_test_0053', 'TRUNCATE'), false, 'tabla nueva: anon sin TRUNCATE');
select test.eq(has_table_privilege('authenticated', 'public.hmy_test_0053', 'TRUNCATE'), false,
               'tabla nueva: authenticated sin TRUNCATE');
drop table public.hmy_test_0053;

\o
\echo 'PRUEBAS DE PRIVILEGIOS DE TABLAS PASARON'
