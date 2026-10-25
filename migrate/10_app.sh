#!/usr/bin/env bash
# Before the migration: node 1 is an ordinary PostgreSQL server with the
# application's database, and the application is writing to it.
#
#   mig_seq    (node uuid, seq) - each node's writer adds its rows 1, 2, 3 ...
#   mig_local  rows the application wrote once; not put on the cluster, so a new
#              node has them from the dump alone
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

say "-- $(now) node 1: the application's database"
q 1 postgres <<SQL >/dev/null || bad "node 1: the role and the database"
create role $MIG_USER login password '$MIG_PASS';
create database $MIG_DB owner $MIG_USER;
SQL
q 1 <<SQL >/dev/null || bad "node 1: the tables"
set role $MIG_USER;
create table mig_seq (node uuid not null, seq int not null, at timestamptz not null default now(),
    primary key (node, seq));
create table mig_local (id int primary key, v text not null);
insert into mig_local select g, md5(g::text) from generate_series(1, $MIG_LOCAL_ROWS) g;
SQL
check "node 1: mig_local holds the application's $MIG_LOCAL_ROWS rows" "$MIG_LOCAL_ROWS" \
	"$(qc 1 "select count(*) from mig_local")"

writer_start 1 || bad "node 1: the writer did not start"
first() { [ "$(qc 1 "select count(*) from mig_seq")" -ge 5 ] 2>/dev/null; }
if wait_for 30 first; then
	ok "node 1: the application writes to plain PostgreSQL ($(writer_counts 1))"
else
	bad "node 1: no rows from the writer within 30 s ($(writer_counts 1))"
fi
finish
