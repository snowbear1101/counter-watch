#!/bin/sh
# Runs the database API tests against a throwaway database on a local PostgreSQL (14+).
# Uses the usual libpq settings (PGHOST, PGPORT, PGUSER...); the user must be able to create
# databases and roles. Nothing is installed: just psql and a server.
#
#   tests/run.sh               run every tests/test_*.sql and tests/test_*.sh (which get PGDATABASE)
#   tests/run.sh test_auth.sql run one file
set -eu
cd "$(dirname "$0")"
db="cw_test_$$"
export PGOPTIONS="-c track_functions=pl -c client_min_messages=warning"
q() { psql -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"; }

createdb "$db"
trap 'dropdb --if-exists "$db"' EXIT

# What Supabase provides that schema.sql relies on.
q -c "create schema extensions;" \
  -c "do \$\$ begin
        if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
        if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
      end \$\$;"
q -o /dev/null -f ../schema.sql
q -f lib.sql

status=0
files=${*:-$(ls test_*.sql test_*.sh)}
for f in $files; do
  printf '%s ... ' "$f"
  case $f in
    *.sh) run() { PGDATABASE="$db" sh "$f" 2>&1; } ;;
    *)    run() { q -o /dev/null -f "$f" 2>&1; } ;;
  esac
  if ! out=$(run); then echo ERROR; status=1
  elif printf "%s" "$out" | grep -q "FAIL:"; then echo FAILED
  else echo ok; fi
  if [ -n "$out" ]; then echo "$out"; fi
done

fails=$(q -At -c "select count(*) from t.failures")
if [ "$fails" -ne 0 ]; then
  echo; echo "$fails failed assertion(s):"
  q -c "select label, detail from t.failures"
  status=1
fi

q -f coverage.sql
exit $status
