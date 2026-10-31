#!/usr/bin/env bash
# Arma identity-check y didit-webhook como un solo archivo cada una, para
# pegarlas en el panel de Supabase (Edge Functions > Deploy a new function >
# Via Editor) sin dar un token de cuenta. Mismo código que en el repositorio.
# Uso: supabase/scripts/bundle_didit.sh <carpeta de salida>
set -euo pipefail
cd "$(dirname "$0")/../functions"
out="${1:?carpeta de salida}"
mkdir -p "$out"
grep -qx 'export const LIVE_ENABLED = false;' _shared/didit.ts || { echo "El modo real no está cerrado" >&2; exit 1; }
for f in identity-check didit-webhook; do
  {
    echo "// $f — generado por supabase/scripts/bundle_didit.sh desde el repositorio. No editar aquí."
    cat _shared/didit.ts
    echo
    grep -v "^import .*_shared/didit.ts';$" "$f/index.ts"
  } > "$out/$f.ts"
done
(cd "$out" && sha256sum identity-check.ts didit-webhook.ts)
