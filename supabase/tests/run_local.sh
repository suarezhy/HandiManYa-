#!/usr/bin/env bash
# Crea una base PostgreSQL local vacía, aplica las migraciones y corre las
# pruebas. Nunca se conecta a Supabase.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${HMY_TEST_DB:-hmy_test}"
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"

run() { psql -v ON_ERROR_STOP=1 -q -X -d "$DB" -f "$1"; }

run tests/00_supabase_stub.sql 2>&1 | grep -v -e 'wal_level' -e 'HINT' || true
for f in migrations/*.sql; do
  echo "Aplicando $f"
  run "$f"
done
for t in tests/[1-9]*_tests.sql; do run "$t" 2>&1 | sed "s/^psql:[^ ]* NOTICE:  /  /"; done

# La misma comprobación que corre en dev después de aplicar (tablas,
# funciones, permisos). Así una tabla nueva sin anotar falla aquí y no en dev.
psql -q -X -d "$DB" -c "create schema if not exists supabase_migrations;
  create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);"
versions=""
for f in migrations/*.sql; do
  b="$(basename "$f" .sql)"
  psql -q -X -d "$DB" -c "insert into supabase_migrations.schema_migrations (version, name) values ('${b%%_*}', '${b#*_}') on conflict do nothing"
  versions="${versions}${b%%_*},"
done
psql -X -At -v ON_ERROR_STOP=1 -d "$DB" -v versions="${versions%,}" -f scripts/verify_remote.sql 2>&1 | sed "s/^psql:[^ ]* NOTICE:  /  /"
