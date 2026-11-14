#!/usr/bin/env bash
# Shared settings and helpers of the migration test. Source, do not execute.
set -uo pipefail

MIG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$MIG_HERE/.." && pwd)"
# Settings: yt-cluster-tests/.env (not committed, see env.example); the environment wins.
if [ -f "$TESTS_ROOT/.env" ]; then
	_mig_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_mig_keep"; unset _mig_keep
fi

# The package under test: the pg18 deb (cargo deb --variant pg18), as the nightly builds it.
MIG_DEB="${MIG_DEB:-${YT_CLUSTER_DEB:-}}"
MIG_IMAGE="${MIG_IMAGE:-ubuntu:24.04}"
MIG_PG="${MIG_PG:-18}"
# containers: <prefix>-base (PostgreSQL installed, copied to the others) and the
# database servers <prefix>-1 .. -4; node 1 is the server the application ran on
MIG_PREFIX="${MIG_PREFIX:-ytmig}"
MIG_NODES="${MIG_NODES:-1 2 3 4}"
# the node added by `ytctl --copy` (35_copy.sh), a box of its own beside the others; empty:
# no copy
MIG_COPY="${MIG_COPY-5}"
# the hot rows the copy's source updates while the backup runs (35_copy.sh, hot.sh): row 0,
# which every update moves, and these, each moved by one update in turn
MIG_HOT_ROWS="${MIG_HOT_ROWS:-20000}"
# container NIC: bridge (lxdbr0) or macvlan, as lxc/env.sh. The containers fetch
# PostgreSQL from apt.postgresql.org: where Docker drops lxdbr0's forwarding, macvlan.
MIG_NIC="${MIG_NIC:-${YX_NIC:-bridge}}"
# the application: its database, its role (password auth over TCP, as an app connects)
MIG_DB="${MIG_DB:-appdb}"
MIG_USER="${MIG_USER:-app}"
MIG_PASS="${MIG_PASS:-app-test-only}"
# the load: on every node, rows 1 .. MIG_LOOP of that node, one a second
MIG_LOOP="${MIG_LOOP:-1500}"
MIG_PAUSE="${MIG_PAUSE:-1}"
# seconds a node gets to follow, and the nodes to agree at the end
MIG_WAIT="${MIG_WAIT:-300}"
# the application's table nobody writes after the start, kept off the cluster:
# it reaches a new node only in the dump
MIG_LOCAL_ROWS="${MIG_LOCAL_ROWS:-20000}"
PORT=7421
CFG=public.yt_config
# the namespace ytctl's --peers roster derives node uuids in: uuid5(ns, host)
YT_CLUSTER_NS=6a9f5c2e-1b3d-5e47-9a08-0bf99b3e0275
# what one run hands the next script: addresses, uuids, the cluster uuid, the dumps
RUN="$MIG_HERE/run"
mkdir -p "$RUN"

