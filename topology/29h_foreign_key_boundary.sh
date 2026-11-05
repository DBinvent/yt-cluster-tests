#!/usr/bin/env bash
# [fk] A foreign key ties a child's write to its parent row's (YT Cluster's problems.md P4,
# ytserv/checkin.md section 2c): a child's INSERT or re-reference names the parent key it
# references, a parent's DELETE, re-key or TRUNCATE the key it takes away, and the leader
# compares the two across the tables - committed and exactly the key, 23503 (what one
# PostgreSQL answers); a parent's key that cascades, or a key maybe the one, 40001 behind;
# in flight, 40001. Before, both were admitted: a member applying the child after the
# parent's delete failed the key (`cluster_apply fail`), or a party waited on the other's
# row across nodes until a timeout (55P03, 08006).
#
# Written 2026-10-28 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   F1   fp1/fc1, cluster_commit=nodes>=1, 30 rounds: $REF inserts parent r and waits until
#        every node holds it; then one origin deletes r while another inserts a child of r,
#        0-50 ms apart. Never both acknowledged, every refusal 23503 or 40001, no orphan on
#        any node, every node identical, no `cluster_apply fail`
#   F1b  F1 under the default party: no 55P03, no 08006; each round <= 10 s
#   F2   ON DELETE CASCADE: no orphan, every refusal 23503 or 40001, nodes identical (both
#        may stand - the child first, the cascade after)
#   F3   a re-key `update fp4 set id = id + 1000` under ON UPDATE CASCADE against a child's
#        insert: no orphan, nodes identical
#   F4   a self-referencing tree: a node deleted while a child of it is inserted - never both
#   F5   a composite key to a unique key other than the primary one (a parent's DELETE
#        sends its primary key only: maybe any child's, every stripe) - never both, 40001 or
#        23503 only
#   F6   liveness: three origins insert children of their own parents for 30 s - >= 95 %
#        acknowledged, no refusal
#
# fw: the writability probe.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== foreign key boundary: a child's write against its parent's =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 3 ] || { bad "needs three non-spare nodes, has ${#VOTERS[@]}"; summary; }
ORIG=( "${VOTERS[@]:0:3}" )
REF="${VOTERS[0]}"

