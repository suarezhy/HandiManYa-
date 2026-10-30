#!/usr/bin/env bash
# Carrera real por el cobro de la comisión (0066): el cliente toca "Ya pagué"
# dos veces al mismo tiempo (doble toque o reintento), desde dos conexiones, en
# un trabajo terminado de Bs 100, N veces. Debe quedar un solo cobro de Bs 10
# por trabajo (clave commission:<pedido>) y la billetera nunca negativa.
# Solo local: copia la base de run_local.sh.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/payment_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race_payment"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

C=00000000-0000-0000-0000-000009aa3001
P=00000000-0000-0000-0000-000009aa3002
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');
insert into auth.users (id, email, raw_user_meta_data) values
  ('$C', 'prace-c@test.bo', '{"full_name": "Cliente Pago"}'),
  ('$P', 'prace-p@test.bo', '{"full_name": "Profesional Pago"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('$P', 'Profesional Pago', 1, 1, 'approved', true);
insert into public.wallets (professional_id) values ('$P') on conflict do nothing;
-- Trabajos terminados de Bs 100 con la regla del 10 %, uno por carrera.
set session_replication_role = replica;
update public.wallets set available = 1000 where professional_id = '$P';
insert into public.bookings (id, code, customer_id, professional_id, category_id, city_id, mode, description, status,
                             agreed_amount, agreed_kind, agreed_at, final_amount, quote_amount, finished_at,
                             commission_rule_id)
select ('00000000-0000-0000-0000-' || lpad(to_hex(i), 12, '0'))::uuid, 'PAY' || lpad(i::text, 5, '0'), '$C', '$P', 1, 1,
       'now', 'Pago ' || i, 'work_finished', 100, 'service', now(), 100, 100, now(),
       (select id from public.commission_rules where name = 'Comisión general (10 %)')
from generate_series(1, $N) i;
set session_replication_role = origin;
SQL

paid() { # pedido
  psql -X -At -d "$DB" -c "select set_config('request.jwt.claims', json_build_object('sub', '$C', 'role', 'authenticated')::text, false) is null;" \
       -c "set role authenticated" -c "select public.acknowledge_payment('$1', 'cash')" 2>&1 | grep -oE 'HMY_[A-Z_]+|ERROR: .*' | head -1 || true
}
ok=0; bad=0
for i in $(seq 1 "$N"); do
  id="00000000-0000-0000-0000-$(printf '%012x' "$i")"
  a=$(mktemp); b=$(mktemp)
  paid "$id" > "$a" & paid "$id" > "$b" & wait
  r="$(cat "$a")$(cat "$b")"; rm -f "$a" "$b"
  n=$(psql -X -At -d "$DB" -c "select count(*) from public.wallet_ledger where booking_id = '$id'")
  c=$(psql -X -At -d "$DB" -c "select commission_captured from public.bookings where id = '$id'")
  if [ -z "$r" ] && [ "$n" = 1 ] && [ "$c" = "10.00" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "carrera $i: errores '$r' · movimientos $n · cobrado $c"; fi
done
w=$(psql -X -At -d "$DB" -c "select available from public.wallets where professional_id = '$P'")
neg=$(psql -X -At -d "$DB" -c "select count(*) from public.wallets where available < 0 or reserved < 0")
exp=$(psql -X -At -d "$DB" -c "select (1000 - 10 * $N)::numeric(12,2)")
echo "Carreras: $N · un solo cobro: $ok · otro resultado: $bad · saldo $w (esperado $exp) · billeteras negativas: $neg"
[ "$bad" = 0 ] && [ "$ok" = "$N" ] && [ "$neg" = 0 ] && [ "$w" = "$exp" ] && echo "CARRERA POR EL COBRO: PASÓ" || { echo "CARRERA POR EL COBRO: FALLÓ"; exit 1; }
