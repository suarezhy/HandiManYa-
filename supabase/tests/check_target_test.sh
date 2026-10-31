#!/usr/bin/env bash
# Prueba el candado de proyecto del workflow de migraciones (sin red).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { # esperado(0|1) descripción url
  DB_URL="$3" EXPECTED_REF=yldqopeldibwgbwmdnzy supabase/scripts/check_target.sh >/dev/null 2>&1
  local got=$?; [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$1" ]; then echo "  ok - $2"; else echo "  FALLÓ - $2"; fail=1; fi
}
check 0 'acepta el proyecto nuevo (session pooler)' 'postgresql://postgres.yldqopeldibwgbwmdnzy:pw@aws-0-sa-east-1.pooler.supabase.com:5432/postgres'
check 0 'acepta el proyecto nuevo (conexión directa)' 'postgresql://postgres:pw@db.yldqopeldibwgbwmdnzy.supabase.co:5432/postgres'
check 1 'rechaza el proyecto original de FlutterFlow' 'postgresql://postgres.fbzlhyrcshkajebgrxja:pw@aws-0-sa-east-1.pooler.supabase.com:5432/postgres'
check 1 'rechaza handimanya-dev de FlutterFlow' 'postgresql://postgres:pw@db.ozsuzlkxspqfdzvvxrag.supabase.co:5432/postgres'
check 1 'no se engaña con el ref nuevo escondido en la contraseña' 'postgresql://postgres.abcdefghijabcdefghij:yldqopeldibwgbwmdnzy@aws-0.pooler.supabase.com:5432/postgres'
check 1 'rechaza cualquier otro proyecto' 'postgresql://postgres.abcdefghijabcdefghij:pw@aws-0.pooler.supabase.com:5432/postgres'
check 1 'rechaza la contraseña sin reemplazar' 'postgresql://postgres.yldqopeldibwgbwmdnzy:[YOUR-PASSWORD]@aws-0.pooler.supabase.com:5432/postgres'
check 1 'rechaza el secreto vacío' ''
[ "$fail" -eq 0 ] && echo 'CANDADO DE PROYECTO OK'
exit $fail
