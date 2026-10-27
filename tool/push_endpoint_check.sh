#!/usr/bin/env bash
# Comprueba que send-push (dev) no está abierto: sin el secreto del webhook
# responde 401 y no hace nada. No usa secretos ni manda avisos.
# Uso: bash tool/push_endpoint_check.sh
set -uo pipefail
url="https://yldqopeldibwgbwmdnzy.supabase.co/functions/v1/send-push"
ok=1
first=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$url")
if [ "$first" = "404" ]; then echo "send-push todavía no está desplegado (HTTP 404)."; exit 0; fi
check() { # nombre, código esperado, curl args...
  local name="$1" want="$2"; shift 2
  local out code
  out=$(curl -sS -o /dev/stdout -w '\n%{http_code}' "$@" "$url")
  code=$(tail -n1 <<< "$out")
  echo "$name: HTTP $code $(head -n1 <<< "$out" | head -c 120)"
  [ "$code" = "$want" ] || ok=0
}
check "Sin encabezado" 401 -X POST -H 'Content-Type: application/json' -d '{"token":"x"}'
check "Con un secreto equivocado" 401 -X POST -H 'x-hmy-push-secret: equivocado' -d '{}'
check "GET" 405 -X GET
[ $ok = 1 ] && echo "Resultado: send-push rechaza a quien no tiene el secreto." || { echo "Resultado: REVISAR"; exit 1; }
