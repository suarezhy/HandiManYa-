#!/usr/bin/env bash
# Dos pedidos a la vez enlazan la misma sesión de Didit (0019): el primero la
# guarda y el segundo la reutiliza, sin error ni sesión duplicada.
# Solo contra una base local creada por run_local.sh (HMY_TEST_DB, por defecto hmy_test).
set -euo pipefail
DB="${HMY_TEST_DB:-hmy_test}"
P="psql -X -At -v ON_ERROR_STOP=1 -d $DB"
PRO=00000000-0000-0000-0000-00000000cc01
$P -q -c "insert into auth.users (id, email, raw_user_meta_data) values ('$PRO', 'cc@test.bo', '{\"full_name\":\"C C\",\"city_id\":\"1\"}') on conflict do nothing;" \
      -c "insert into public.professional_profiles (user_id) values ('$PRO') on conflict do nothing;"
c1=$($P -c "insert into public.identity_checks (professional_id, sandbox) values ('$PRO', true) returning id" | head -1)
c2=$($P -c "insert into public.identity_checks (professional_id, sandbox) values ('$PRO', true) returning id" | head -1)
out=$(mktemp)
$P -c "begin; select public.hmy_identity_attach($c1, 'cc-sid', 'https://verify.didit.me/s/a'); select pg_sleep(2); commit;" > "$out" &
sleep 0.5
second=$($P -c "select public.hmy_identity_attach($c2, 'cc-sid', 'https://verify.didit.me/s/b')" | head -1)
wait
first=$(sed -n 2p "$out")
rows=$($P -c "select count(*) from public.identity_checks where session_id = 'cc-sid'")
left=$($P -c "select count(*) from public.identity_checks where id = $c2")
$P -q -c "delete from public.identity_checks where professional_id = '$PRO'; delete from public.professional_profiles where user_id = '$PRO'; delete from auth.users where id = '$PRO';"
echo "primero: $first"
echo "segundo: $second"
[[ "$first" == *'"saved": true'* && "$first" == *'"reused": false'* ]] || { echo "FALLA: el primero no guardó"; exit 1; }
[[ "$second" == *'"saved": true'* && "$second" == *'"reused": true'* ]] || { echo "FALLA: el segundo no reutilizó"; exit 1; }
[[ "$rows" == 1 && "$left" == 0 ]] || { echo "FALLA: filas=$rows intento vacío=$left"; exit 1; }
echo "PASA: una sola sesión, el segundo pedido la reutiliza"