pass=0; fail=0
say()  { printf '%s\n' "$*"; }
now()  { date -u +%H:%M:%S; }
ok()   { say "  OK    $1"; pass=$((pass + 1)); }
bad()  { say "  FAIL  $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
# a script's last line, and its exit code: the number of failed checks
finish() { say "---- $(basename "$0"): $pass passed, $fail failed"; exit $(( fail > 0 )); }

cname() { echo "$MIG_PREFIX-$1"; }
xn() { local n="$1"; shift; lxc exec "$(cname "$n")" -- "$@"; }
# push_peers <n> <file>: node n's roster file in place, tried three times - an lxc exec
# LXD itself cut ("error receiving version packet ... connection reset by peer") left
# node 1 with none, and its ytctl, and so every node after it, failed (nightly of
# 2026-10-31)
push_peers() {
	local n="$1" f="$2" i
	for i in 1 2 3; do
		xn "$n" mkdir -p /etc/yt-cluster && lxc file push "$f" "$(cname "$n")/etc/yt-cluster/peers" >/dev/null \
			&& xn "$n" test -s /etc/yt-cluster/peers && return 0
		sleep 2
	done
	return 1
}
ip_of() { lxc list "^$1\$" -c4 --format csv | grep -oE '^[0-9.]+' | head -1; }
nip() { ip_of "$(cname "$1")"; }
node_uuid() { python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' "$YT_CLUSTER_NS" "$1"; }
# node n's address, and its yt.node as the test derived it from that (00_create.sh)
ipn() { cat "$RUN/ip.$1"; }
nuuid() { cat "$RUN/uuid.$1"; }

# psql as postgres on server n: q <n> [db] < sql; QT seconds before giving up (default 60)
q() {
	local n="$1" db="${2:-$MIG_DB}"
	lxc exec "$(cname "$n")" -- timeout "${QT:-60}" su postgres -c "psql -X -q -At -d $db -v ON_ERROR_STOP=1" 2>&1
}
qc() { printf '%s\n' "$2" | q "$1" "${3:-$MIG_DB}"; }

# this node's state as yt_info('E') says it: Leader, Good (a follower), Spare, ...
state_of() {
	qc "$1" "with e as (select * from json_to_recordset(yt_info('E')) as x(name text, value text, module text)) select split_part(v.value, ', ', 2) from e v, e s where s.name = 'self' and v.name = s.value" postgres 2>/dev/null
}
# the term node n is at, and the leader it knows (its uuid), from yt_info('E')
einfo() { qc "$1" "select value from json_to_recordset(yt_info('E')) as x(name text, value text, module text) where name = '$2'" postgres 2>/dev/null; }
term_of() { einfo "$1" term; }
is_state() { [ "$(state_of "$1")" = "$2" ]; }
# node n follows: Good, under the leader every member names
follows() { local l; l=$(leader) || return 1; is_state "$1" Good && [ "$(einfo "$1" leader)" = "$(nuuid "$l")" ]; }
leader() { local n; for n in $(members); do is_state "$n" Leader && { echo "$n"; return 0; }; done; return 1; }

# the nodes in the cluster so far, in the order they joined
members() { cat "$RUN/members" 2>/dev/null; }
add_member() { echo "$1" >> "$RUN/members"; }

# wait_for <seconds> <command...>: until the command succeeds. Its locals carry a
# prefix: bash scopes dynamically, and the command sees them - a `t` here was the
# old term 40_term.sh's check compared against, so it waited for a term past 300
wait_for() {
	local _wf_t="$1" _wf_s; shift
	_wf_s=$(date +%s)
	while :; do
		"$@" && return 0
		[ $(( $(date +%s) - _wf_s )) -ge "$_wf_t" ] && return 1
		sleep 2
	done
}

wait_container() {
	local c="$1"
	for _ in $(seq 1 30); do
		timeout 20 lxc exec "$c" -- systemctl is-system-running --wait >/dev/null 2>&1 && return 0
		sleep 2
	done
	return 1
}

# the writer of node n, as a transient unit there: the rows (its uuid, 1 .. MIG_LOOP)
writer_start() {
	local n="$1"
	xn "$n" mkdir -p /root/mig
	lxc file push "$MIG_HERE/writer.sh" "$(cname "$n")/root/mig/writer.sh" >/dev/null
	xn "$n" systemd-run --unit=mig-writer --setenv=PGPASSWORD="$MIG_PASS" \
		--setenv=MIG_DB="$MIG_DB" --setenv=MIG_USER="$MIG_USER" \
		bash /root/mig/writer.sh "$(nuuid "$n")" "$MIG_LOOP" "$MIG_PAUSE" >/dev/null 2>&1
}
writer_done() { xn "$1" test -e /root/mig/done; }
# the hot rows' updater of node n, as a transient unit there (hot.sh); its committed count
hot_start() {
	local n="$1"
	xn "$n" mkdir -p /root/mig
	lxc file push "$MIG_HERE/hot.sh" "$(cname "$n")/root/mig/hot.sh" >/dev/null
	xn "$n" systemd-run --unit=mig-hot --setenv=PGPASSWORD="$MIG_PASS" \
		--setenv=MIG_DB="$MIG_DB" --setenv=MIG_USER="$MIG_USER" \
		bash /root/mig/hot.sh "$MIG_HOT_ROWS" >/dev/null 2>&1
}
# ...stopped after the batch running, which hot.sh gives up on after 120 s
hot_stop() { xn "$1" touch /root/mig/hot.stop; local i; for i in $(seq 1 150); do xn "$1" test -e /root/mig/hot.done && return 0; sleep 1; done; return 1; }
hot_count() { xn "$1" sh -c "grep -c '^UPDATE 2' /root/mig/hot.log 2>/dev/null"; }
# every node's mig_hot: its rows and their values
hot_digest() { qc "$1" "select count(*) || ' ' || coalesce(sum(n), 0) || ' ' || md5(coalesce(string_agg(id || ':' || n, ',' order by id), '')) from mig_hot"; }
# dump_on <n>: the application's database and the roles, by pg_dump on server n,
# into postgres's home there (DUMP_AT)
DUMP_AT=/var/lib/postgresql
dump_on() {
	xn "$1" su postgres -c "pg_dump -Fc -d $MIG_DB -f $DUMP_AT/mig.dump && pg_dumpall --roles-only -f $DUMP_AT/mig-roles.sql"
}
# refused transactions (ERR) of every member's writer so far, summed
refused_all() { local n c=0 x; for n in $(members); do x=$(xn "$n" sh -c "grep -c ' ERR ' /root/mig/writer.log" 2>/dev/null); c=$((c + ${x:-0})); done; echo "$c"; }
# outcome counts of node n's writer: "OK=.. ERR=.. NOC=.. UNK=.."
writer_counts() {
	xn "$1" sh -c "awk '{c[\$3]++} END {printf \"OK=%d ERR=%d NOC=%d UNK=%d\", c[\"OK\"], c[\"ERR\"], c[\"NOC\"], c[\"UNK\"]}' /root/mig/writer.log 2>/dev/null"
}