# ── helpers (as 29e_unique_boundary.sh's) ───────────────────────────────────
qx() {
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"; }
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
everywhere() { # everywhere <secs> <sql> <want> -> 0 once every node answers <want>
	local deadline=$((SECONDS + $1)) n all
	while :; do
		all=1
		for n in "${NODES[@]}"; do [ "$(qt "$n" "$2")" = "$3" ] || { all=0; break; }; done
		[ "$all" = 1 ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 1
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
same_everywhere() {
	local n
	wait_converged 90 "$3" || true
	for n in "${NODES[@]}"; do
		[ "$n" = "$REF" ] && continue
		check_same "$1 $n is identical to $REF" "$REF" "$n" "$3" "$4" "$2"
	done
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
no_orphan() { # no_orphan <label> <orphan-count sql>
	local n c
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "$2")"
		check "$1 no orphan on $n" "0" "${c:-?}"
	done
}

TABLES="fc1 fp1 fc2 fp2 fc3 fp3 fc4 fp4 ft fc5 fp5 fc6 fp6 fw"
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
			q "$n" "drop table if exists $t cascade" >/dev/null 2>&1
			cfg_delete "$n" "public.$t" A >/dev/null 2>&1
		done
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
ONE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
[ -n "$ONE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists fc1, fp1, fc2, fp2, fc3, fp3, fc4, fp4, ft, fc5, fp5, fc6, fp6, fw cascade;
	        create table fp1 (id bigint primary key);
	        create table fc1 (id bigint primary key, pid bigint references fp1 (id));
	        create table fp2 (id bigint primary key);
	        create table fc2 (id bigint primary key, pid bigint references fp2 (id));
	        create table fp3 (id bigint primary key);
	        create table fc3 (id bigint primary key, pid bigint references fp3 (id) on delete cascade);
	        create table fp4 (id bigint primary key);
	        create table fc4 (id bigint primary key, pid bigint references fp4 (id) on update cascade);
	        create table ft (id bigint primary key, parent bigint references ft (id));
	        create table fp5 (id bigint primary key, a int, b text, unique (a, b));
	        create table fc5 (id bigint primary key, a int, b text, foreign key (a, b) references fp5 (a, b));
	        create table fp6 (id bigint primary key);
	        create table fc6 (id bigint primary key, pid bigint references fp6 (id));
	        create table fw (id bigint primary key, v text);" >/dev/null
done
for t in fp1 fc1 fp3 fc3 fp4 fc4 ft fp5 fc5; do register_table "public.$t" "$ONE_CFG"; done
for t in fp2 fc2 fp6 fc6 fw; do register_table "public.$t"; done
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" fw || { bad "cluster never became writable"; summary; }
cw "$REF" "insert into fw values (1, 'term')" >/dev/null
everywhere 60 "select count(*) from fw where id = 1" 1 || bad "setup: a node never applied the guard's write of the term"
settle() {
	wait_writable "$REF" "${VOTERS[1]}" fw >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

# pair <label> <rounds> <parent sql> <parent-held sql> <remove sql> <child sql> -> per round:
# $REF writes the parent and waits for every node to hold it; then ORIG[1] removes it while
# ORIG[2] writes a child of it, 0-50 ms apart. @R@ is the round. $TMP/<label>.both (rounds
# both acknowledged), .err (state message), .secs
pair() {
	local L="$1" rounds="$2" mk="$3" held="$4" rm_sql="$5" ch="$6" r t0 d1 d2 a b
	rm -f "$TMP/$L".*
	for r in $(seq 1 "$rounds"); do
		cw "$REF" "${mk//@R@/$r}" >/dev/null
		everywhere 30 "${held//@R@/$r}" 1 || echo "$r - parent not everywhere" >> "$TMP/$L.err"
		d1="0.0$((RANDOM % 5))$((RANDOM % 10))"; d2="0.0$((RANDOM % 5))$((RANDOM % 10))"
		t0=$SECONDS
		( sleep "$d1"; e="$(cw "${ORIG[1]}" "${rm_sql//@R@/$r}" 30s)"; echo "${e:-ok}" > "$TMP/$L.$r.rm" ) &
		( sleep "$d2"; e="$(cw "${ORIG[2]}" "${ch//@R@/$r}" 30s)"; echo "${e:-ok}" > "$TMP/$L.$r.ch" ) &
		wait
		echo "$((SECONDS - t0))" >> "$TMP/$L.secs"
		a="$(cat "$TMP/$L.$r.rm")"; b="$(cat "$TMP/$L.$r.ch")"
		[ "$a" = ok ] && [ "$b" = ok ] && echo "$r" >> "$TMP/$L.both"
		for x in "$a" "$b"; do [ "$x" = ok ] || echo "$r $(state_of "$x") ${x:0:200}" >> "$TMP/$L.err"; done
	done
}
other_refusals() {
	local f="$1"; shift
	[ -f "$f" ] || return 0
	local ok_re; ok_re="$(printf '%s|' "$@")"; ok_re="${ok_re%|}"
	awk -v re="^($ok_re)\$" '$2 !~ re { $1=""; print substr($0, 2) }' "$f"
}
refusals_ok() { # refusals_ok <label> <states...>
	local L="$1"; shift
	local b; b="$(other_refusals "$TMP/$L.err" "$@")"
	[ -z "$b" ] && ok "$L every refusal $* ($(lines "$TMP/$L.err"))" \
		|| bad "$L refusals other than $*: $(printf '%s\n' "$b" | head -3)"
}

# ── F1, F1b: NO ACTION ───────────────────────────────────────────────────────
f1() { # f1 <label> <n>
	local L="$1" n="$2" T0 slowest
	echo "  -- $L: 30 rounds, ${ORIG[1]} deletes a parent while ${ORIG[2]} inserts a child of it"
	T0="$(host_now)"
	pair "$L" 30 "insert into fp$n values (@R@)" "select count(*) from fp$n where id = @R@" \
		"delete from fp$n where id = @R@" "insert into fc$n values (@R@, @R@)"
	check "$L never both acknowledged" "0" "$(lines "$TMP/$L.both")"
	refusals_ok "$L" 23503 40001
	no_orphan "$L" "select count(*) from fc$n c left join fp$n p on p.id = c.pid where c.pid is not null and p.id is null"
	same_everywhere "$L" "fc$n" "select coalesce(md5(string_agg(id::text||':'||pid, ',' order by id)), '-') from fc$n" 0
	same_everywhere "$L" "fp$n" "select coalesce(md5(string_agg(id::text, ',' order by id)), '-') from fp$n" 0
	check "$L no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
	if [ "$n" = 2 ]; then
		slowest="$(sort -n "$TMP/$L.secs" 2>/dev/null | tail -1)"
		[ "${slowest:-99}" -le 10 ] && ok "$L each round over within seconds (slowest ${slowest} s)" \
			|| bad "$L a round took ${slowest:-?} s - a writer waited on another node's row"
	fi
	settle "$L"
}
f1 F1 1
f1 F1b 2

# ── F2: ON DELETE CASCADE ────────────────────────────────────────────────────
echo "  -- F2: 30 rounds as F1, ON DELETE CASCADE"
T0="$(host_now)"
pair F2 30 "insert into fp3 values (@R@)" "select count(*) from fp3 where id = @R@" \
	"delete from fp3 where id = @R@" "insert into fc3 values (@R@, @R@)"
refusals_ok F2 23503 40001
no_orphan F2 "select count(*) from fc3 c left join fp3 p on p.id = c.pid where c.pid is not null and p.id is null"
same_everywhere F2 fc3 "select coalesce(md5(string_agg(id::text||':'||pid, ',' order by id)), '-') from fc3" 0
check "F2 no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
settle F2

# ── F3: a re-key under ON UPDATE CASCADE ─────────────────────────────────────
echo "  -- F3: 30 rounds, ${ORIG[1]} re-keys a parent while ${ORIG[2]} inserts a child of its old key"
T0="$(host_now)"
pair F3 30 "insert into fp4 values (@R@)" "select count(*) from fp4 where id = @R@" \
	"update fp4 set id = id + 1000 where id = @R@" "insert into fc4 values (@R@, @R@)"
refusals_ok F3 23503 40001
no_orphan F3 "select count(*) from fc4 c left join fp4 p on p.id = c.pid where c.pid is not null and p.id is null"
same_everywhere F3 fc4 "select coalesce(md5(string_agg(id::text||':'||pid, ',' order by id)), '-') from fc4" 0
same_everywhere F3 fp4 "select coalesce(md5(string_agg(id::text, ',' order by id)), '-') from fp4" 1
check "F3 no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
settle F3

# ── F4: a self-referencing tree ──────────────────────────────────────────────
echo "  -- F4: 30 rounds, ${ORIG[1]} deletes a tree node while ${ORIG[2]} inserts a child of it"
cw "$REF" "insert into ft values (0, null)" >/dev/null
pair F4 30 "insert into ft values (@R@, 0)" "select count(*) from ft where id = @R@" \
	"delete from ft where id = @R@" "insert into ft values (@R@ + 1000, @R@)"
check "F4 never both acknowledged" "0" "$(lines "$TMP/F4.both")"
refusals_ok F4 23503 40001
no_orphan F4 "select count(*) from ft c left join ft p on p.id = c.parent where c.parent is not null and p.id is null"
same_everywhere F4 ft "select md5(string_agg(id::text||':'||coalesce(parent::text, '~'), ',' order by id)) from ft" 1
settle F4

# ── F5: a composite key to a unique key other than the primary one ──────────
echo "  -- F5: 20 rounds, ${ORIG[1]} deletes a parent while ${ORIG[2]} inserts a child of its (a, b)"
pair F5 20 "insert into fp5 values (@R@, @R@, 'k@R@')" "select count(*) from fp5 where id = @R@" \
	"delete from fp5 where id = @R@" "insert into fc5 values (@R@, @R@, 'k@R@')"
check "F5 never both acknowledged" "0" "$(lines "$TMP/F5.both")"
refusals_ok F5 23503 40001
no_orphan F5 "select count(*) from fc5 c left join fp5 p on p.a = c.a and p.b = c.b where c.a is not null and c.b is not null and p.id is null"
same_everywhere F5 fc5 "select coalesce(md5(string_agg(id::text||':'||a||':'||b, ',' order by id)), '-') from fc5" 0
settle F5

# ── F6: children of different parents never meet ───────────────────────────
echo "  -- F6: 30 s, ${ORIG[*]} insert children of their own parents"
cw "$REF" "insert into fp6 values (1), (2), (3)" >/dev/null
everywhere 30 "select count(*) from fp6" 3 || bad "F6 setup: a node lacks the parents"
for k in 0 1 2; do
	(
		o="${ORIG[$k]}"; end=$((SECONDS + 30)); i=0
		while [ "$SECONDS" -lt "$end" ]; do
			i=$((i + 1))
			e="$(cw "$o" "insert into fc6 values ($((k * 100000 + i)), $((k + 1)))" 20s)"
			if [ -z "$e" ]; then echo "$i" >> "$TMP/f6.$k.ok"; else echo "$i $(state_of "$e") ${e:0:200}" >> "$TMP/f6.$k.err"; fi
		done
	) &
done
wait
f6_ok=$(( $(lines "$TMP/f6.0.ok") + $(lines "$TMP/f6.1.ok") + $(lines "$TMP/f6.2.ok") ))
f6_err=$(( $(lines "$TMP/f6.0.err") + $(lines "$TMP/f6.1.err") + $(lines "$TMP/f6.2.err") ))
f6_try=$((f6_ok + f6_err))
echo "     child inserts: $f6_try, acknowledged $f6_ok, refused $f6_err"
[ "$f6_try" -ge 30 ] && ok "F6 $f6_try child inserts attempted" || bad "F6 only $f6_try child inserts attempted"
[ "$f6_try" -gt 0 ] && [ $((f6_ok * 100)) -ge $((f6_try * 95)) ] \
	&& ok "F6 >= 95 % acknowledged ($f6_ok of $f6_try)" \
	|| bad "F6 $f6_ok of $f6_try acknowledged - first refusal: $(cat "$TMP"/f6.*.err 2>/dev/null | head -1)"
check "F6 no refusal" "0" "$f6_err"
same_everywhere F6 fc6 "select md5(string_agg(id::text||':'||pid, ',' order by id)) from fc6" 1

cleanup
summary
