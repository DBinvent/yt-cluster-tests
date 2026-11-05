#!/usr/bin/env bash
# [canon] A composite, inexact, partial, expression or exclusion key is compared by its
# canonical value (YT Cluster's problems.md P6, ytserv/checkin.md section 2): the origin
# lists the key with its columns' kinds, the leader makes each value one text - numeric
# 1.5 = 1.50, one instant under two time zones, bpchar's trailing spaces - and refuses
# another node's write of the same value on another row: committed and exactly it, 23505;
# maybe it (an unsent column, an OPAQUE kind, a predicate, an exclusion), 40001 behind; in
# flight, 40001. Before, two INSERTs of one such value were both admitted - under
# nodes>=1 each node kept the row it applied first.
#
# Written 2026-10-28 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   K1   ck(id pk, a int, b text, unique (a, b)), cluster_commit=nodes>=1: 30 rounds,
#        three origins insert one (a, b) under three ids at once. No round acknowledged
#        twice, the acknowledged rows are the rows, every refusal 23505 or 40001, every
#        node identical, no `cluster_apply fail`
#   K1b  K1 under the default party: no 55P03, no 08006; each round <= 10 s
#   K2   kn(id pk, v numeric(12,2) unique), nodes>=1: 1.5, 1.50 and 1.500 at once, 20
#        rounds - at most one a round
#   K3   kp(id pk, email text, deleted_at timestamptz), unique (email) where deleted_at
#        is null, nodes>=1: a racing pair, at most one acknowledged; an email soft-deleted
#        and inserted again is acknowledged
#   K4   kl(id pk, email text), unique (lower(email)), nodes>=1: 'A@x', 'a@x', 'a@X' at
#        once, 20 rounds - at most one a round, refusals 40001 - or the origin's own index's
#        23505 (PostgreSQL's message), never the leader's
#   K5   kx(id pk, room int, during tsrange, exclude using gist (during with &&)),
#        nodes>=1: overlapping ranges at once, 20 rounds - at most one a round
#   K6   ku(id pk, a int, b int, note text, unique (a, b)), the default party: one origin
#        updates `note` of rows 1-10, two set `b` of rows 11-30 to fresh values: none
#        refused as a table-level collision, >= 95 % acknowledged
#   K7   kt(id pk, at timestamptz unique), nodes>=1: one origin under DateStyle 'SQL, DMY',
#        two under ISO, one instant at once, 20 rounds - at most one a round, refusals
#        23505 or 40001
#
# kw: the writability probe.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== composite unique: a key's canonical value =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 3 ] || { bad "needs three non-spare nodes, has ${#VOTERS[@]}"; summary; }
ORIG=( "${VOTERS[@]:0:3}" )
REF="${VOTERS[0]}"

# ── helpers (as 29e_unique_boundary.sh's) ───────────────────────────────────
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

