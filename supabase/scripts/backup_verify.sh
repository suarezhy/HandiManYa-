#!/usr/bin/env bash
# Respaldo de la base de dev, comprobado antes de guardarlo. Solo LEE la base
# de dev; la prueba de restauración corre en una base local desechable.
#
# Uso:
#   DB_URL=...                      (la base de dev, solo lectura)
#   RESTORE_ADMIN_URL=...           (PostgreSQL local con superusuario, para restaurar)
#   OUT=dir                         (dónde dejar el respaldo cifrado)
#   BACKUP_PASSPHRASE=...           (sin ella se comprueba pero no se guarda nada)
#   supabase/scripts/backup_verify.sh
#
# Qué comprueba:
# 1. pg_dump de todo el esquema public (estructura y datos) y de los datos de
#    auth.users, storage.buckets y storage.objects (los archivos en sí viven
#    en Storage y no entran).
# 2. Que cada tabla tenga en el respaldo las mismas filas que en la base.
# 3. Que los datos de public se restauren sin errores en una base local con
#    las mismas migraciones, y que ahí también cuadren las filas.
# 4. Que el archivo cifrado se pueda descifrar y abrir.
# En los registros solo salen nombres de tablas y cantidades: nunca datos.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

: "${DB_URL:?Falta DB_URL}"
: "${RESTORE_ADMIN_URL:?Falta RESTORE_ADMIN_URL}"
: "${OUT:?Falta OUT}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT"

live() { psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 "$@"; }

# Filas por tabla, con el mismo formato que count_dump: "esquema.tabla cantidad".
count_sql="select table_schema || '.' || table_name || ' ' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name),
                                        false, true, '')))[1]::text
  from information_schema.tables
  where table_type = 'BASE TABLE'
    and (table_schema = 'public'
         or (table_schema, table_name) in (('auth', 'users'), ('storage', 'buckets'), ('storage', 'objects')))
  order by 1"

# Filas en un respaldo, contando las líneas de cada COPY (COPY escapa los
# saltos de línea, así que una línea es una fila). Las tablas vacías no
# aparecen; se completan con 0 al comparar.
count_dump() {
  pg_restore --data-only -f - "$@" | awk '
    /^COPY / { t = $2; n = 0; inside = 1; next }
    inside && $0 == "\\." { print t " " n; inside = 0; next }
    inside { n++ }' | sort
}

compare() { # $1 esperado, $2 obtenido, $3 nombre
  local bad
  bad="$(join -a1 -a2 -e 0 -o 0,1.2,2.2 "$1" "$2" | awk -v where="$3" '$2 != $3 { print "  " $1 ": " $2 " esperadas, " $3 " en " where }')"
  if [ -n "$bad" ]; then
    echo "::error::Las filas no cuadran ($3):"
    echo "$bad"
    return 1
  fi
}

echo "== 1. Respaldo"
versions="$(live -c "select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations")"
echo "Migraciones en la base: $(tr ',' '\n' <<< "$versions" | grep -c .)"
server_major="$(live -c "show server_version_num" | cut -c1-2)"
echo "PostgreSQL de la base: $server_major · pg_dump: $(pg_dump --version | awk '{print $3}')"

dump_ok=""
for attempt in 1 2; do
  live -c "$count_sql" | sort > "$work/live.txt"
  pg_dump "$DB_URL" -Fc --schema=public -f "$work/public.dump"
  pg_dump "$DB_URL" -Fc --data-only -t auth.users -t storage.buckets -t storage.objects -f "$work/auth_storage.dump"
  { count_dump "$work/public.dump"; count_dump "$work/auth_storage.dump"; } | sort > "$work/dump.txt"
  if compare "$work/live.txt" "$work/dump.txt" "el respaldo"; then dump_ok=1; break; fi
  # Alguien usó la app justo durante el respaldo: se repite una vez.
  echo "Se repite el respaldo una vez."
done
[ -n "$dump_ok" ] || exit 1
echo "Tablas: $(wc -l < "$work/live.txt") · filas: $(awk '{s += $2} END {print s}' "$work/live.txt") · todo cuadra."
for t in public.profiles public.bookings public.professional_profiles auth.users; do
  grep -q "^$t " "$work/live.txt" || { echo "::error::Falta la tabla $t"; exit 1; }
done

echo "== 2. Restauración de prueba (base local desechable)"
restore_db=hmy_restore_check
psql "$RESTORE_ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c "drop database if exists $restore_db" -c "create database $restore_db"
restore_url="${RESTORE_ADMIN_URL%/*}/$restore_db"
rdb() { psql "$restore_url" -X -q -v ON_ERROR_STOP=1 "$@"; }
rdb -f tests/00_supabase_stub.sql > /dev/null 2>&1
for f in migrations/*.sql; do
  b="$(basename "$f" .sql)"
  if [ -n "$versions" ] && ! tr ',' '\n' <<< "$versions" | grep -qx "${b%%_*}"; then
    echo "No está en la base, no se aplica: $b"
    continue
  fi
  rdb -f "$f" > /dev/null 2>&1 || { echo "::error::La migración $b no corre en la base local"; exit 1; }
done
# Las migraciones traen datos iniciales (ciudades, servicios): se vacían para
# que quede exactamente lo del respaldo.
rdb -At -c "select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
            from pg_tables where schemaname = 'public'" > "$work/truncate.sql"
rdb -f "$work/truncate.sql"
if ! pg_restore --data-only --disable-triggers --no-owner --schema=public -d "$restore_url" \
     "$work/public.dump" 2> "$work/restore.err"; then
  # Los mensajes de error pueden traer datos: solo se dice cuántos y en qué tablas.
  echo "::error::La restauración falló: $(grep -c 'error' "$work/restore.err") errores en" \
    "$(grep -o 'COPY [a-z_]*' "$work/restore.err" | sort -u | tr '\n' ' ')"
  exit 1
fi
psql "$restore_url" -X -At -v ON_ERROR_STOP=1 -c "$count_sql" | grep '^public\.' | sort > "$work/restored.txt"
grep '^public\.' "$work/dump.txt" > "$work/dump_public.txt" || true
compare "$work/restored.txt" "$work/dump_public.txt" "la restauración"
echo "Datos de public restaurados: $(wc -l < "$work/restored.txt") tablas, todo cuadra."
psql "$RESTORE_ADMIN_URL" -X -q -c "drop database $restore_db"

echo "== 3. Guardar cifrado"
if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  echo "::error::Respaldo comprobado pero NO guardado: falta el secreto BACKUP_PASSPHRASE."
  exit 3
fi
stamp="$(date -u +%Y%m%d-%H%M%S)"
{
  echo "respaldo $stamp"
  echo "postgres $server_major"
  echo "migraciones $versions"
  (cd "$work" && sha256sum public.dump auth_storage.dump)
  cat "$work/live.txt"
} > "$work/manifest.txt"
file="$OUT/respaldo-dev-$stamp.tar.gpg"
tar -C "$work" -cf - manifest.txt public.dump auth_storage.dump |
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 \
      -o "$file" 3<<< "$BACKUP_PASSPHRASE"
listed="$(gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d "$file" 3<<< "$BACKUP_PASSPHRASE" | tar -tf - | sort | tr '\n' ' ')"
[ "$listed" = "auth_storage.dump manifest.txt public.dump " ] || { echo "::error::El archivo cifrado no se abre bien"; exit 1; }
echo "Guardado: $(basename "$file") ($(du -h "$file" | cut -f1)), se descifra y abre bien."
