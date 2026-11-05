#!/usr/bin/env bash
# [composite-pk] Tables keyed by more than one column, synced, and the warning for tables the
# cluster can tell apart by no primary key (YT Cluster's problems.md P6 and P12; the owner,
# 2026-11-01: a merge table's unique key beside its primary key, and a keyless table, are
# warned of and better kept out of the sync - "warn and avoid").
#
#   P1   cp(a int, b text, v, note, primary key (a, b)), the default party: three origins
#        insert 30 rows each, keys of their own - every one acknowledged, every node identical
#   P2   cp1 as cp, cluster_commit=nodes>=1: 30 rounds, three origins insert one (a, b) at
#        once - no round acknowledged twice, refusals 23505, 40001 or 55409 (the first writer
#        of a row wins, [rmw]: another origin's insert of the key in flight - a retry would
#        meet its 23505), every node identical, no `cluster_apply fail`
#   P2b  P2 under the default party (cp2): as P2, each round <= 10 s
#   P3   UPDATEs of a non-key column by the composite key, two origins on rows of their own:
#        >= 95 % acknowledged, every node identical
#   P4   an UPDATE of a key column (b) moves the row: the new key on every node, the old on none
#   P5   a DELETE by the composite key from another origin: the row gone on every node
#   P6   cpu(a, b, c, v, primary key (a, b), unique (c, v)), nodes>=1: 20 rounds, three
#        origins insert keys of their own with one (c, v) at once - at most one a round,
#        refusals 23505 or 40001
#   P7   cpi(id pk, a, b, v) with a composite index (a, b), not unique: three origins insert
#        and update by it at once - no refusal, every node identical
#   W1   ckl, keyless, one write: a warning alert on its origin (source config, "no primary
#        key") - once, however many writes
#   W2   cpm, a merge table keyed (a, b) with unique (k) beside it: a warning alert naming the
#        key; cpu, a plain table with one, and cp, none, have no such alert
#
# cpw: the writability probe.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== composite primary keys, and the non-PK sync warning =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 3 ] || { bad "needs three non-spare nodes, has ${#VOTERS[@]}"; summary; }
ORIG=( "${VOTERS[@]:0:3}" )
REF="${VOTERS[0]}"

