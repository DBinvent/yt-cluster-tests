#!/usr/bin/env bash
# [shard-lease] A node that keeps writing one shard leases the shard's subterms and
# issues them as the shard's holder; another node writing the shard checks in with
# the holder, sent there by the leader. yt-pgxt pre-checkin.md "Shard lease".
#
# Written 2026-10-16 without a run (full test runs were off for a dev session) and
# put in run_a.sh as it was, the owner's call: its first run is the next nightly.
#
# sl_t's shard is its `store` column, pinned (`outer=pin`): store 'top' is az top,
# n1 and n2 here, so both may write it, nobody else holds it. `hpc` puts the table
# at sequential_consistency 2, which any subterm lease needs.
#
#   L1  W, a top node that is not the leader, writes store 'top' fast: it comes to
#       hold the lease of shard top (yt_info('E') hpc_lease)
#   L2  O, the other top node, writes store 'top' while W holds it: every write
#       commits, and W issued them - its run's next subterm moved by as many
#   L3  n1 and n2 hold the same sl_t, exactly the acknowledged rows
#   L4  nobody writes for longer than the lease: it lapses, and O's next write is
#       admitted by the leader again
#   L4b no lease while O's write of the shard is in flight: the leader refuses, and
#       says why; W's writes go by ordinary checkins, every one committed
#   L5  W takes the lease again and drops off the network with it: O's writes of
#       the shard fail while they are sent to W, and commit again once the lease
#       lapsed - nothing waits for W for good (added 2026-10-16, unrun)
#       ...and meanwhile a write of another synced table commits at once: the
#       lease's gap holds only its own rows (lease-end, 2026-10-17) - written once
#       O and the leader, which picks its party, both see W off; the leader
#       answers within 3 s all the while (2026-10-19)
#   L6  W back on the network holds what O holds
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== shard lease: a shard's subterms issued by the node that writes it =="

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server' || true; }
}
cwc() { err_of "$(qx "$1" "begin; $2; commit;" "${3:-60s}")"; }
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
yinfo() { # yinfo <node> <letters> <name> -> one yt_info value
	qt "$1" "select yt_info('$2')" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == sys.argv[1]: print(r.get('value','')); break
" "$3" 2>/dev/null || true
}
leader_now() {
	local n v
	for n in "${NODES[@]}"; do
		v="$(yinfo "$n" O cluster)"
		case "$v" in *", Leader"|*", Leader, discrepancy"*) printf '%s' "$n"; return 0 ;; esac
	done
}
lease_next() { # the holder's next subterm, from "... next N, ..."
	yinfo "$1" E hpc_lease | sed -nE 's/.* next ([0-9]+),.*/\1/p'
}
lease_live() { # a lease in use, not the lapsed one that still names the shard
	case "$(yinfo "$1" E hpc_lease)" in
		*"spent or past its time"*) return 1 ;;
		*"holds shard top of public.sl_t"*) return 0 ;;
		*) return 1 ;;
	esac
}

cleanup() {
	set +e
	local n
	# L5 takes the holder off the network: never leave it so
	[ -n "${W:-}" ] && node_up "$W" >/dev/null 2>&1
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists sl_t; drop table if exists sl_o;" >/dev/null 2>&1
		cfg_delete "$n" public.sl_t A >/dev/null 2>&1 || true
		cfg_delete "$n" public.sl_o A >/dev/null 2>&1 || true
	done
}

# ── setup ────────────────────────────────────────────────────────────────────
TOPS=(); for n in "${NODES[@]}"; do [ "${NODE_AZ[$n]:-}" = top ] && TOPS+=("$n"); done
[ "${#TOPS[@]}" -ge 2 ] || { bad "needs two nodes in az top, has ${#TOPS[@]}"; summary; }
CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'shard=store; outer=pin; hpc' | tail -1 || true)"
[ -n "$CFG" ] || { bad "ytctl --encode-table-cfg does not know 'hpc' (is $REPO_ROOT built?)"; summary; }
trap cleanup EXIT
cleanup
for n in "${NODES[@]}"; do
	q "$n" "create table sl_t (store text not null, id bigint not null, v bigint, primary key (store, id));" >/dev/null
	# [lease-end] a table no lease covers, written while the holder is away (L5)
	q "$n" "create table sl_o (id bigint primary key, v bigint);" >/dev/null
