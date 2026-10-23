#!/usr/bin/env bash
# Arma send-push como un solo archivo para pegarlo en el panel de Supabase
# (Edge Functions > Deploy a new function > Via Editor). Mismo código que en el repositorio.
# Uso: supabase/scripts/bundle_send_push.sh <carpeta de salida>
set -euo pipefail
cd "$(dirname "$0")/../functions/send-push"
out="${1:?carpeta de salida}"
mkdir -p "$out"
{
  echo "// send-push — generado por supabase/scripts/bundle_send_push.sh desde el repositorio. No editar aquí."
  cat push.ts
  echo
  grep -v "^import .*'./push.ts';$" index.ts
} > "$out/send-push.ts"
(cd "$out" && sha256sum send-push.ts)
