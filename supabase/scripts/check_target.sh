#!/usr/bin/env bash
# Verifica que la cadena de conexión apunta al proyecto nuevo
# handimanya-flutter-dev y nunca a los proyectos anteriores de FlutterFlow.
# Uso: DB_URL=... EXPECTED_REF=... supabase/scripts/check_target.sh
# Imprime el destino con la contraseña oculta. Sale con 1 si algo no cuadra.
set -euo pipefail

blocked_refs=(fbzlhyrcshkajebgrxja ozsuzlkxspqfdzvvxrag)

if [ -z "${DB_URL:-}" ]; then
  echo "::error::Falta el secreto SUPABASE_DB_URL en Settings > Secrets and variables > Actions."
  exit 1
fi
if [ -z "${EXPECTED_REF:-}" ]; then
  echo "::error::Falta EXPECTED_REF."
  exit 1
fi

# postgresql://USUARIO:CONTRASEÑA@HOST:PUERTO/BASE
re='^postgres(ql)?://([^:@/]+)(:[^@]*)?@([^:/?]+)(:([0-9]+))?/([^?]*)'
if [[ ! "${DB_URL}" =~ $re ]]; then
  echo "::error::La cadena de conexión no tiene el formato postgresql://usuario:contraseña@host:puerto/base."
  exit 1
fi
user="${BASH_REMATCH[2]}"
host="${BASH_REMATCH[4]}"
port="${BASH_REMATCH[6]:-5432}"
db="${BASH_REMATCH[7]}"

if [[ "${BASH_REMATCH[3]}" == *"YOUR-PASSWORD"* || "${BASH_REMATCH[3]}" == ":" || -z "${BASH_REMATCH[3]}" ]]; then
  echo "::error::Falta la contraseña: reemplaza [YOUR-PASSWORD] por la contraseña de la base."
  exit 1
fi

echo "Destino: usuario=${user} host=${host} puerto=${port} base=${db} (contraseña oculta)"

for ref in "${blocked_refs[@]}"; do
  if [[ "${user}" == *"${ref}"* || "${host}" == *"${ref}"* ]]; then
    echo "::error::Esta conexión es de un proyecto anterior de FlutterFlow (${ref}). No se toca."
    exit 1
  fi
done

# Session pooler: usuario postgres.<ref>. Conexión directa: host db.<ref>.supabase.co.
if [[ "${user}" == "postgres.${EXPECTED_REF}" || "${host}" == "db.${EXPECTED_REF}.supabase.co" ]]; then
  echo "Proyecto correcto: ${EXPECTED_REF} (handimanya-flutter-dev)"
else
  echo "::error::La conexión no es del proyecto handimanya-flutter-dev (${EXPECTED_REF})."
  exit 1
fi