done
register_table public.sl_t "$CFG"
register_table public.sl_o ""
restart_all
await_cluster
L="$(leader_now)"
# A third node leads, never a top one: with the leader as O, O's view of W and the
# party chooser's are one, and L5 tests nothing of the two disagreeing - the
# nightlies' failures all had a west node lead (2026-10-19). Moved by the operator's
# force-election, yt_info('e:<ip>:<port>'), as 34_skv_store does.
case " ${TOPS[*]} " in *" $L "*)
	for n in "${NODES[@]}"; do
		case " ${TOPS[*]} " in *" $n "*) continue ;; esac
		is_spare_node "$n" && continue
		NIP="$(rh "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $n")"
		echo "  force-election to $n ($NIP): $(q "$L" "select yt_info('e:$NIP:$YX_PORT')" 2>&1 | cut -c1-120)"
		for _ in $(seq 1 30); do [ "$(leader_now)" = "$n" ] && break; sleep 2; done
		await_cluster
		L="$(leader_now)"
		break
	done ;;
esac
check "a third node leads, neither top node (leader $L)" "" "$(case " ${TOPS[*]} " in *" $L "*) echo "$L" ;; esac)"
# W: a top node that is not the leader - the leader leases to nobody, itself included
W=""; O=""
for n in "${TOPS[@]}"; do [ "$n" != "$L" ] && [ -z "$W" ] && W="$n"; done
for n in "${TOPS[@]}"; do [ "$n" != "$W" ] && [ -z "$O" ] && O="$n"; done
[ -n "$W" ] && [ -n "$O" ] || { bad "no top node to lease (leader $L, top ${TOPS[*]})"; summary; }
echo "  leader $L, lease writer $W, other writer $O"
# writable, and replicating to O: a fresh negative id per attempt, as wait_writable
for i in $(seq 1 24); do
	cwc "$W" "insert into sl_t values ('top', -$i, 0)" >/dev/null
	[ "$(qt "$O" "select count(*) from sl_t where id = -$i")" = 1 ] && break
	sleep 5
done
cwc "$W" "delete from sl_t where id < 0" >/dev/null
# batch <node> <first id> <count>: that many inserts of store 'top' in ONE psql
# session, each its own transaction (autocommit; auto_complete makes each a cluster
# commit) - one docker exec per statement is too slow for the hheuristic's 10 writes
# in 2 s. Sets BATCH_N, how many of the ids are on the node afterwards, and
# BATCH_ERR - globals, not output: a command substitution would lose BATCH_ERR.
batch() {
	local sql="" i
	for i in $(seq "$2" $(($2 + $3 - 1))); do sql+="insert into sl_t values ('top', $i, $i);"$'\n'; done
	BATCH_ERR="$(err_of "$(qx "$1" "$sql" 120s)")"
	BATCH_N="$(qt "$1" "select count(*) from sl_t where id between $2 and $(($2 + $3 - 1))")"
}

# ── L1: the writer comes to hold the lease ──────────────────────────────────
# 40: past the 10 the lease is asked after, well inside the run it is given (the
# rate over the window times hpc_lease_sec - about 200)
batch "$W" 1 40; acked="${BATCH_N:-0}"
check "L1 $W's 40 writes of shard top committed" "40" "${acked:-0}${BATCH_ERR:+ - $BATCH_ERR}"
case "$(yinfo "$W" E hpc_lease)" in
	*"holds shard top of public.sl_t"*) ok "L1 $W holds the lease of shard top: $(yinfo "$W" E hpc_lease)" ;;
	*) bad "L1 $W does not hold shard top: [$(yinfo "$W" E hpc_lease)]" ;;
esac

