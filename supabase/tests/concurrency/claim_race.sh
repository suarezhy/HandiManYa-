#!/usr/bin/env bash
# Carrera real: dos profesionales aceptan el mismo pedido ¡Ya! al mismo tiempo,
# desde dos conexiones distintas, N veces. Debe ganar exactamente uno por pedido
# y el otro recibir HMY_ALREADY_TAKEN. Solo local: copia la base de run_local.sh.
#
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/concurrency/claim_race.sh [N]
set -euo pipefail
N="${1:-20}"
SRC="${HMY_TEST_DB:-hmy_test}"
DB="hmy_race"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB template $SRC"
trap 'psql -X -q -d postgres -c "drop database if exists $DB"' EXIT

C=00000000-0000-0000-0000-000009a99001
P1=00000000-0000-0000-0000-000009a99002
P2=00000000-0000-0000-0000-000009a99003
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
insert into auth.users (id, email, raw_user_meta_data) values
  ('$C', 'race-c@test.bo', '{"full_name": "Cliente Carrera"}'),
  ('$P1', 'race-p1@test.bo', '{"full_name": "Carrera Uno"}'),
  ('$P2', 'race-p2@test.bo', '{"full_name": "Carrera Dos"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status, is_available)
select u, 'Carrera', 1, 1, 'approved', true from unnest(array['$P1', '$P2']::uuid[]) u;
insert into public.wallets (professional_id, available) values ('$P1', 100000), ('$P2', 100000)
  on conflict (professional_id) do update set available = excluded.available;
-- Datos de la prueba sin los límites de uso (son 30 pedidos de un mismo cliente).
set session_replication_role = replica;
insert into public.bookings (id, customer_id, category_id, city_id, mode, description, status, response_deadline)
select ('00000000-0000-0000-0000-' || lpad(to_hex(i), 12, '0'))::uuid, '$C', 1, 1, 'now', 'Carrera ' || i,
       'awaiting_response', now() + interval '10 minutes'
from generate_series(1, $N) i;
insert into public.booking_offers (booking_id, professional_id)
select b.id, p from public.bookings b, unnest(array['$P1', '$P2']::uuid[]) p where b.customer_id = '$C';
set session_replication_role = origin;
SQL

claim() { # profesional, pedido
  psql -X -At -d "$DB" -c "select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, false) is null;" \
       -c "set role authenticated" -c "select test.agree('$2')" 2>&1 | grep -oE 'confirmed|HMY_[A-Z_]+' | head -1
}
wins=0; lost=0; other=0
for i in $(seq 1 "$N"); do
  id="00000000-0000-0000-0000-$(printf '%012x' "$i")"
  a=$(mktemp); b=$(mktemp)
  claim "$P1" "$id" > "$a" & claim "$P2" "$id" > "$b" & wait
  r="$(cat "$a") $(cat "$b")"; rm -f "$a" "$b"
  # El ganador termina ese trabajo para quedar libre para la próxima carrera.
  psql -X -q -d "$DB" -c "set session_replication_role = replica; update public.bookings set status = 'work_finished' where id = '$id' and status = 'confirmed'"
  case "$r" in
    "confirmed HMY_ALREADY_TAKEN"|"HMY_ALREADY_TAKEN confirmed") wins=$((wins + 1)); lost=$((lost + 1)) ;;
    *) other=$((other + 1)); echo "pedido $i: $r" ;;
  esac
done
assigned=$(psql -X -At -d "$DB" -c "select count(*) from public.bookings where customer_id = '$C' and status = 'work_finished' and professional_id is not null")
accepted=$(psql -X -At -d "$DB" -c "select count(*) from public.booking_offers o join public.bookings b on b.id = o.booking_id where b.customer_id = '$C' and o.status = 'accepted'")
echo "Carreras: $N · un ganador: $wins · el otro rechazado: $lost · otro resultado: $other · asignados: $assigned · ofertas aceptadas: $accepted"
[ "$other" = 0 ] && [ "$wins" = "$N" ] && [ "$assigned" = "$N" ] && [ "$accepted" = "$N" ] && echo "CARRERA DE ACEPTACIÓN: PASÓ" || { echo "CARRERA DE ACEPTACIÓN: FALLÓ"; exit 1; }
