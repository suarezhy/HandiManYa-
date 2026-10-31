#!/usr/bin/env bash
# Carreras reales de 0067, desde dos conexiones, N veces:
#  a) el profesional cancela dos veces a la vez un trabajo aceptado: una sola
#     penalización de Bs 3 (clave cancel-penalty:<pedido>);
#  b) en un trabajo de Bs 100 el profesional contraoferta Bs 130 y el cliente
#     Bs 120 al mismo tiempo: queda una sola propuesta abierta y el precio
#     acordado sigue en Bs 100;
#  c) el que responde acepta esa propuesta dos veces a la vez: se acepta una
#     vez y el total queda igual a la propuesta (nunca sumado).
# Solo local: copia la base de run_local.sh.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/counteroffer_cancel_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race_counter"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

C=00000000-0000-0000-0000-000009aa5001
P=00000000-0000-0000-0000-000009aa5002
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');
insert into auth.users (id, email, raw_user_meta_data) values
  ('$C', 'crace-c@test.bo', '{"full_name": "Cliente Carrera"}'),
  ('$P', 'crace-p@test.bo', '{"full_name": "Profesional Carrera"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('$P', 'Profesional Carrera', 1, 1, 'approved', true);
insert into public.wallets (professional_id) values ('$P') on conflict do nothing;
-- Trabajos confirmados de Bs 100 con la regla del 10 %: 1..N para cancelar,
-- N+1..2N para la contraoferta.
set session_replication_role = replica;
update public.wallets set available = 1000 where professional_id = '$P';
insert into public.bookings (id, code, customer_id, professional_id, category_id, city_id, mode, description, status,
                             agreed_amount, agreed_kind, agreed_at, quote_amount, commission_rule_id,
                             scheduled_start, scheduled_end)
select ('00000000-0000-0000-0000-' || lpad(to_hex(i), 12, '0'))::uuid, 'CR' || lpad(i::text, 6, '0'), '$C', '$P', 1, 1,
       'scheduled', 'Carrera ' || i, 'confirmed', 100, 'service', now(), 100,
       (select id from public.commission_rules where name = 'Comisión general (10 %)'),
       date_trunc('hour', now()) + make_interval(days => 2, hours => 3 * i),
       date_trunc('hour', now()) + make_interval(days => 2, hours => 3 * i + 2)
from generate_series(1, 2 * $N) i;
set session_replication_role = origin;
SQL

as() { # usuario, sql
  psql -X -At -d "$DB" -c "select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, false) is null;" \
       -c "set role authenticated" -c "$2" 2>&1 | grep -oE 'HMY_[A-Z_]+|ERROR: .*' | head -1 || true
}
q() { psql -X -At -d "$DB" -c "$1"; }
ok=0; bad=0
for i in $(seq 1 "$N"); do
  x="00000000-0000-0000-0000-$(printf '%012x' "$i")"
  y="00000000-0000-0000-0000-$(printf '%012x' $((N + i)))"
  # a) Doble cancelación.
  as "$P" "select public.cancel_booking('$x', '')" > /dev/null & as "$P" "select public.cancel_booking('$x', '')" > /dev/null & wait
  pen=$(q "select count(*) || '/' || coalesce((select cancel_penalty::text from public.bookings where id = '$x'), '-')
           from public.wallet_ledger where booking_id = '$x' and entry_type = 'penalty'")
  # b) Dos contraofertas a la vez.
  as "$P" "select public.propose_price('$y', 130, 'total')" > /dev/null & as "$C" "select public.propose_price('$y', 120, 'total')" > /dev/null & wait
  open=$(q "select count(*) from public.price_offers where booking_id = '$y' and status = 'open'")
  agreed=$(q "select agreed_amount + extras_amount from public.bookings where id = '$y'")
  o=$(q "select id || ' ' || author_role || ' ' || amount from public.price_offers where booking_id = '$y' and status = 'open'")
  set -- $o
  who=$([ "${2:-}" = customer ] && echo "$P" || echo "$C")
  # c) El otro acepta dos veces a la vez.
  as "$who" "select public.accept_price_offer(${1:-0})" > /dev/null & as "$who" "select public.accept_price_offer(${1:-0})" > /dev/null & wait
  total=$(q "select agreed_amount + extras_amount from public.bookings where id = '$y'")
  acc=$(q "select count(*) from public.admin_audit_log where action = 'price.change_accepted' and target_id = '$y'")
  if [ "$pen" = "1/3.00" ] && [ "$open" = 1 ] && [ "$agreed" = "100.00" ] && [ "$total" = "${3:-x}" ] && [ "$acc" = 1 ]; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1)); echo "carrera $i: penalización $pen · abiertas $open · antes $agreed · total $total (propuesta ${3:-}) · aceptadas $acc"
  fi
done
w=$(q "select available from public.wallets where professional_id = '$P'")
exp=$(q "select (1000 - 3 * $N)::numeric(12,2)")
neg=$(q "select count(*) from public.wallets where available < 0 or reserved < 0")
echo "Carreras: $N · correctas: $ok · otro resultado: $bad · saldo $w (esperado $exp) · billeteras negativas: $neg"
[ "$bad" = 0 ] && [ "$ok" = "$N" ] && [ "$neg" = 0 ] && [ "$w" = "$exp" ] && echo "CARRERAS DE CONTRAOFERTA Y CANCELACIÓN: PASARON" || { echo "CARRERAS DE CONTRAOFERTA Y CANCELACIÓN: FALLARON"; exit 1; }