# ── L2: the other top node's writes go through the holder ───────────────────
n0="$(lease_next "$W")"
batch "$O" 1001 10; o_acked="${BATCH_N:-0}"
n1="$(lease_next "$W")"
check "L2 every write of $O to shard top committed" "10" "${o_acked:-0}${BATCH_ERR:+ - $BATCH_ERR}"
if [ -n "$n0" ] && [ -n "$n1" ]; then
	[ "$((n1 - n0))" -ge 10 ] && ok "L2 $W issued them: its run moved from $n0 to $n1" \
		|| bad "L2 $W's run moved from $n0 to $n1 for 10 writes of $O - not issued by the holder"
else
	bad "L2 $W holds no lease any more to read its run from: [$(yinfo "$W" E hpc_lease)]"
fi

# ── L3: the two top nodes agree ─────────────────────────────────────────────
want=$(( ${acked:-0} + ${o_acked:-0} ))
for _ in $(seq 1 20); do
	a="$(qt "${TOPS[0]}" "select count(*) from sl_t where id > 0")"; b="$(qt "${TOPS[1]}" "select count(*) from sl_t where id > 0")"
	[ "$a" = "$want" ] && [ "$b" = "$want" ] && break
	sleep 3
done
check "L3 ${TOPS[0]} holds exactly the acknowledged rows" "$want" "$a"
check "L3 ${TOPS[1]} holds exactly the acknowledged rows" "$want" "$b"
check "L3 the two agree on sl_t" "$(qt "${TOPS[0]}" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")" \
	"$(qt "${TOPS[1]}" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"

# ── L4: the lease lapses, and the leader takes the shard again ──────────────
sleep 25
case "$(yinfo "$W" E hpc_lease)" in
	*"holds shard top"*"spent or past its time"*|*"holds none"*) ok "L4 the lease lapsed: $(yinfo "$W" E hpc_lease)" ;;
	*) bad "L4 the lease is still held 25 s after the writing stopped: [$(yinfo "$W" E hpc_lease)]" ;;
esac
check "L4 $O's write after the lapse committed" "" "$(cwc "$O" "insert into sl_t values ('top', 2001, 1)")"

# ── L4b: no lease while another node's write of the shard is in flight ──────
# The holder's conflict scan does not see a write still on its way to it, so the
# leader refuses (shard_lease_refusal) and the burst goes by ordinary checkins. L4's
# write met L5's burst so by chance in the nightlies of 2026-10-30 and 2026-11-04.
sleep 6   # a node says a refusal once in 30 s: L1's turn, had it one, is over
t1=$(date +%s)
inflight="$(mktemp)"
qx "$O" "begin; insert into sl_t values ('top', 2002, 1); select pg_sleep(10); commit;" 30s > "$inflight" 2>&1 &
inflight_pid=$!
sleep 2
batch "$W" 2101 40
check "L4b $W's 40 writes committed with $O's in flight" "40" "${BATCH_N:-0}${BATCH_ERR:+ - $BATCH_ERR}"
lease_live "$W" && bad "L4b a lease with $O's write in flight: [$(yinfo "$W" E hpc_lease)]" \
	|| ok "L4b no lease while $O's write is in flight"
said="$(rh "docker logs --since $t1 $W 2>&1 | grep -c 'of shard top of .* refused: a write of shard top by another node is in flight'" 2>/dev/null || true)"
check "L4b $W says why" "1" "$([ "${said:-0}" -ge 1 ] && echo 1 || echo "${said:-0}")"
wait "$inflight_pid"
check "L4b $O's write committed" "" "$(err_of "$(cat "$inflight")")"
rm -f "$inflight"

# ── L5: the holder goes away under its lease ────────────────────────────────
batch "$W" 3001 40
check "L5 $W's 40 writes of shard top committed" "40" "${BATCH_N:-0}${BATCH_ERR:+ - $BATCH_ERR}"
# The leader may refuse this whole burst too, for a write of O's it has not yet seen
# done (L4b): the next burst asks again.
bursts=1
while ! lease_live "$W" && [ "$bursts" -lt 6 ]; do
	sleep 1
	batch "$W" $((3001 + 40 * bursts)) 40
	check "L5 $W's next 40 writes of shard top committed" "40" "${BATCH_N:-0}${BATCH_ERR:+ - $BATCH_ERR}"
	bursts=$((bursts + 1))
