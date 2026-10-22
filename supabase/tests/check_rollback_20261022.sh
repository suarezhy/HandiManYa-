#!/usr/bin/env bash
# Prueba local del plan de reversión de 0034 a 0037 (nunca se conecta a Supabase).
# 1. Base A: migraciones hasta 0033, con datos de prueba (los archivos de prueba
#    10 a 99b, sin deshacer).
# 2. Base B: copia de A, más 0034 a 0037, más supabase/scripts/rollback_20261022.sql.
# 3. El esquema y los datos de B tienen que ser iguales a los de A, salvo lo
#    que el script deja a propósito (TRUNCATE en la auditoría, last_run_at).
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/check_rollback_20261022.sh
set -euo pipefail
cd "$(dirname "$0")/.."
run() { psql -v ON_ERROR_STOP=1 -q -X -d "$1" -f "$2" >/dev/null; }
psql -q -d postgres -c "drop database if exists hmy_rb_a" -c "drop database if exists hmy_rb_b" -c "create database hmy_rb_a" 2>/dev/null
run hmy_rb_a tests/00_supabase_stub.sql 2>/dev/null || true
for f in migrations/*.sql; do
  [[ "$(basename "$f")" > "20261022003400" ]] && break
  run hmy_rb_a "$f"
done
for t in tests/[1-9]*_tests.sql; do
  [[ "$(basename "$t")" > "99c" ]] && break
  run hmy_rb_a "$t" 2>/dev/null
done
psql -q -d postgres -c "create database hmy_rb_b template hmy_rb_a"
for f in migrations/20261022003[4-7]00_*.sql; do run hmy_rb_b "$f"; done
run hmy_rb_b scripts/rollback_20261022.sql

dump() {
  pg_dump -d "$1" --schema-only --no-owner -n public -n storage \
    | sed -E 's/(anon|authenticated)=rxt/\1=rDxt/' \
    | grep -v -e '^--' -e '^$' -e '^\\restrict' -e '^\\unrestrict' -e 'admin_audit_log FROM anon' -e 'admin_audit_log FROM authenticated' \
                -e 'admin_audit_log TO anon' -e 'admin_audit_log TO authenticated'
}
# Datos: todas las tablas de public, sin last_run_* ni updated_at de los agentes.
data() {
  for t in $(psql -X -At -d "$1" -c "select tablename from pg_tables where schemaname = 'public' order by 1"); do
    case "$t" in
      ai_agents) cols="key, number, name, purpose, phase, status, needs, added_by_claude" ;;
      ai_agent_runs|admin_audit_log) continue ;;
      *) cols="*" ;;
    esac
    echo "== $t"
    psql -X -At -d "$1" -c "select $cols from public.$t" | sort
  done
}
fail=0
diff <(dump hmy_rb_a) <(dump hmy_rb_b) || { echo 'El esquema no volvió a 0033.'; fail=1; }
diff <(data hmy_rb_a) <(data hmy_rb_b) || { echo 'Los datos cambiaron.'; fail=1; }
[ "$fail" = 0 ] && echo 'PRUEBA DE REVERSIÓN 0034-0037: el esquema y los datos volvieron a 0033.'
exit "$fail"
