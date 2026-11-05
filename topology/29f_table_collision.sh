#!/usr/bin/env bash
# [bg-pull] A table-level collision is refused 40001 at once, and the pull runs in the
# background (YT Cluster's problems.md P5, ytserv/checkin.md section 1). Before, the
# leader answered data_loss: the origin pulled what it lacked and checked in again, up to
# three times, inside the statement - whose rows the pulled write's apply waited on, until
# lock_timeout or statement_timeout (55P03, 08006), or 08006 "Requered to run table level
# transactions" after the third pull. A statement's own transaction is no collision
# ([own-tx]), and two INSERTs of a keyless table no key ties are none either ([keys-only]).
#
# Written 2026-10-28 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   T1   tc(id pk, a, b, unique (a, b)), the default party: three origins for 30 s, each
#        `begin; update a; pg_sleep(0.2); update b; commit` on its own row - an UPDATE of a
#        composite key's column, the table. Every refusal 40001 (no 55P03, no 08006), the
#        slowest transaction <= 10 s, no "tryign to load data" logged since the start (the
#        pull inside the statement), no `cluster_apply fail`, every node identical; and a
#        two-row update in one transaction acknowledged (its own transaction, F2)
#   T1b  T1 under cluster_commit=nodes>=1
#   T2   tk(at, msg), no key at all: three origins insert at once, 30 rounds. Every refusal
#        40001; with [keys-only] all 90 acknowledged; every node holds 90 rows
#
# tc (T1), tc1 (T1b, nodes>=1), tk (T2), tw: the writability probe.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== table collision: 40001 at once, the pull in the background =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 3 ] || { bad "needs three non-spare nodes, has ${#VOTERS[@]}"; summary; }
ORIG=( "${VOTERS[@]:0:3}" )
REF="${VOTERS[0]}"

