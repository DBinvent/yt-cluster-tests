#!/usr/bin/env bash
# [ycoord] Cluster-wide advisory locks and sequences from SQL: yt_advisory_lock and its kin
# are pg_advisory_lock across the nodes, yt_nextval is nextval() across them - held on each
# node's ytserv, decided by its etcd's leader, which is the Boss.
#
# Written 2026-11-21 without a run; its first run is the next nightly.
#
# L1 a lock n1 holds: n2's try is refused, n2's wait ends at its statement_timeout (57014)
# L2 n1's unlock: n2's try takes it; held again it is held once more (two unlocks free it)
# L3 a transaction's lock goes at its commit
# L4 a session's lock goes when its backend exits
# S1 a table's defaults on the cluster's sequences (yt_cluster_sequences on each node):
#    rows inserted on every node at once, no id twice
# S2 the cluster off for a session (yt.node = 'local'): yt_nextval is the local nextval()
# S3 every ytserv restarted, PostgreSQL up: the sequence goes on above what it gave
#    (its marks kept in yt_config, module Q), and a lock held across it stays held
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== cluster locks and sequences: yt_advisory_lock, yt_nextval =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 2 ] || { bad "needs two non-spare nodes, has ${#VOTERS[@]}"; summary; }
N1="${VOTERS[0]}"; N2="${VOTERS[1]}"

psql_on() { # psql_on <node> <sql>: its output, errors in full
	printf '%s\n' "$2" | rh "docker exec -i -u postgres $1 psql -X -tAq -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
sqlstate_of() {
	printf '%s\n' "$1" | { grep -m1 '^ERROR:' || true; } | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p'
}
# n1 holds <sql> for <secs>, in the background
hold() { # hold <sql> <secs>
	psql_on "$N1" "$1; select pg_sleep($2);" > "$TMP/hold.out" &
	HOLD=$!
}
# n2's try of <key>, until it reads <want> or <tries> 2-second steps pass
try_until() { # try_until <key> <want> <tries>
	local got="" i
	for i in $(seq 1 "$3"); do
		got="$(q "$N2" "select yt_try_advisory_lock($1)" | tail -1)"
		[ "$got" = "$2" ] && break
		[ "$got" = t ] && q "$N2" "select yt_advisory_unlock($1)" >/dev/null
		sleep 2
	done
	printf '%s' "$got"
}

TMP="$(mktemp -d)"
cleanup() {
	set +e
	local n
	[ -n "${HOLD:-}" ] && kill "$HOLD" 2>/dev/null
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists cl_t;" >/dev/null 2>&1
		cfg_delete "$n" public.cl_t A >/dev/null 2>&1 || true
	done
	rm -rf "$TMP"
}
trap cleanup EXIT
await_cluster

# ── L1/L2: a lock across nodes ──────────────────────────────────────────────
hold "select yt_advisory_lock(4201)" 12
sleep 3
check "L1 $N2's try of the lock $N1 holds: refused" f "$(q "$N2" "select yt_try_advisory_lock(4201)" | tail -1)"
out="$(psql_on "$N2" "set statement_timeout = '3s'; select yt_advisory_lock(4201);")"
check "L1 $N2's wait ends at its statement_timeout" 57014 "$(sqlstate_of "$out")"
wait "$HOLD"; HOLD=""
check "L2 $N1's session gone, $N2's try takes it" t "$(try_until 4201 t 10)"
two="$(psql_on "$N2" "select yt_advisory_lock(4202); select yt_advisory_lock(4202);
	select yt_advisory_unlock(4202); select yt_advisory_unlock(4202); select yt_advisory_unlock(4202);")"
check "L2 held twice, two unlocks free it, a third finds none" "t t f" "$(printf '%s\n' "$two" | grep -E '^[tf]$' | tr '\n' ' ' | sed 's/ $//')"

# ── L3: a transaction's lock ────────────────────────────────────────────────
hold "begin; select yt_advisory_xact_lock(4203)" 6
sleep 2
check "L3 $N1's transaction lock: $N2's try refused" f "$(q "$N2" "select yt_try_advisory_lock(4203)" | tail -1)"
wait "$HOLD"; HOLD=""
check "L3 its transaction over, $N2's try takes it" t "$(try_until 4203 t 10)"

# ── L4: a session's end ─────────────────────────────────────────────────────
q "$N1" "select yt_advisory_lock(4204)" >/dev/null
check "L4 $N1's session ended, its lock goes" t "$(try_until 4204 t 10)"

# ── S1: sequences from every node ───────────────────────────────────────────
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists cl_t; create table cl_t (id bigserial primary key, node text not null);" >/dev/null
done
register_table public.cl_t ""
restart_all
await_cluster
for n in "${NODES[@]}"; do
	switched="$(q "$n" "select yt_cluster_sequences('public.cl_t'::regclass, true)" | tail -1)"
	check "S1 $n: one column on the cluster's sequence" 1 "$switched"
done
pids=()
for n in "${VOTERS[@]}"; do
	( for i in $(seq 1 20); do
		q "$n" "begin; insert into cl_t (node) values ('$n'); select yt_complete(true); commit;" >/dev/null
	  done ) &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
want=$(( ${#VOTERS[@]} * 20 ))
for i in $(seq 1 24); do [ "$(q "$N1" "select count(*) from cl_t")" = "$want" ] && break; sleep 5; done
check "S1 every node's rows on $N1" "$want" "$(q "$N1" "select count(*) from cl_t")"
check "S1 no id twice" "$want" "$(q "$N1" "select count(distinct id) from cl_t")"
top="$(q "$N1" "select max(id) from cl_t")"

# ── S2: the cluster off for a session ───────────────────────────────────────
local_next="$(q "$N2" "set yt.node = 'local'; select yt_nextval('public.cl_t_id_seq') = (select last_value from public.cl_t_id_seq)")"
check "S2 off: yt_nextval is the local sequence's nextval" t "$(printf '%s\n' "$local_next" | tail -1)"

# ── S3: every ytserv restarted, PostgreSQL up ───────────────────────────────
hold "select yt_advisory_lock(4205)" 90
sleep 3
restart_all
await_cluster
next="$(q "$N2" "select yt_nextval('public.cl_t_id_seq')" | tail -1)"
if [ -n "$next" ] && [ -n "$top" ] && [ "$next" -gt "$top" ]; then
	ok "S3 after the restart the sequence goes on above $top ($next)"
else
	bad "S3 after the restart the sequence goes on above $top, read [$next]"
fi
check "S3 the lock $N1 held across the restart is held yet" f "$(q "$N2" "select yt_try_advisory_lock(4205)" | tail -1)"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""

summary
