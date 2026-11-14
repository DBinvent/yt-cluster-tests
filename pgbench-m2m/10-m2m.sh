#!/usr/bin/env bash
# [pgbench-m2m] A node's pgbench tables, made and filled as `pgbench -i` would - alike on every
# node, before the extension is in their database (yt-node setup puts it there after the init
# scripts), so the cluster starts with one copy and no load of 100k rows goes through it.
#   M2M_LAYOUT=db      a database per node: bench1 .. bench<M2M_NODES>, the tables in public
#   M2M_LAYOUT=schema  one database `bench`, a schema per node: n1 .. n<M2M_NODES>
#   M2M_SCALE          pgbench's scale (default 1)
set -euo pipefail
scale="${M2M_SCALE:-1}"; n="${M2M_NODES:-6}"
tables() { # tables <schema>
	cat <<SQL
CREATE TABLE $1.pgbench_branches (bid int PRIMARY KEY, bbalance int, filler char(88));
CREATE TABLE $1.pgbench_tellers (tid int PRIMARY KEY, bid int, tbalance int, filler char(84));
CREATE TABLE $1.pgbench_accounts (aid int PRIMARY KEY, bid int, abalance int, filler char(84));
CREATE TABLE $1.pgbench_history (hid bigserial PRIMARY KEY, tid int, bid int, aid int, delta int, mtime timestamp, filler char(22));
INSERT INTO $1.pgbench_branches SELECT b, 0, '' FROM generate_series(1, $scale) b;
INSERT INTO $1.pgbench_tellers SELECT t, (t - 1) / 10 + 1, 0, '' FROM generate_series(1, 10 * $scale) t;
INSERT INTO $1.pgbench_accounts SELECT a, (a - 1) / 100000 + 1, 0, '' FROM generate_series(1, 100000 * $scale) a;
SQL
}
{
	if [ "${M2M_LAYOUT:-db}" = db ]; then
		for i in $(seq 1 "$n"); do echo "CREATE DATABASE bench$i;"; done
		for i in $(seq 1 "$n"); do echo "\\c bench$i"; tables public; done
	else
		echo "CREATE DATABASE bench;"; echo "\\c bench"
		for i in $(seq 1 "$n"); do echo "CREATE SCHEMA n$i;"; tables "n$i"; done
	fi
} | psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres -q
