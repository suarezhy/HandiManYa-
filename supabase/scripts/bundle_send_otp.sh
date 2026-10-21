#!/usr/bin/env bash
# Arma send-otp como un solo archivo para pegarlo en el panel de Supabase
# (Edge Functions > Deploy a new function > Via Editor). Mismo código que en el repositorio.
# Uso: supabase/scripts/bundle_send_otp.sh <carpeta de salida>
set -euo pipefail
cd "$(dirname "$0")/../functions/send-otp"
out="${1:?carpeta de salida}"
mkdir -p "$out"
{
  echo "// send-otp — generado por supabase/scripts/bundle_send_otp.sh desde el repositorio. No editar aquí."
  cat otp.ts
  echo
  grep -v "^import .*'./otp.ts';$" index.ts
} > "$out/send-otp.ts"
(cd "$out" && sha256sum send-otp.ts)