done
echo "  L5 $W asked through $bursts burst(s) of 40"
# a live lease, not the lapsed one of L4 - that one still names the shard
case "$(yinfo "$W" E hpc_lease)" in
	*"spent or past its time"*) bad "L5 $W did not take the lease again - it shows the lapsed one: [$(yinfo "$W" E hpc_lease)]" ;;
	*"holds shard top of public.sl_t"*) ok "L5 $W holds the lease of shard top again" ;;
	*) bad "L5 $W did not take the lease again: [$(yinfo "$W" E hpc_lease)]" ;;
esac
# the leader now, while W still answers (W is never it): it picks the party below
L="$(leader_now)"; [ -n "$L" ] || L="$O"
node_down "$W"
# Writes only once O has NOTICED the holder gone (as 23_split's E2): a write racing
# the detection takes the holder into its 2PC party and fails on its PREPARE
# ("Fail to modify peer ... of party: Timeout expired", the nightly of 2026-10-18) -
# a different question from whether it waits on the lease's gap.
# ...and the leader too: it picks the party. O saw W off and wrote while the leader
# still counted W up, a second later than O - its party held W, and the PREPARE
# came 2 of 3 short ("no response from any nodes on PREPARE": six runs at debug
# 2026-10-19, every failure that order, every pass the other).
# The leader's answers are timed meanwhile: they read W's state under the lock its
# party choice reads, and a leader that stalls while W goes is a fault of its own -
# the nightlies of 2026-10-19 timed out checking in with it ("Timeout expired").
seen=""; uw="$(node_uuid "$W")"; slow=0
for i in $(seq 1 20); do
	a="$(info "$O" E "$uw")"
	t1=$(date +%s%N); b="$(info "$L" E "$uw")"; t1=$(( ($(date +%s%N) - t1) / 1000000 ))
	[ "$t1" -gt "$slow" ] && slow=$t1
	case "$a" in ""|*Good*|*Leader*) sleep 1; continue ;; esac
	case "$b" in ""|*Good*|*Leader*) sleep 1; continue ;; esac
	seen=$i; break
done
echo "  $O and the leader $L see $W off$([ -n "$seen" ] && echo " after ${seen}s" || echo " - not within 20s")"
check "L5 the leader answered within 3 s while $W went away (slowest: ${slow} ms)" "1" "$([ "$slow" -lt 3000 ] && echo 1 || echo 0)"
# [lease-end] another table's write does not wait on the lease's gap: it commits
# well inside the statement timeout (before, every synced table waited on it)
t1=$(date +%s)
e1="$(cwc "$O" "insert into sl_o values (1, 1)" 20s)"
check "L5 with the holder gone, $O's write of another table committed at once" "" \
	"${e1}$( [ -z "$e1" ] && [ $(( $(date +%s) - t1 )) -gt 10 ] && echo "after $(( $(date +%s) - t1 ))s" )"
t0=$(date +%s); back=""; e=""; wrote=""
for i in $(seq 1 24); do
	e="$(cwc "$O" "insert into sl_t values ('top', $((4000 + i)), $i)" 30s)"
	[ -z "$e" ] && { back=$(( $(date +%s) - t0 )); wrote=$((4000 + i)); break; }
	sleep 5
done
[ -n "$back" ] && ok "L5 with the holder gone, $O's write of shard top committed again after ${back}s" \
	|| bad "L5 $O's writes of shard top never committed in $(( ($(date +%s) - t0) / 60 )) min with the holder $W off the network: [$e]"
node_up "$W"

# ── L6: the holder back holds what the others hold ──────────────────────────
a=""; b=""
for _ in $(seq 1 30); do
	a="$(qt "$O" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"
	b="$(qt "$W" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"
	[ -n "$a" ] && [ "$a" = "$b" ] && break
	sleep 5
done
check "L6 $W back on the network holds what $O holds" "$a" "$b"
# and the write it missed: L6 is otherwise met by two copies that never changed
[ -z "$wrote" ] || check "L6 $W holds $O's write of id $wrote, made while it was away" "1" \
	"$(qt "$W" "select count(*) from sl_t where id = $wrote")"
summary
