#!/usr/bin/env bash
# [delta] A write that conflicts with a concurrent one is retryable only when it is
# a delta. A plain UPDATE run again overwrites the other writer's change with no
# review by the user, so its conflict is a plain rollback - 55409, "do not retry;
# review the row" - not the 40001 drivers and ORMs retry by themselves. A session
# whose SQL is a delta (`set n = n + 1`, a json or a text patch) says so with
# yt_cluster.delta, and then the same refusal reaches it as 40001.
#
# The conflict, made the same way every run: n1 holds an update of row 1 open (in
# flight at the leader) while n2 updates the row. The table's party is its origin
# alone (cluster_commit=nodes>=1), so no member holds n1's row lock and n2's
# statement reaches the leader's check-in, which refuses it ([rmw]).
#
# Written 2026-10-22 without a run; its first run is the next nightly.
#
# D1 n2's plain update of the row n1 holds in flight: 55409, do not retry
# D2 the same with `set yt_cluster.delta = on`: 40001, retry the transaction
# D3 every node holds one value of the row, never n2's refused one
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== delta retry: a conflicting plain write is a plain rollback; a delta session retries =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 2 ] || { bad "needs two non-spare nodes, has ${#VOTERS[@]}"; summary; }
W1="${VOTERS[0]}"; W2="${VOTERS[1]}"

# the SQLSTATE from its own field (96_jsonb_merge.sh: never a glob over the text)
sqlstate_of() {
	printf '%s\n' "$1" | { grep -m1 '^ERROR:' || true; } \
		| sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p'
}
psql_on() { # psql_on <node> <sql>: its output, errors in full
	printf '%s\n' "$2" | rh "docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=20s' $1 \
		psql -X -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
# n1 holds row 1 in flight for <secs>, in the background
hold() { # hold <value> <secs>
	psql_on "$W1" "begin; update dl_t set v = '$1' where id = 1; select pg_sleep($2);
		select yt_complete(true); commit;" > "$TMP/hold.out" &
	HOLD=$!
}

TMP="$(mktemp -d)"
cleanup() {
	set +e
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists dl_t;" >/dev/null 2>&1
		cfg_delete "$n" public.dl_t A >/dev/null 2>&1 || true
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
ONE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
[ -n "$ONE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists dl_t; create table dl_t (id bigint primary key, v text not null);" >/dev/null
done
register_table public.dl_t "$ONE_CFG"
restart_all
await_cluster
q "$W1" "begin; insert into dl_t values (1, 'base'); select yt_complete(true); commit;" >/dev/null
for i in $(seq 1 12); do [ "$(q "$W2" "select v from dl_t where id = 1")" = base ] && break; sleep 5; done
check "setup: row 1 reached $W2" base "$(q "$W2" "select v from dl_t where id = 1")"

# ── D1: a plain update, no delta ─────────────────────────────────────────────
hold n1-a 6
sleep 2
out="$(psql_on "$W2" "begin; update dl_t set v = 'n2-a' where id = 1; select yt_complete(true); commit;")"
wait "$HOLD"
check "D1 $W2's plain update of a row $W1 holds in flight: 55409" 55409 "$(sqlstate_of "$out")"
case "$out" in
	*"do not retry; review the row"*) ok "D1 ...and it says do not retry" ;;
	*) bad "D1 the refusal says do not retry: [$(printf '%s' "$out" | grep -m1 '^ERROR:')]" ;;
esac

# ── D2: the same, the session's SQL a delta ─────────────────────────────────
hold n1-b 6
sleep 2
out="$(psql_on "$W2" "set yt_cluster.delta = on;
	begin; update dl_t set v = 'n2-b' where id = 1; select yt_complete(true); commit;")"
wait "$HOLD"
check "D2 with yt_cluster.delta: 40001" 40001 "$(sqlstate_of "$out")"
case "$out" in
	*"a delta (yt_cluster.delta): retry the transaction"*) ok "D2 ...and it says retry" ;;
	*) bad "D2 the refusal says retry: [$(printf '%s' "$out" | grep -m1 '^ERROR:')]" ;;
esac

# ── D3: one value everywhere, never a refused one ───────────────────────────
sleep 5
vals=""
for n in "${NODES[@]}"; do vals="$vals $(q "$n" "select v from dl_t where id = 1")"; done
uniq_vals="$(printf '%s\n' $vals | sort -u | tr '\n' ' ')"
check "D3 every node holds one value of row 1" 1 "$(printf '%s\n' $vals | sort -u | grep -c .)"
case " $uniq_vals " in
	*" n2-"*) bad "D3 a refused write of $W2 is on a node: [$uniq_vals]" ;;
	*) ok "D3 no node holds a refused write ($uniq_vals)" ;;
esac
summary
