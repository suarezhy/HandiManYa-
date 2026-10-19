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
