#!/usr/bin/env bash
# Carrera real: un mismo profesional acepta al mismo tiempo dos solicitudes
# programadas que se cruzan en horario, desde dos conexiones, N veces. Debe
# quedarse con una sola y la otra recibir HMY_SLOT_TAKEN. Solo local: copia la
# base de run_local.sh. Sin el bloqueo de 0060 la base igual impide los dos
# trabajos (bookings_no_overlap), pero una de las dos aceptaciones fallaba con
# un "deadlock" en vez de HMY_SLOT_TAKEN.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/scheduled_overlap_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race_sched"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

C=00000000-0000-0000-0000-000009a93001
P=00000000-0000-0000-0000-000009a93002
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
insert into auth.users (id, email, raw_user_meta_data) values
  ('$C', 'race-sc@test.bo', '{"full_name": "Cliente Horario"}'),
  ('$P', 'race-sp@test.bo', '{"full_name": "Profesional Horario"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
values ('$P', 'Horario', 1, 1, 'approved', true);
insert into public.wallets (professional_id, available) values ('$P', 100000)
  on conflict (professional_id) do update set available = excluded.available;
-- Dos solicitudes por ronda, a la misma hora (rondas separadas por un día).
set session_replication_role = replica;
insert into public.bookings (id, customer_id, category_id, city_id, mode, description, status, response_deadline,
                             scheduled_start, scheduled_end)
select ('00000000-0000-0000-0000-' || lpad(to_hex(i * 10 + k), 12, '0'))::uuid, '$C', 1, 1, 'scheduled',
       'Horario ' || i || '-' || k, 'awaiting_response', now() + interval '1 day',
       date_trunc('hour', now()) + make_interval(days => i + 1),
       date_trunc('hour', now()) + make_interval(days => i + 1, hours => 2)
from generate_series(1, $N) i, generate_series(1, 2) k;
insert into public.booking_offers (booking_id, professional_id)
select b.id, '$P' from public.bookings b where b.customer_id = '$C';
set session_replication_role = origin;
SQL

claim() { # pedido
  psql -X -At -d "$DB" -c "select set_config('request.jwt.claims', json_build_object('sub', '$P', 'role', 'authenticated')::text, false) is null;" \
       -c "set role authenticated" -c "select test.agree('$1')" 2>&1 | grep -oE "confirmed|HMY_[A-Z_]+" | head -1
}
ok=0; other=0
for i in $(seq 1 "$N"); do
  a=$(mktemp); b=$(mktemp)
  claim "00000000-0000-0000-0000-$(printf '%012x' $((i * 10 + 1)))" > "$a" &
  claim "00000000-0000-0000-0000-$(printf '%012x' $((i * 10 + 2)))" > "$b" & wait
  r="$(cat "$a") $(cat "$b")"; rm -f "$a" "$b"
  case "$r" in
    "confirmed HMY_SLOT_TAKEN"|"HMY_SLOT_TAKEN confirmed") ok=$((ok + 1)) ;;
    *) other=$((other + 1)); echo "ronda $i: $r" ;;
  esac
done
double=$(psql -X -At -d "$DB" -c "select count(*) from (select scheduled_start from public.bookings where professional_id = '$P' and status = 'confirmed' group by scheduled_start having count(*) > 1) x")
echo "Rondas: $N · una sola aceptada: $ok · otro resultado: $other · horarios con dos trabajos: $double"
[ "$other" = 0 ] && [ "$ok" = "$N" ] && [ "$double" = 0 ] && echo "CARRERA DE HORARIO: PASÓ" || { echo "CARRERA DE HORARIO: FALLÓ"; exit 1; }
