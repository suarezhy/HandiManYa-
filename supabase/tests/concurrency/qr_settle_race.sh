#!/usr/bin/env bash
# Carrera real: llegan dos avisos de pago distintos para la misma recarga por
# QR al mismo tiempo, desde dos conexiones, N veces. Se acredita exactamente
# una vez por recarga. Solo local: copia la base de run_local.sh.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/qr_settle_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race_qr"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

P=00000000-0000-0000-0000-000009aa0f02
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
insert into auth.users (id, email, raw_user_meta_data) values ('$P', 'qrace-p@test.bo', '{"full_name": "Carrera QR"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, test_fixture)
values ('$P', 'Carrera QR', 1, 1, 'approved', true);
insert into public.wallets (professional_id) values ('$P') on conflict do nothing;
insert into public.qr_recharges (professional_id, amount, provider, simulated, provider_ref, expires_at)
select '$P', 20, 'dev_mock', true, 'MOCK-race-' || i, now() + interval '1 hour' from generate_series(1, $N) i;
SQL

settle() { # referencia, evento
  psql -X -At -d "$DB" -c "select public.hmy_qr_settle('dev_mock', '$1', '$2', 20, 'BOB', now())" 2>&1 | head -1
}
ok=0; bad=0
for i in $(seq 1 "$N"); do
  a=$(mktemp); b=$(mktemp)
  settle "MOCK-race-$i" "evt-a-$i" > "$a" & settle "MOCK-race-$i" "evt-b-$i" > "$b" & wait
  r="$(cat "$a") $(cat "$b")"; rm -f "$a" "$b"
  case "$r" in
    "credited already_credited"|"already_credited credited") ok=$((ok + 1)) ;;
    *) bad=$((bad + 1)); echo "recarga $i: $r" ;;
  esac
done
w=$(psql -X -At -d "$DB" -c "select available from public.wallets where professional_id = '$P'")
n=$(psql -X -At -d "$DB" -c "select count(*) from public.wallet_ledger where professional_id = '$P' and entry_type = 'topup'")
echo "Carreras: $N · una acreditación: $ok · otro resultado: $bad · saldo Bs $w · entradas $n"
[ "$bad" = 0 ] && [ "$ok" = "$N" ] && [ "$n" = "$N" ] && [ "$w" = "$((20 * N)).00" ] && echo "CARRERA DE AVISOS QR: PASÓ" || { echo "CARRERA DE AVISOS QR: FALLÓ"; exit 1; }
