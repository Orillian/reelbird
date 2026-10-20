#!/bin/sh
# Local Postgres 18 for development, kept inside cloud/.pgdata on port 54329.
# Usage: scripts/db.sh start | stop | status | reset
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
cd "$(dirname "$0")/.."
PG=$(brew --prefix postgresql@18 2>/dev/null)/bin
[ -x "$PG/pg_ctl" ] || PG=$(dirname "$(command -v pg_ctl)")
DATA=.pgdata PORT=54329
case "$1" in
  start)
    if [ ! -d "$DATA" ]; then
      "$PG/initdb" -D "$DATA" -U postgres --auth=trust -E UTF8 >/dev/null
    fi
    "$PG/pg_ctl" -D "$DATA" -o "-p $PORT -k /tmp -c listen_addresses=127.0.0.1" -l "$DATA/server.log" -w start >/dev/null
    for db in reelbird_cloud reelbird_cloud_test; do
      "$PG/psql" -h 127.0.0.1 -p $PORT -U postgres -tAc "select 1 from pg_database where datname='$db'" | grep -q 1 \
        || "$PG/createdb" -h 127.0.0.1 -p $PORT -U postgres "$db"
    done
    echo "postgres://postgres@127.0.0.1:$PORT/reelbird_cloud" ;;
  stop) "$PG/pg_ctl" -D "$DATA" -w stop >/dev/null && echo stopped ;;
  status) "$PG/pg_ctl" -D "$DATA" status ;;
  reset) "$PG/pg_ctl" -D "$DATA" -w stop >/dev/null 2>&1 || true; rm -rf "$DATA"; "$0" start ;;
  *) echo "usage: $0 start|stop|status|reset" >&2; exit 2 ;;
esac
