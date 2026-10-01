#!/bin/sh
# Things that only go wrong when two requests arrive at once. Each case holds one call's
# transaction open for a moment while a second call comes in from another connection.
set -eu
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

tok=$(q -c "select t.reset()" -c "select t.counter('North')" -o /dev/null && q -c "select t.user('amy')")

# Two check-ins at once (double tap, or phone and laptop): only one shift may open.
q -c "begin" -c "select cw_checkin('$tok', 1, 1.3, 103.8, 5)" -c "select pg_sleep(1)" -c "commit" -o /dev/null &
first=$!
second=$(q -c "select pg_sleep(0.3)" -o /dev/null && q -c "select cw_checkin('$tok', 1, 1.3, 103.8, 5)" 2>&1 >/dev/null || true)
wait $first
q -o /dev/null -c "select t.eq((select count(*) from cw_shifts where end_at is null), 1::bigint, 'race: concurrent check-ins open one shift')"
q -o /dev/null -c "select t.ok(\$\$$second\$\$ like '%already checked in at North%', 'race: second check-in is refused')"
