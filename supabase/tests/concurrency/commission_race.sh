#!/usr/bin/env bash
# Carrera real por el mismo saldo: un profesional con Bs 15 acepta dos trabajos
# de Bs 100 (Bs 10 de comisión cada uno) al mismo tiempo, desde dos conexiones,
# N veces. Desde 0066 nada se reserva, pero el saldo tiene que cubrir todas las
# comisiones por cobrar: debe quedar exactamente uno acordado, el otro con
# HMY_INSUFFICIENT_BALANCE, y la billetera intacta en 15 / 0, nunca negativa.
# Solo local: copia la base de run_local.sh.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/commission_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race_wallet"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

C=00000000-0000-0000-0000-000009a9e001
P=00000000-0000-0000-0000-000009a9e002
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
update public.commission_rules set is_active = (name = 'Comisión general (10 %)');
insert into auth.users (id, email, raw_user_meta_data) values
  ('$C', 'wrace-c@test.bo', '{"full_name": "Cliente Saldo"}'),
  ('$P', 'wrace-p@test.bo', '{"full_name": "Profesional Saldo"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('$P', 'Profesional Saldo', 1, 1, 'approved', true);
insert into public.wallets (professional_id) values ('$P') on conflict do nothing;
-- Pedidos programados dirigidos a él, dos por carrera, sin los límites de uso.
set session_replication_role = replica;
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status,
                             scheduled_start, scheduled_end, response_deadline)
select ('00000000-0000-0000-0000-' || lpad(to_hex(i), 12, '0'))::uuid, '$C', '$P', 1, 1, 'scheduled', 'Saldo ' || i,
       'requested', date_trunc('hour', now()) + make_interval(days => 2, hours => 3 * i),
       date_trunc('hour', now()) + make_interval(days => 2, hours => 3 * i + 2), now() + interval '1 day'
from generate_series(1, 2 * $N) i;
set session_replication_role = origin;
SQL

agree() { # pedido
  psql -X -At -d "$DB" -c "select set_config('request.jwt.claims', json_build_object('sub', '$P', 'role', 'authenticated')::text, false) is null;" \
       -c "set role authenticated" -c "select test.agree('$1', 100)" 2>&1 | grep -oE 'confirmed|HMY_[A-Z_]+|ERROR: .*' | sed 's/^ERROR: *\(HMY_\)/\1/' | head -1
}
ok=0; bad=0
for i in $(seq 1 "$N"); do
  a_id="00000000-0000-0000-0000-$(printf '%012x' $((2 * i - 1)))"
  b_id="00000000-0000-0000-0000-$(printf '%012x' $((2 * i)))"
  # Cada carrera empieza con Bs 15 y sin trabajos por cobrar (los de la carrera
  # anterior se cierran).
  psql -X -q -d "$DB" -c "set session_replication_role = replica; update public.wallets set available = 15, reserved = 0 where professional_id = '$P'; update public.bookings set status = 'cancelled' where professional_id = '$P' and status = 'confirmed'"
  a=$(mktemp); b=$(mktemp)
  agree "$a_id" > "$a" & agree "$b_id" > "$b" & wait
  r="$(cat "$a") $(cat "$b")"; rm -f "$a" "$b"
  w=$(psql -X -At -d "$DB" -c "select available || '/' || reserved from public.wallets where professional_id = '$P'")
  n=$(psql -X -At -d "$DB" -c "select count(*) from public.bookings where id in ('$a_id', '$b_id') and status = 'confirmed'")
  case "$r" in
    "confirmed HMY_INSUFFICIENT_BALANCE"|"HMY_INSUFFICIENT_BALANCE confirmed")
      if [ "$w" = "15.00/0.00" ] && [ "$n" = 1 ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "carrera $i: $r · billetera $w · acordados $n"; fi ;;
    *) bad=$((bad + 1)); echo "carrera $i: $r · billetera $w · acordados $n" ;;
  esac
done
neg=$(psql -X -At -d "$DB" -c "select count(*) from public.wallets where available < 0 or reserved < 0")
echo "Carreras: $N · uno acordado y el otro sin saldo: $ok · otro resultado: $bad · billeteras negativas: $neg"
[ "$bad" = 0 ] && [ "$ok" = "$N" ] && [ "$neg" = 0 ] && echo "CARRERA POR EL SALDO: PASÓ" || { echo "CARRERA POR EL SALDO: FALLÓ"; exit 1; }