# ── helpers (as 29g_composite_unique.sh's) ───────────────────────────────────
qx() { # qx <node> <sql> [statement_timeout] [extra PGOPTIONS] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}" extra="${4:-}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to $extra' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout] [extra PGOPTIONS] -> "" when the cluster write committed, else the error
	err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}" "${4:-}")"
}
state_of() {
	local s
	s="$(printf '%s\n' "$1" | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' | head -1)"
	printf '%s' "${s:--}"
}
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
wait_converged() {
	local deadline=$((SECONDS + $1)) n d first same
	while :; do
		first=""; same=1
		for n in "${NODES[@]}"; do
			d="$(qt "$n" "$2")"; d="${d:-<none>}"
			[ -n "$first" ] || first="$d"
			[ "$d" = "$first" ] || { same=0; break; }
		done
		[ "$same" = 1 ] && [ "$first" != "<none>" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}
host_now() { rh "date +%s" 2>/dev/null || date +%s; }
apply_fails_since() {
	local n c total=0
	for n in "${NODES[@]}"; do
		c="$(rh "docker logs --since $1 $n 2>&1 | grep -c 'cluster_apply fail'" 2>/dev/null || true)"
		case "$c" in ''|*[!0-9]*) c=0 ;; esac
		total=$((total + c))
	done
	echo "$total"
}
twice() { [ -f "$1" ] || return 0; cut -d' ' -f1 "$1" | sort | uniq -d | tr '\n' ' ' | sed 's/ $//'; }
acked_ids() { [ -f "$1" ] || return 0; cut -d' ' -f2 "$1" | sort -n | tr '\n' ' ' | sed 's/ $//'; }
same_everywhere() { # same_everywhere <label> <table> <digest-sql> <min rows>
	local n
	wait_converged 90 "$3" || true
	for n in "${NODES[@]}"; do
		[ "$n" = "$REF" ] && continue
		check_same "$1 $n is identical to $REF" "$REF" "$n" "$3" "$4" "$2"
	done
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
other_refusals() {
	local f="$1"; shift
	[ -f "$f" ] || return 0
	local ok_re; ok_re="$(printf '%s|' "$@")"; ok_re="${ok_re%|}"
	awk -v re="^($ok_re)\$" '$2 !~ re { $1=""; print substr($0, 2) }' "$f"
}

TABLES="cp cp1 cp2 cpu cpi ckl cpm cpw"
TMP="$(mktemp -d)"
CLEANED=0
cleanup() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local p n t
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	for n in "${NODES[@]}"; do
		for t in $TABLES; do
			q "$n" "drop table if exists $t" >/dev/null 2>&1
			cfg_delete "$n" "public.$t" A >/dev/null 2>&1
		done
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
ONE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
MERGE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'merge' | tail -1 || true)"
[ -n "$ONE_CFG" ] && [ -n "$MERGE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists cp; create table cp (a int, b text, v int, note text, primary key (a, b));
	        drop table if exists cp1; create table cp1 (a int, b text, v int, primary key (a, b));
	        drop table if exists cp2; create table cp2 (a int, b text, v int, primary key (a, b));
	        drop table if exists cpu; create table cpu (a int, b int, c text, v int, primary key (a, b), unique (c, v));
	        drop table if exists cpi; create table cpi (id bigint primary key, a int, b text, v int);
	        create index cpi_a_b on cpi (a, b);
	        drop table if exists ckl; create table ckl (a int, v int);
	        drop table if exists cpm; create table cpm (a int, b text, k text, doc jsonb, primary key (a, b), unique (k));
	        drop table if exists cpw; create table cpw (id bigint primary key, v text);" >/dev/null
	q "$n" "delete from public.yt_alert where source = 'config'" >/dev/null 2>&1
done
register_table public.cp
register_table public.cp1 "$ONE_CFG"
register_table public.cp2
register_table public.cpu "$ONE_CFG"
register_table public.cpi
register_table public.ckl
register_table public.cpm "$MERGE_CFG"
register_table public.cpw
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" cpw || { bad "cluster never became writable"; summary; }
cw "$REF" "insert into cpw values (1, 'term')" >/dev/null
for _i in $(seq 1 30); do
	_all=1
	for n in "${NODES[@]}"; do [ "$(qt "$n" "select count(*) from cpw where id = 1")" = 1 ] || _all=0; done
	[ "$_all" = 1 ] && break
	sleep 2
done
[ "$_all" = 1 ] || bad "setup: a node never applied the guard's write of the term"
settle() {
	wait_writable "$REF" "${VOTERS[1]}" cpw >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

# race <label> <rounds> <sql k0> <sql k1> <sql k2> [extra PGOPTIONS of origin 0] -> three
# origins run their statement at once, round after round - an empty one sits out; @R@ is
# the round, @ID@ an id of its own. $TMP/<label>.ok (round id), .err (round state message), .secs (round seconds)
race() {
	local L="$1" rounds="$2" r k o id e t0 pids d sql
	local tpl=("$3" "$4" "$5") x0="${6:-}"
	rm -f "$TMP/$L".*
	for r in $(seq 1 "$rounds"); do
		pids=(); t0=$SECONDS
		for k in 0 1 2; do
			o="${ORIG[$k]}"; id=$((r * 10 + k))
			[ -n "${tpl[$k]}" ] || continue
			sql="${tpl[$k]//@R@/$r}"; sql="${sql//@ID@/$id}"
			d="0.0$((RANDOM % 5))$((RANDOM % 10))"
			(
				sleep "$d"
				x=""; [ "$k" = 0 ] && x="$x0"
				e="$(cw "$o" "$sql" 30s "$x")"
				if [ -z "$e" ]; then echo "$r $id" >> "$TMP/$L.ok"
				else echo "$r $(state_of "$e") ${e:0:200}" >> "$TMP/$L.err"; fi
			) &
			pids+=($!)
		done
		for p in "${pids[@]}"; do wait "$p" || true; done
		echo "$((SECONDS - t0))" >> "$TMP/$L.secs"
	done
}
# at_most_one <label> <refusal states...> -> no round acknowledged twice, refusals of these states
at_most_one() {
	local L="$1"; shift
	local acked refused bad1
	acked="$(lines "$TMP/$L.ok")"; refused="$(lines "$TMP/$L.err")"
	echo "     acknowledged $acked, refused $refused"
	check "$L no round acknowledged twice" "" "$(twice "$TMP/$L.ok")"
	[ "$acked" -ge 3 ] && ok "$L the first writer of a value commits ($acked acknowledged)" \
		|| bad "$L only $acked acknowledged - the case under test hardly happened"
	bad1="$(other_refusals "$TMP/$L.err" "$@")"
	[ -z "$bad1" ] && ok "$L every refusal $* ($refused)" \
		|| bad "$L refusals other than $*: $(printf '%s\n' "$bad1" | head -3)"
}

# at_most_one <label> <refusal states...> -> no round acknowledged twice, refusals of these states
at_most_one() {
	local L="$1"; shift
	local acked refused bad1
	acked="$(lines "$TMP/$L.ok")"; refused="$(lines "$TMP/$L.err")"
	echo "     acknowledged $acked, refused $refused"
	check "$L no round acknowledged twice" "" "$(twice "$TMP/$L.ok")"
	[ "$acked" -ge 3 ] && ok "$L the first writer of a key commits ($acked acknowledged)" \
		|| bad "$L only $acked acknowledged - the case under test hardly happened"
	bad1="$(other_refusals "$TMP/$L.err" "$@")"
	[ -z "$bad1" ] && ok "$L every refusal $* ($refused)" \
		|| bad "$L refusals other than $*: $(printf '%s\n' "$bad1" | head -3)"
}
DIGCP="select md5(string_agg(a||':'||b||':'||coalesce(v::text, '-')||':'||coalesce(note, '-'), ',' order by a, b)) from cp"

# ── P1: composite keys of their own, three origins ──────────────────────────
echo "  -- P1: ${ORIG[*]} insert 30 rows each into cp (a, b), keys of their own"
T0="$(host_now)"
for k in 0 1 2; do
	(
		o="${ORIG[$k]}"
		for i in $(seq 1 30); do
			e="$(cw "$o" "insert into cp values ($i, 'o$k', $i, 'n0')" 30s)"
			if [ -z "$e" ]; then echo "$i" >> "$TMP/p1.$k.ok"; else echo "$(state_of "$e") ${e:0:200}" >> "$TMP/p1.$k.err"; fi
		done
	) &
done
for p in $(jobs -p); do wait "$p" || true; done
p1_ok=$(( $(lines "$TMP/p1.0.ok") + $(lines "$TMP/p1.1.ok") + $(lines "$TMP/p1.2.ok") ))
check "P1 every insert of a key of its own acknowledged" "90" "$p1_ok"
[ "$p1_ok" = 90 ] || echo "     first refusal: $(cat "$TMP"/p1.*.err 2>/dev/null | head -1)"
same_everywhere P1 cp "$DIGCP" 90
check "P1 $REF holds the 90 rows" "90" "$(qt "$REF" "select count(*) from cp")"
settle P1

# ── P2, P2b: one composite key from three origins at once ───────────────────
echo "  -- P2: 30 rounds, ${ORIG[*]} insert one (a, b) at once (nodes>=1)"
K="insert into cp1 values (@R@, 'k', @ID@)"
race P2 30 "$K" "$K" "$K"
at_most_one P2 23505 40001 55409
same_everywhere P2 cp1 "select md5(string_agg(a||':'||b||':'||v, ',' order by a, b)) from cp1" 1
check "P2 $REF holds one row a round acknowledged" "$(lines "$TMP/P2.ok")" "$(qt "$REF" "select count(*) from cp1")"
check "P2 no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
settle P2

echo "  -- P2b: 30 rounds as P2, the default party"
K="insert into cp2 values (@R@, 'k', @ID@)"
race P2b 30 "$K" "$K" "$K"
at_most_one P2b 23505 40001 55409
slowest="$(sort -n "$TMP/P2b.secs" 2>/dev/null | tail -1)"
[ "${slowest:-99}" -le 10 ] && ok "P2b each round over within seconds (slowest ${slowest} s)" \
	|| bad "P2b a round took ${slowest:-?} s"
same_everywhere P2b cp2 "select md5(string_agg(a||':'||b||':'||v, ',' order by a, b)) from cp2" 1
settle P2b

# ── P3: UPDATEs by the composite key ────────────────────────────────────────
echo "  -- P3: ${ORIG[1]} and ${ORIG[2]} update note of their own rows by (a, b)"
for k in 1 2; do
	(
		o="${ORIG[$k]}"; end=$((SECONDS + 25)); i=0
		while [ "$SECONDS" -lt "$end" ]; do
			i=$((i + 1))
			e="$(cw "$o" "update cp set note = 'u$i' where a = $((i % 30 + 1)) and b = 'o$k'" 20s)"
			if [ -z "$e" ]; then echo "$i" >> "$TMP/p3.$k.ok"; else echo "$(state_of "$e") ${e:0:200}" >> "$TMP/p3.$k.err"; fi
			sleep 0.1
		done
	) &
done
for p in $(jobs -p); do wait "$p" || true; done
p3_ok=$(( $(lines "$TMP/p3.1.ok") + $(lines "$TMP/p3.2.ok") ))
p3_try=$((p3_ok + $(lines "$TMP/p3.1.err") + $(lines "$TMP/p3.2.err")))
echo "     updates: $p3_try, acknowledged $p3_ok"
[ "$p3_try" -ge 20 ] && [ $((p3_ok * 100)) -ge $((p3_try * 95)) ] \
	&& ok "P3 >= 95 % of the updates by the composite key acknowledged ($p3_ok of $p3_try)" \
	|| bad "P3 $p3_ok of $p3_try acknowledged - first refusal: $(cat "$TMP"/p3.*.err 2>/dev/null | head -1)"
same_everywhere P3 cp "$DIGCP" 90
settle P3

# ── P4: an UPDATE of a key column moves the row ─────────────────────────────
echo "  -- P4: ${ORIG[1]} moves (7, 'o0') to (7, 'moved')"
e="$(cw "${ORIG[1]}" "update cp set b = 'moved' where a = 7 and b = 'o0'")"
check "P4 the key's update is acknowledged" "" "$e"
wait_converged 60 "select count(*) from cp where a = 7 and b = 'moved'" || true
for n in "${NODES[@]}"; do
	check "P4 $n holds the new key, not the old" "1 0" \
		"$(qt "$n" "select (select count(*) from cp where a = 7 and b = 'moved')||' '||(select count(*) from cp where a = 7 and b = 'o0')")"
done
settle P4

# ── P5: a DELETE by the composite key ───────────────────────────────────────
echo "  -- P5: ${ORIG[2]} deletes (8, 'o1')"
e="$(cw "${ORIG[2]}" "delete from cp where a = 8 and b = 'o1'")"
check "P5 the delete is acknowledged" "" "$e"
wait_converged 60 "select count(*) from cp where a = 8 and b = 'o1'" || true
for n in "${NODES[@]}"; do
	check "P5 $n no longer holds (8, 'o1')" "0" "$(qt "$n" "select count(*) from cp where a = 8 and b = 'o1'")"
done
same_everywhere P5 cp "$DIGCP" 89
settle P5

# ── P6: a composite key and a composite unique (c, v) beside it ─────────────
echo "  -- P6: 20 rounds, ${ORIG[*]} insert keys of their own with one (c, v) at once (nodes>=1)"
K="insert into cpu values (@R@, @ID@, 'c', @R@)"
race P6 20 "$K" "$K" "$K"
at_most_one P6 23505 40001
same_everywhere P6 cpu "select md5(string_agg(a||':'||b||':'||c||':'||v, ',' order by a, b)) from cpu" 1
settle P6

# ── P7: a composite index, not unique ───────────────────────────────────────
echo "  -- P7: ${ORIG[*]} insert and update by a non-unique index (a, b) at once"
for k in 0 1 2; do
	(
		o="${ORIG[$k]}"
		for i in $(seq 1 15); do
			id=$((k * 1000 + i))
			e="$(cw "$o" "insert into cpi values ($id, $i, 'x', 0)" 30s)"
			[ -z "$e" ] || echo "$(state_of "$e") ${e:0:200}" >> "$TMP/p7.err"
			e="$(cw "$o" "update cpi set v = v + 1 where id = $id and a = $i and b = 'x'" 30s)"
			[ -z "$e" ] || echo "$(state_of "$e") ${e:0:200}" >> "$TMP/p7.err"
		done
	) &
done
for p in $(jobs -p); do wait "$p" || true; done
check "P7 no write refused" "0" "$(lines "$TMP/p7.err")"
[ "$(lines "$TMP/p7.err")" = 0 ] || echo "     first refusal: $(head -1 "$TMP/p7.err")"
same_everywhere P7 cpi "select md5(string_agg(id::text||':'||a||':'||b||':'||v, ',' order by id)) from cpi" 45
check "P7 every row updated once" "45" "$(qt "$REF" "select count(*) from cpi where v = 1")"
settle P7

# ── W1, W2: the non-PK sync warning ─────────────────────────────────────────
echo "  -- W1: a keyless table written to - a warning alert on its origin, once"
O="${ORIG[1]}"
for i in 1 2 3; do cw "$O" "insert into ckl values ($i, $i)" >/dev/null; done
alerts() { # alerts <node> <table> <detail pattern> -> how many config warnings name it
	qt "$1" "select count(*) from public.yt_alert where source = 'config' and class = 2 \
		and subject like '%.public.$2' and detail like '$3'"
}
seen=""
for _i in $(seq 1 20); do seen="$(alerts "$O" ckl '%no primary key%')"; [ "${seen:-0}" -ge 1 ] && break; sleep 1; done
check "W1 $O filed one warning of the keyless ckl" "1" "$seen"
echo "     $(qt "$O" "select subject||': '||detail from public.yt_alert where source = 'config' and subject like '%.public.ckl' limit 1")"

echo "  -- W2: a merge table with a unique key beside its primary key"
cw "$O" "insert into cpm values (1, 'm', 'k1', '{\"x\": 1}')" >/dev/null
seen=""
for _i in $(seq 1 20); do seen="$(alerts "$O" cpm '%merge table%cpm_k_key%')"; [ "${seen:-0}" -ge 1 ] && break; sleep 1; done
check "W2 $O filed a warning of the merge table cpm naming its key" "1" "$seen"
check "W2 no warning of cpu: a plain table's unique key is probed" "0" "$(alerts "${ORIG[0]}" cpu '%')"
check "W2 no warning of cp: keyed by its primary key alone" "0" "$(alerts "${ORIG[0]}" cp '%')"

cleanup
summary
