#!/usr/bin/env bash
# PostgreSQL side of the append-and-commit benchmark (see src/bin/benchmark/AppendCommit.hs).
# Starts a throwaway cluster, appends COUNT rows one commit at a time, restarts, and queries.
#
#   scripts/bench-append-postgres.sh [COUNT] [WORKDIR]
#
# Set SYNC=off to compare against MinimalPersistence (no fsync on commit).
set -euo pipefail

COUNT="${1:-1000}"
WORKDIR="${2:-$(mktemp -d)}"
PORT="${PGPORT:-54329}"
SYNC="${SYNC:-on}"
PGDATA="$WORKDIR/pgdata"
export PGHOST=127.0.0.1 PGPORT="$PORT" PGDATABASE=postgres PGUSER=bench

now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed_ms() { perl -e 'printf "%.3f", ($ARGV[1]-$ARGV[0])*1000' "$1" "$2"; }

start() {
  pg_ctl -D "$PGDATA" -w -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c synchronous_commit=$SYNC" -l "$WORKDIR/pg.log" start >/dev/null
}
stop() { pg_ctl -D "$PGDATA" -w -m fast stop >/dev/null; }

rm -rf "$PGDATA"
initdb -D "$PGDATA" -U bench --no-locale -E UTF8 >/dev/null
start
trap 'stop || true' EXIT

psql -q -c "create table event (id bigint primary key, kind text not null, payload text not null)" \
        -c "create sequence event_id"

cat > "$WORKDIR/append.sql" <<'SQL'
insert into event
select i, (array['created','renamed','moved','archived'])[1 + i % 4],
       repeat('0123456789abcdefghijklmno', 4) || i
from nextval('event_id') as i;
SQL

echo "synchronous_commit=$SYNC"
pgbench -n -c 1 -j 1 -t "$COUNT" -f "$WORKDIR/append.sql" | grep -E "latency average|tps"
du -sh "$PGDATA" | awk '{print "disk: " $1}'

stop
t0=$(now); start; psql -q -At -c "select 1" >/dev/null; t1=$(now)
echo "open (server start + first query): $(elapsed_ms "$t0" "$t1") ms"

cat > "$WORKDIR/lookup.sql" <<SQL
\set k random(1, $COUNT)
select * from event where id = :k;
SQL
echo "select * from event;" > "$WORKDIR/scan.sql"
echo "select * from event where kind = 'moved';" > "$WORKDIR/filter.sql"

echo -n "scan: ";           pgbench -n -c 1 -t 20  -f "$WORKDIR/scan.sql"   | grep "latency average"
echo -n "lookup by id: ";   pgbench -n -c 1 -t 1000 -f "$WORKDIR/lookup.sql" | grep "latency average"
echo -n "filter by kind: "; pgbench -n -c 1 -t 20  -f "$WORKDIR/filter.sql" | grep "latency average"

# update and delete single rows by primary key, one commit each
cat > "$WORKDIR/update.sql" <<SQL
\set k random(1, $COUNT)
update event set payload = 'updated' where id = :k;
SQL
cat > "$WORKDIR/delete.sql" <<SQL
\set k random(1, $COUNT)
delete from event where id = :k;
SQL
echo -n "update by id: "; pgbench -n -c 1 -t 1000 -f "$WORKDIR/update.sql" | grep "latency average"
echo -n "delete by id: "; pgbench -n -c 1 -t 1000 -f "$WORKDIR/delete.sql" | grep "latency average"
