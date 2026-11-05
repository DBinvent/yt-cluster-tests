#!/usr/bin/env bash
# [keyless-row] A table with no primary key: an UPDATE or a DELETE changes, on every
# member, the one row the origin changed - found by all its columns - never every row
# like it (YT Cluster's ytserv core.rs keyless_row). Before, the trigger sent no column of
# a keyless DELETE, and every member ran `delete from t`: the whole table, for one row;
# a keyless UPDATE changed every row holding the changed column's old value.
#
# Written 2026-10-28 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   K1  DELETE one of 22 rows: 21 on every node, and not that one
#   K2  two identical rows, one of them deleted (by ctid on the origin): one left on
#       every node
#   K3  UPDATE one row's note that three other rows hold too: only that row changes,
#       everywhere
#   K4  a row with json, numeric, timestamptz and a NULL deleted, and another's json
#       updated: found by their values on every node
#   K5  every node identical, no `cluster_apply fail`
#
# kl_t: no primary key, the default party. kl_w: a keyed table - the writability probe.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== keyless rows: an UPDATE or DELETE of a table with no primary key takes its one row =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 2 ] || { bad "needs two non-spare nodes, has ${#VOTERS[@]}"; summary; }
REF="${VOTERS[0]}"

# ── helpers (local, as 29e_unique_boundary.sh's: env.sh's q discards stderr) ─
qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout] -> "" when the cluster write committed, else the error
	err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
}
qt() { # env.sh's q plus a statement_timeout, so a wedged ytserv cannot hang a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
# wait_all <secs> <sql> <want> -> 0 once every node returns <want>
wait_all() {
	local deadline=$((SECONDS + $1)) n all
	while :; do
		all=1
		for n in "${NODES[@]}"; do [ "$(qt "$n" "$2")" = "$3" ] || { all=0; break; }; done
		[ "$all" = 1 ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}
# every_node <label> <sql> <want>: waits, then one check per node
every_node() {
	local n
	wait_all 60 "$2" "$3" || true
	for n in "${NODES[@]}"; do check "$1 on $n" "$3" "$(qt "$n" "$2")"; done
}
host_now() { rh "date +%s" 2>/dev/null || date +%s; }
apply_fails_since() { # `cluster_apply fail` lines logged by every node since <unix-ts>
	local n c total=0
	for n in "${NODES[@]}"; do
		c="$(rh "docker logs --since $1 $n 2>&1 | grep -c 'cluster_apply fail'" 2>/dev/null || true)"
		case "$c" in ''|*[!0-9]*) c=0 ;; esac
		total=$((total + c))
	done
	echo "$total"
}

CLEANED=0
cleanup() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local n t
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists kl_t; drop table if exists kl_w;" >/dev/null 2>&1
		for t in kl_t kl_w; do cfg_delete "$n" "public.$t" A >/dev/null 2>&1; done
	done
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists kl_t; create table kl_t (id bigint, v text, doc json, amt numeric(10,2),
	          at timestamptz, n int);
	        drop table if exists kl_w; create table kl_w (id bigint primary key, v text);" >/dev/null
done
# both before ONE restart: a module-A row is read by the startup loader
register_table public.kl_t
register_table public.kl_w
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" kl_w || { bad "cluster never became writable"; summary; }
T0="$(host_now)"

# 20 rows, the note shared by every third; 100 twice, the same row
SEED="insert into kl_t select i, 'note-'||(i % 3), json_build_object('i', i), i * 1.5,
	'2026-10-28 12:00:00+00'::timestamptz + i * interval '1 minute', case when i % 4 = 0 then null else i end
	from generate_series(1, 20) i;
	insert into kl_t values (100, 'dup', '{\"d\": 1}', 1.00, '2026-10-28 12:00:00+00', 1),
	                        (100, 'dup', '{\"d\": 1}', 1.00, '2026-10-28 12:00:00+00', 1)"
e="$(cw "$REF" "$SEED")"
check "the seed committed on $REF" "" "$e"
every_node "the seed's 22 rows" "select count(*) from kl_t" 22

# ── K1: one row deleted, the rest kept ──────────────────────────────────────
echo "  -- K1: delete one of 22 rows on $REF"
check "K1 the delete committed" "" "$(cw "$REF" "delete from kl_t where id = 7")"
every_node "K1 21 rows" "select count(*) from kl_t" 21
every_node "K1 none of id 7" "select count(*) from kl_t where id = 7" 0

# ── K2: one of two identical rows ───────────────────────────────────────────
echo "  -- K2: delete one of two identical rows on $REF"
check "K2 the delete committed" "" \
	"$(cw "$REF" "delete from kl_t where ctid = (select ctid from kl_t where id = 100 limit 1)")"
every_node "K2 one copy of the row left" "select count(*) from kl_t where id = 100" 1
every_node "K2 20 rows" "select count(*) from kl_t" 20

# ── K3: one row's note, which three others hold too ─────────────────────────
echo "  -- K3: update the note of id 5 ('note-2', as ids 2, 8, 11, 14, 17, 20)"
check "K3 the update committed" "" "$(cw "$REF" "update kl_t set v = 'changed' where id = 5")"
every_node "K3 one row changed" "select string_agg(id::text, ',') from kl_t where v = 'changed'" 5
every_node "K3 the others keep the note" "select count(*) from kl_t where v = 'note-2'" 6

# ── K4: json, numeric, timestamptz and a NULL ───────────────────────────────
echo "  -- K4: delete id 12 (json, numeric 18.00, a timestamptz, n NULL); set id 3's json"
check "K4 the delete committed" "" "$(cw "$REF" "delete from kl_t where id = 12")"
every_node "K4 none of id 12" "select count(*) from kl_t where id = 12" 0
check "K4 the json update committed" "" "$(cw "$REF" "update kl_t set doc = '{\"x\": 3}' where id = 3")"
every_node "K4 id 3's json" "select doc::text from kl_t where id = 3" '{"x": 3}'
every_node "K4 19 rows" "select count(*) from kl_t" 19

# ── K5: every node identical ────────────────────────────────────────────────
DIG="select md5(string_agg(id||':'||v||':'||coalesce(doc::text,'~')||':'||amt||':'||extract(epoch from at)
	||':'||coalesce(n::text,'~'), ',' order by id, v)) from kl_t"
for n in "${NODES[@]}"; do
	[ "$n" = "$REF" ] && continue
	check_same "K5 $n is identical to $REF" "$REF" "$n" "$DIG" 19 kl_t
done
check "K5 no cluster_apply fail" 0 "$(apply_fails_since "$T0")"

cleanup
summary