TABLES="ck ck2 kn kp kl kx ku kt kw"
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
[ -n "$ONE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists ck; create table ck (id bigint primary key, a int, b text, unique (a, b));
	        drop table if exists ck2; create table ck2 (id bigint primary key, a int, b text, unique (a, b));
	        drop table if exists kn; create table kn (id bigint primary key, v numeric(12,2) unique);
	        drop table if exists kp; create table kp (id bigint primary key, email text, deleted_at timestamptz);
	        create unique index kp_live on kp (email) where deleted_at is null;
	        drop table if exists kl; create table kl (id bigint primary key, email text);
	        create unique index kl_lower on kl (lower(email));
	        drop table if exists kx; create table kx (id bigint primary key, room int, during tsrange,
	          exclude using gist (during with &&));
	        drop table if exists ku; create table ku (id bigint primary key, a int, b int, note text, unique (a, b));
	        drop table if exists kt; create table kt (id bigint primary key, at timestamptz unique);
	        drop table if exists kw; create table kw (id bigint primary key, v text);" >/dev/null
done
register_table public.ck "$ONE_CFG"
register_table public.ck2
register_table public.kn "$ONE_CFG"
register_table public.kp "$ONE_CFG"
register_table public.kl "$ONE_CFG"
register_table public.kx "$ONE_CFG"
register_table public.ku
register_table public.kt "$ONE_CFG"
register_table public.kw
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" kw || { bad "cluster never became writable"; summary; }
cw "$REF" "insert into kw values (1, 'term')" >/dev/null
for _i in $(seq 1 30); do
	_all=1
	for n in "${NODES[@]}"; do [ "$(qt "$n" "select count(*) from kw where id = 1")" = 1 ] || _all=0; done
	[ "$_all" = 1 ] && break
	sleep 2
done
[ "$_all" = 1 ] || bad "setup: a node never applied the guard's write of the term"
settle() {
	wait_writable "$REF" "${VOTERS[1]}" kw >/dev/null 2>&1 \
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

# ── K1, K1b: unique (a, b) ───────────────────────────────────────────────────
echo "  -- K1: 30 rounds, ${ORIG[*]} insert one (a, b) at once (nodes>=1)"
T0="$(host_now)"
K="insert into ck values (@ID@, @R@, 'k-@R@')"
race K1 30 "$K" "$K" "$K"
at_most_one K1 23505 40001
DIG1="select md5(string_agg(id::text||':'||a||':'||b, ',' order by id)) from ck"
same_everywhere K1 ck "$DIG1" 1
check "K1 $REF holds exactly the acknowledged rows" "$(acked_ids "$TMP/K1.ok")" \
	"$(qt "$REF" "select string_agg(id::text, ' ' order by id) from ck")"
check "K1 no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
settle K1

echo "  -- K1b: 30 rounds as K1, the default party"
K="insert into ck2 values (@ID@, @R@, 'k-@R@')"
race K1b 30 "$K" "$K" "$K"
at_most_one K1b 23505 40001
slowest="$(sort -n "$TMP/K1b.secs" 2>/dev/null | tail -1)"
[ "${slowest:-99}" -le 10 ] && ok "K1b each round over within seconds (slowest ${slowest} s)" \
	|| bad "K1b a round took ${slowest:-?} s - a writer waited on another node's index entry"
same_everywhere K1b ck2 "select md5(string_agg(id::text||':'||a||':'||b, ',' order by id)) from ck2" 1
settle K1b

# ── K2: numeric 1.5 = 1.50 = 1.500 ───────────────────────────────────────────
echo "  -- K2: 20 rounds, 1.5, 1.50 and 1.500 at once (nodes>=1)"
race K2 20 "insert into kn values (@ID@, @R@.5)" "insert into kn values (@ID@, @R@.50)" "insert into kn values (@ID@, @R@.500)"
at_most_one K2 23505 40001
same_everywhere K2 kn "select md5(string_agg(id::text||':'||v, ',' order by id)) from kn" 1
settle K2

# ── K3: a partial index ──────────────────────────────────────────────────────
echo "  -- K3: 20 rounds, a racing pair under a partial unique index (nodes>=1)"
K="insert into kp values (@ID@, 'p@R@@x', null)"
race K3 20 "$K" "$K" ""
at_most_one K3 23505 40001
e="$(cw "$REF" "update kp set deleted_at = now() where email = 'p1@x'")"
check "K3 a soft delete is acknowledged" "" "$e"
wait_converged 60 "select count(*) from kp where email = 'p1@x' and deleted_at is not null" || true
e="$(cw "${ORIG[1]}" "insert into kp values (9001, 'p1@x', null)")"
check "K3 the soft-deleted email inserted again is acknowledged" "" "$e"
same_everywhere K3 kp "select md5(string_agg(id::text||':'||email||':'||(deleted_at is null), ',' order by id)) from kp" 1
settle K3

# ── K4: an expression's index ───────────────────────────────────────────────
echo "  -- K4: 20 rounds, 'A@x', 'a@x', 'a@X' at once under unique (lower(email)) (nodes>=1)"
race K4 20 "insert into kl values (@ID@, 'A@x@R@')" "insert into kl values (@ID@, 'a@x@R@')" "insert into kl values (@ID@, 'a@X@R@')"
# The leader cannot read an expression's key, so a 23505 of its - "another node committed
# this value" - is never right here. The origin's own index may answer first, though: the
# competing row applied there already, PostgreSQL's own 23505 - correct, and since the
# applies run faster (the internal bus, 2026-10-29) a round now and then (nightly round 5)
sed -i -E 's/^([0-9]+) 23505 (.*duplicate key value violates unique constraint)/\1 23505-own-index \2/' "$TMP/K4.err" 2>/dev/null || true
at_most_one K4 40001 23505-own-index
same_everywhere K4 kl "select md5(string_agg(id::text||':'||email, ',' order by id)) from kl" 1
settle K4

# ── K5: an exclusion constraint ─────────────────────────────────────────────
echo "  -- K5: 20 rounds, overlapping ranges at once (nodes>=1)"
K0="insert into kx values (@ID@, 1, tsrange('2026-01-01'::timestamp + interval '@R@ day', '2026-01-01'::timestamp + interval '@R@ day 2 hours'))"
K1="insert into kx values (@ID@, 1, tsrange('2026-01-01'::timestamp + interval '@R@ day 1 hour', '2026-01-01'::timestamp + interval '@R@ day 3 hours'))"
race K5 20 "$K0" "$K1" "$K0"
at_most_one K5 23P01 40001
same_everywhere K5 kx "select md5(string_agg(id::text||':'||during::text, ',' order by id)) from kx" 1
settle K5

# ── K6: an UPDATE of a composite key's column is its row ────────────────────
echo "  -- K6: ${ORIG[0]} updates note of rows 1-10; ${ORIG[1]} and ${ORIG[2]} set fresh b of rows 11-30"
for i in $(seq 1 30); do cw "$REF" "insert into ku values ($i, $i, 0, 'n0')" >/dev/null; done
wait_converged 60 "select count(*) from ku where id between 1 and 30" || true
(
	end=$((SECONDS + 30)); i=0
	while [ "$SECONDS" -lt "$end" ]; do
		i=$((i + 1))
		cw "${ORIG[0]}" "update ku set note = 'n$i' where id = $((i % 10 + 1))" 20s >/dev/null
	done
) &
NPID=$!
for k in 1 2; do
	(
		o="${ORIG[$k]}"; end=$((SECONDS + 28)); i=0
		while [ "$SECONDS" -lt "$end" ]; do
			i=$((i + 1))
			e="$(cw "$o" "update ku set b = $((k * 100000 + i)) where id = $((10 + k * 10 - (i % 10)))" 20s)"
			if [ -z "$e" ]; then echo "$i" >> "$TMP/k6.$k.ok"; else echo "$(state_of "$e") ${e:0:200}" >> "$TMP/k6.$k.err"; fi
			sleep 0.1
		done
	) &
done
for p in $(jobs -p); do [ "$p" = "$NPID" ] || wait "$p" || true; done
wait "$NPID" || true
k6_ok=$(( $(lines "$TMP/k6.1.ok") + $(lines "$TMP/k6.2.ok") ))
k6_err=$(( $(lines "$TMP/k6.1.err") + $(lines "$TMP/k6.2.err") ))
k6_try=$((k6_ok + k6_err))
k6_table="$(cat "$TMP"/k6.*.err 2>/dev/null | grep -c 'table level' || true)"
echo "     b updates: $k6_try, acknowledged $k6_ok, refused $k6_err"
[ "$k6_try" -ge 20 ] && ok "K6 $k6_try updates of b attempted" || bad "K6 only $k6_try updates of b attempted"
check "K6 no update of b refused as a table-level collision" "0" "${k6_table:-0}"
[ "$k6_try" -gt 0 ] && [ $((k6_ok * 100)) -ge $((k6_try * 95)) ] \
	&& ok "K6 >= 95 % of the updates of b acknowledged ($k6_ok of $k6_try)" \
	|| bad "K6 $k6_ok of $k6_try acknowledged - first refusal: $(cat "$TMP"/k6.*.err 2>/dev/null | head -1)"
same_everywhere K6 ku "select md5(string_agg(id::text||':'||a||':'||b||':'||note, ',' order by id)) from ku" 30
settle K6

# ── K7: one instant under two DateStyles ────────────────────────────────────
echo "  -- K7: 20 rounds, one instant from a 'SQL, DMY' session and two ISO ones (nodes>=1)"
K="insert into kt values (@ID@, '2026-10-01 00:00:00+00'::timestamptz + interval '@R@ minute')"
race K7 20 "$K" "$K" "$K" "-c DateStyle=SQL,DMY"
at_most_one K7 23505 40001
same_everywhere K7 kt "select md5(string_agg(id::text||':'||extract(epoch from at), ',' order by id)) from kt" 1

cleanup
summary