# ── helpers (as 29e_unique_boundary.sh's) ───────────────────────────────────
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
logged_since() { # logged_since <unix-ts> <fixed string> -> lines of it every node logged since
	local n c total=0
	for n in "${NODES[@]}"; do
		c="$(rh "docker logs --since $1 $n 2>&1 | grep -cF '$2'" 2>/dev/null || true)"
		case "$c" in ''|*[!0-9]*) c=0 ;; esac
		total=$((total + c))
	done
	echo "$total"
}
same_everywhere() { # same_everywhere <label> <table> <digest-sql> <min rows>
	local n
	wait_converged 90 "$3" || true
	for n in "${NODES[@]}"; do
		[ "$n" = "$REF" ] && continue
		check_same "$1 $n is identical to $REF" "$REF" "$n" "$3" "$4" "$2"
	done
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
other_refusals() { # other_refusals <err file> <state...> -> refusals of any other SQLSTATE
	local f="$1"; shift
	[ -f "$f" ] || return 0
	local ok_re; ok_re="$(printf '%s|' "$@")"; ok_re="${ok_re%|}"
	awk -v re="^($ok_re)\$" '$2 !~ re { $1=""; print substr($0, 2) }' "$f"
}

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
		q "$n" "drop table if exists tc; drop table if exists tc1; drop table if exists tk; drop table if exists tw;" >/dev/null 2>&1
		for t in tc tc1 tk tw; do cfg_delete "$n" "public.$t" A >/dev/null 2>&1; done
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
ONE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
[ -n "$ONE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists tc; create table tc (id bigint primary key, a bigint, b bigint, unique (a, b));
	        drop table if exists tc1; create table tc1 (id bigint primary key, a bigint, b bigint, unique (a, b));
	        drop table if exists tk; create table tk (at text, msg text);
	        drop table if exists tw; create table tw (id bigint primary key, v text);" >/dev/null
done
register_table public.tc
register_table public.tc1 "$ONE_CFG"
register_table public.tk
register_table public.tw
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" tw || { bad "cluster never became writable"; summary; }
# every node holds a write of the leader's term before the races (29e's [P3] guard)
cw "$REF" "insert into tw values (1, 'term')" >/dev/null
for _i in $(seq 1 30); do
	_all=1
	for n in "${NODES[@]}"; do [ "$(qt "$n" "select count(*) from tw where id = 1")" = 1 ] || _all=0; done
	[ "$_all" = 1 ] && break
	sleep 2
done
[ "$_all" = 1 ] || bad "setup: a node never applied the guard's write of the term"
settle() {
	wait_writable "$REF" "${VOTERS[1]}" tw >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

# rows 1-3 and 11-13, one per origin, and two more for the two-row update
for tbl in tc tc1; do
	cw "$REF" "insert into $tbl values (1, 1, 0), (2, 2, 0), (3, 3, 0), (11, 11, 0), (12, 12, 0)" >/dev/null
done
wait_converged 60 "select count(*) from tc1 where id in (1, 2, 3, 11, 12)" || true

# ups <table> <secs> -> each origin updates a, then b, of its own row for <secs>;
# $TMP/<table>.ok, .err (state message), .secs (each transaction's seconds)
ups() {
	local tbl="$1" secs="$2" k
	rm -f "$TMP/$tbl".*
	for k in 0 1 2; do
		(
			o="${ORIG[$k]}"; id=$((k + 1)); end=$((SECONDS + secs)); i=0
			while [ "$SECONDS" -lt "$end" ]; do
				i=$((i + 1)); t0=$SECONDS
				e="$(cw "$o" "update $tbl set a = $((id * 1000000 + i)) where id = $id; select pg_sleep(0.2);
					update $tbl set b = $i where id = $id" 30s)"
				echo "$((SECONDS - t0))" >> "$TMP/$tbl.secs"
				if [ -z "$e" ]; then echo "$i" >> "$TMP/$tbl.ok"
				else echo "$i $(state_of "$e") ${e:0:200}" >> "$TMP/$tbl.err"; fi
			done
		) &
	done
	wait
}

t1() { # t1 <label> <table>
	local L="$1" tbl="$2" acked refused slowest bad1 T0
	echo "  -- $L: 30 s, ${ORIG[*]} update a, then b, of their own rows of $tbl"
	T0="$(host_now)"
	ups "$tbl" 30
	acked="$(lines "$TMP/$tbl.ok")"; refused="$(lines "$TMP/$tbl.err")"
	slowest="$(sort -n "$TMP/$tbl.secs" 2>/dev/null | tail -1)"
	echo "     acknowledged $acked, refused $refused, slowest ${slowest:-?} s"
	[ "$acked" -ge 3 ] && ok "$L transactions commit ($acked acknowledged)" \
		|| bad "$L only $acked transactions acknowledged in 30 s"
	bad1="$(other_refusals "$TMP/$tbl.err" 40001)"
	[ -z "$bad1" ] && ok "$L every refusal 40001 ($refused) - no 55P03, no 08006" \
		|| bad "$L refusals other than 40001: $(printf '%s\n' "$bad1" | head -3)"
	[ "${slowest:-99}" -le 10 ] && ok "$L the slowest transaction took ${slowest} s" \
		|| bad "$L a transaction took ${slowest:-?} s - a statement waited"
	check "$L no pull inside a statement logged" "0" "$(logged_since "$T0" 'tryign to load data')"
	check "$L no 'cluster_apply fail' logged" "0" "$(logged_since "$T0" 'cluster_apply fail')"
	# F2: one transaction's two statements of the table: its own, no collision
	e="$(cw "$REF" "update $tbl set b = b + 1 where id = 11; update $tbl set b = b + 1 where id = 12" 30s)"
	check "$L a two-row update in one transaction is acknowledged" "" "$e"
	same_everywhere "$L" "$tbl" "select md5(string_agg(id::text||':'||coalesce(a::text,'~')||':'||coalesce(b::text,'~'), ',' order by id)) from $tbl" 5
	settle "$L"
}

# ── T1, T1b ──────────────────────────────────────────────────────────────────
t1 T1 tc
t1 T1b tc1

# ── T2: keyless INSERTs from three origins ──────────────────────────────────
echo "  -- T2: 30 rounds, ${ORIG[*]} insert into a keyless table at once"
rm -f "$TMP"/tk.*
for r in $(seq 1 30); do
	for k in 0 1 2; do
		o="${ORIG[$k]}"
		d="0.0$((RANDOM % 5))$((RANDOM % 10))"
		(
			sleep "$d"
			e="$(cw "$o" "insert into tk values ('r$r', '$o')" 30s)"
			if [ -z "$e" ]; then echo "$r $o" >> "$TMP/tk.ok"
			else echo "$r $(state_of "$e") ${e:0:200}" >> "$TMP/tk.err"; fi
		) &
	done
	wait
done
acked="$(lines "$TMP/tk.ok")"; refused="$(lines "$TMP/tk.err")"
echo "     acknowledged $acked of 90, refused $refused"
bad2="$(other_refusals "$TMP/tk.err" 40001)"
[ -z "$bad2" ] && ok "T2 every refusal 40001 ($refused)" \
	|| bad "T2 refusals other than 40001: $(printf '%s\n' "$bad2" | head -3)"
check "T2 every insert acknowledged - two INSERTs no key ties never collide" 90 "$acked"
same_everywhere T2 tk "select md5(string_agg(at||':'||msg, ',' order by at, msg)) from tk" "$acked"
check "T2 $REF holds every acknowledged row" "$acked" "$(qt "$REF" "select count(*) from tk")"

cleanup
summary
