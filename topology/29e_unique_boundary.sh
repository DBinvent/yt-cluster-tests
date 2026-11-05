#!/usr/bin/env bash
# [uniq] Transaction boundaries, first cut: a one-column exact unique key - a constraint's, or a
# bare `create unique index` as SchemaGuard makes them - takes the boundary of its
# VALUE, not the table (YT Cluster's ytserv/checkin.md). The leader compares the value a
# write gives the key with every other node's write the origin has not applied:
# committed, the write is refused 23505 (what one PostgreSQL says); in flight, 40001
# (the younger retries). Checkins of one value take turns. An UPDATE of such a column
# compares as its row, no longer as the table.
#
# Written 2026-10-28 without a run (no e2e on the shared lab hosts that day); its first
# run is the next nightly.
#
#   U1   (G1, G4) cluster_commit=nodes>=1 - the origin alone, no party row lock to hide
#        a miss: 30 rounds, three origins insert different ids with one email at once,
#        0-50 ms apart. No email acknowledged twice, the acknowledged rows are the rows,
#        every refusal 23505 or 40001, every node identical, no `cluster_apply fail`
#   U1b  U1 under the default party: no lock wait across nodes - no 55P03 or 08006,
#        only 23505 and 40001 - and each round over within seconds
#   U2   (narrowing) one origin updates `note` of rows 1-10 in a loop while two others
#        set `code` - a unique constraint's column - of other rows to fresh values:
#        >= 20 such updates, none refused as "table level transactions", >= 95 %
#        acknowledged, every node identical
#   U3   two origins set one `code` on two rows at once, 10 rounds, nodes>=1 - no party node
#        whose own index would stop the second: at most one of each pair acknowledged,
#        every node identical
#   U4   three origins insert NULL emails at once (a nullable unique key), 10 rounds:
#        every one acknowledged - two NULLs never collide
#
# uq_t (U1) and uq_n (U4): a bare unique index, nodes>=1. uq_d (U1b): the same as uq_t,
# the default party. uq_c (U2): a unique constraint, the default party. uq_e (U3): a
# unique constraint, nodes>=1. uq_w: no
# key but the primary one - the writability probe (wait_writable writes one value
# again and again, which a unique key would refuse).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== unique boundary: a unique key's value, not the table =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
[ "${#VOTERS[@]}" -ge 3 ] || { bad "needs three non-spare nodes, has ${#VOTERS[@]}"; summary; }
ORIG=( "${VOTERS[@]:0:3}" )
REF="${VOTERS[0]}"

# ── helpers (local, as 29_concurrent.sh's: env.sh's q discards stderr) ──────
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
# the SQLSTATE from its own field (37_delta_retry.sh), "-" for an error without one
state_of() {
	local s
	s="$(printf '%s\n' "$1" | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' | head -1)"
	printf '%s' "${s:--}"
}
qt() { # env.sh's q plus a statement_timeout, so a wedged ytserv cannot hang a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
# wait_converged <secs> <digest-sql> -> 0 once every node returns the same, non-empty digest
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
apply_fails_since() { # `cluster_apply fail` lines logged by every node since <unix-ts>
	local n c total=0
	for n in "${NODES[@]}"; do
		c="$(rh "docker logs --since $1 $n 2>&1 | grep -c 'cluster_apply fail'" 2>/dev/null || true)"
		case "$c" in ''|*[!0-9]*) c=0 ;; esac
		total=$((total + c))
	done
	echo "$total"
}
# A value twice on one node is no check here - every node's unique index refuses it.
# What a miss leaves is two writes of one value acknowledged, each node holding the one
# it applied first (the apply's `on conflict do nothing`): two acknowledgements of one
# round, rows other than the acknowledged ones, nodes that differ.
# twice <ok file> -> the rounds acknowledged more than once
twice() {
	[ -f "$1" ] || return 0
	cut -d' ' -f1 "$1" | sort | uniq -d | tr '\n' ' ' | sed 's/ $//'
}
# acked_ids <ok file> -> the acknowledged ids, ascending, one line
acked_ids() {
	[ -f "$1" ] || return 0
	cut -d' ' -f2 "$1" | sort -n | tr '\n' ' ' | sed 's/ $//'
}
same_everywhere() { # same_everywhere <label> <table> <digest-sql> <min rows>
	local n
	wait_converged 90 "$3" || true
	for n in "${NODES[@]}"; do
		[ "$n" = "$REF" ] && continue
		check_same "$1 $n is identical to $REF" "$REF" "$n" "$3" "$4" "$2"
	done
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
		q "$n" "drop table if exists uq_t; drop table if exists uq_d; drop table if exists uq_c;
		        drop table if exists uq_e; drop table if exists uq_n; drop table if exists uq_w;" >/dev/null 2>&1
		for t in uq_t uq_d uq_c uq_e uq_n uq_w; do cfg_delete "$n" "public.$t" A >/dev/null 2>&1; done
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

# ── setup ────────────────────────────────────────────────────────────────────
ONE_CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
[ -n "$ONE_CFG" ] || { bad "ytctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists uq_t; create table uq_t (id bigint primary key, email text not null, note text);
	        create unique index uq_t_email on uq_t (email);
	        drop table if exists uq_d; create table uq_d (id bigint primary key, email text not null, note text);
	        create unique index uq_d_email on uq_d (email);
	        drop table if exists uq_c; create table uq_c (id bigint primary key, code text unique, note text);
	        drop table if exists uq_e; create table uq_e (id bigint primary key, code text unique, note text);
	        drop table if exists uq_n; create table uq_n (id bigint primary key, email text, note text);
	        create unique index uq_n_email on uq_n (email);
	        drop table if exists uq_w; create table uq_w (id bigint primary key, v text);" >/dev/null
done
# all before ONE restart: a module-A row is read by the startup loader
register_table public.uq_t "$ONE_CFG"
register_table public.uq_d
register_table public.uq_c
register_table public.uq_e "$ONE_CFG"
register_table public.uq_n "$ONE_CFG"
register_table public.uq_w
restart_all
await_cluster
wait_writable "$REF" "${VOTERS[1]}" uq_w || { bad "cluster never became writable"; summary; }
# [P3] a node that holds no write of the leader's term is not compared with that term's
# writes (yt-pgxt problems.md P3, its own case): every node holds one before the races
cw "$REF" "insert into uq_w values (1, 'term')" >/dev/null
for _i in $(seq 1 30); do
	_all=1
	for n in "${NODES[@]}"; do [ "$(qt "$n" "select count(*) from uq_w where id = 1")" = 1 ] || _all=0; done
	[ "$_all" = 1 ] && break
	sleep 2
done
[ "$_all" = 1 ] || bad "setup: a node never applied the guard's write of the term"
settle() {
	wait_writable "$REF" "${VOTERS[1]}" uq_w >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

# race <table> <rounds> <id base> <value sql> -> three origins insert at once, round after
# round; $TMP/<table>.ok (round id), .err (round state message), .secs (round seconds)
race() {
	local tbl="$1" rounds="$2" base="$3" val="$4" r k o id e t0 pids d
	rm -f "$TMP/$tbl".*
	for r in $(seq 1 "$rounds"); do
		pids=(); t0=$SECONDS
		for k in 0 1 2; do
			o="${ORIG[$k]}"; id=$((base + r * 10 + k))
			d="0.0$((RANDOM % 5))$((RANDOM % 10))" # drawn here: a subshell may repeat the parent's
			(
				sleep "$d"
				e="$(cw "$o" "insert into $tbl values ($id, ${val//@R@/$r}, 'u-$o')" 30s)"
				if [ -z "$e" ]; then echo "$r $id" >> "$TMP/$tbl.ok"
				else echo "$r $(state_of "$e") ${e:0:200}" >> "$TMP/$tbl.err"; fi
			) &
			pids+=($!)
		done
		for p in "${pids[@]}"; do wait "$p" || true; done
		echo "$((SECONDS - t0))" >> "$TMP/$tbl.secs"
	done
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# refusals whose SQLSTATE is not one of <states...>, as "state: message" lines
other_refusals() {
	local f="$1"; shift
	[ -f "$f" ] || return 0
	local ok_re; ok_re="$(printf '%s|' "$@")"; ok_re="${ok_re%|}"
	awk -v re="^($ok_re)\$" '$2 !~ re { $1=""; print substr($0, 2) }' "$f"
}

# ── U1: one email from three origins at once, nodes>=1 ──────────────────────
echo "  -- U1: 30 rounds, ${ORIG[*]} insert one email at once (nodes>=1)"
T0="$(host_now)"
race uq_t 30 0 "'u1-@R@@x'"
acked="$(lines "$TMP/uq_t.ok")"; refused="$(lines "$TMP/uq_t.err")"
echo "     acknowledged $acked of 90, refused $refused"
[ "$acked" -ge 15 ] \
	&& ok "U1 the first writer of an email commits ($acked acknowledgements in 30 rounds)" \
	|| bad "U1 only $acked acknowledgements in 30 rounds - the case under test hardly happened"
bad1="$(other_refusals "$TMP/uq_t.err" 23505 40001)"
[ -z "$bad1" ] && ok "U1 every refusal is 23505 or 40001 ($refused)" \
	|| bad "U1 refusals other than 23505/40001: $(printf '%s\n' "$bad1" | head -3)"
DIG1="select md5(string_agg(id::text||':'||email||':'||coalesce(note,'~'), ',' order by id)) from uq_t where id > 0"
same_everywhere U1 uq_t "$DIG1" 1
check "U1 no email acknowledged twice" "" "$(twice "$TMP/uq_t.ok")"
check "U1 $REF holds exactly the acknowledged rows" "$(acked_ids "$TMP/uq_t.ok")" \
	"$(qt "$REF" "select string_agg(id::text, ' ' order by id) from uq_t where id > 0")"
check "U1 no 'cluster_apply fail' logged" "0" "$(apply_fails_since "$T0")"
settle U1

# ── U1b: the same under the default party ───────────────────────────────────
echo "  -- U1b: 30 rounds as U1, the default party"
race uq_d 30 0 "'u1b-@R@@x'"
acked="$(lines "$TMP/uq_d.ok")"; refused="$(lines "$TMP/uq_d.err")"
slowest="$(sort -n "$TMP/uq_d.secs" 2>/dev/null | tail -1)"
echo "     acknowledged $acked of 90, refused $refused, slowest round ${slowest:-?} s"
[ "$acked" -ge 15 ] \
	&& ok "U1b the first writer of an email commits ($acked acknowledgements in 30 rounds)" \
	|| bad "U1b only $acked acknowledgements in 30 rounds"
bad1="$(other_refusals "$TMP/uq_d.err" 23505 40001)"
[ -z "$bad1" ] && ok "U1b no lock wait across nodes: every refusal 23505 or 40001 ($refused)" \
	|| bad "U1b refusals other than 23505/40001 (55P03 or 08006 is a wait on another node's index entry): $(printf '%s\n' "$bad1" | head -3)"
# 20 s: a loaded shared docker host stretches three ssh + docker exec writes; a writer
# that waited on another's lock runs into the 30 s timeout
[ "${slowest:-99}" -le 20 ] && ok "U1b each round over within seconds (slowest ${slowest} s)" \
	|| bad "U1b a round took ${slowest:-?} s - a writer waited"
DIG1B="select md5(string_agg(id::text||':'||email||':'||coalesce(note,'~'), ',' order by id)) from uq_d where id > 0"
same_everywhere U1b uq_d "$DIG1B" 1
check "U1b no email acknowledged twice" "" "$(twice "$TMP/uq_d.ok")"
check "U1b $REF holds exactly the acknowledged rows" "$(acked_ids "$TMP/uq_d.ok")" \
	"$(qt "$REF" "select string_agg(id::text, ' ' order by id) from uq_d where id > 0")"
settle U1b

# ── U2: an UPDATE of a unique column is its row, not the table ──────────────
# rows 1-30, each its own code; one origin writes `note` of 1-10, two others `code`
# of 11-30, fresh values
echo "  -- U2: ${ORIG[0]} updates note of rows 1-10; ${ORIG[1]} and ${ORIG[2]} set fresh codes of rows 11-30"
for i in $(seq 1 30); do cw "$REF" "insert into uq_c values ($i, 'seed-$i', 'n0')" >/dev/null; done
wait_converged 60 "select count(*) from uq_c where id between 1 and 30" || true
check "U2 setup: 30 rows on $REF" 30 "$(qt "$REF" "select count(*) from uq_c where id between 1 and 30")"
(
	end=$((SECONDS + 30)); i=0
	while [ "$SECONDS" -lt "$end" ]; do
		i=$((i + 1))
		cw "${ORIG[0]}" "update uq_c set note = 'n$i' where id = $((i % 10 + 1))" 20s >/dev/null
	done
) &
NPID=$!
for k in 1 2; do
	(
		o="${ORIG[$k]}"; end=$((SECONDS + 28)); i=0
		while [ "$SECONDS" -lt "$end" ]; do
			i=$((i + 1))
			e="$(cw "$o" "update uq_c set code = 'u2-$o-$i' where id = $((10 + k * 10 - (i % 10)))" 20s)"
			if [ -z "$e" ]; then echo "$i" >> "$TMP/u2.$k.ok"; else echo "$(state_of "$e") ${e:0:200}" >> "$TMP/u2.$k.err"; fi
			sleep 0.1
		done
	) &
done
for p in $(jobs -p); do [ "$p" = "$NPID" ] || wait "$p" || true; done
wait "$NPID" || true
u2_ok=$(( $(lines "$TMP/u2.1.ok") + $(lines "$TMP/u2.2.ok") ))
u2_err=$(( $(lines "$TMP/u2.1.err") + $(lines "$TMP/u2.2.err") ))
u2_try=$((u2_ok + u2_err))
u2_table="$(cat "$TMP"/u2.*.err 2>/dev/null | grep -c 'table level' || true)"
echo "     code updates: $u2_try, acknowledged $u2_ok, refused $u2_err"
[ "$u2_try" -ge 20 ] && ok "U2 $u2_try code updates were attempted" \
	|| bad "U2 only $u2_try code updates were attempted - too few to mean anything"
check "U2 no code update refused as a table-level collision" "0" "${u2_table:-0}"
[ "$u2_try" -gt 0 ] && [ $((u2_ok * 100)) -ge $((u2_try * 95)) ] \
	&& ok "U2 >= 95 % of the code updates acknowledged ($u2_ok of $u2_try)" \
	|| bad "U2 $u2_ok of $u2_try code updates acknowledged - first refusal: $(cat "$TMP"/u2.*.err 2>/dev/null | head -1)"
DIG2="select md5(string_agg(id::text||':'||coalesce(code,'~')||':'||coalesce(note,'~'), ',' order by id)) from uq_c where id between 1 and 30"
same_everywhere U2 uq_c "$DIG2" 30
settle U2

# ── U3: one code on two rows from two origins at once ───────────────────────
echo "  -- U3: 10 rounds, ${ORIG[1]} and ${ORIG[2]} set one code on two rows at once (nodes>=1)"
for r in $(seq 1 10); do
	cw "$REF" "insert into uq_e values ($((100 + r * 2)), 'u3-a-$r', 'n'), ($((101 + r * 2)), 'u3-b-$r', 'n')" >/dev/null
done
wait_converged 60 "select count(*) from uq_e where id between 102 and 121" || true
check "U3 setup: 20 rows on $REF" 20 "$(qt "$REF" "select count(*) from uq_e where id between 102 and 121")"
both=0; u3_ok=0; bad3=""
for r in $(seq 1 10); do
	rm -f "$TMP"/u3.*
	for k in 1 2; do
		d="0.0$((RANDOM % 5))"
		(
			sleep "$d"
			e="$(cw "${ORIG[$k]}" "update uq_e set code = 'u3-$r' where id = $((99 + r * 2 + k))" 30s)"
			if [ -z "$e" ]; then echo ok > "$TMP/u3.$k"; else echo "$(state_of "$e") ${e:0:200}" > "$TMP/u3.$k"; fi
		) &
	done
	wait
	n_ok="$(cat "$TMP"/u3.* 2>/dev/null | grep -c '^ok$' || true)"
	u3_ok=$((u3_ok + n_ok))
	[ "$n_ok" -le 1 ] || both=$((both + 1))
	for k in 1 2; do
		s="$(cut -d' ' -f1 "$TMP/u3.$k" 2>/dev/null || true)"
		case "$s" in ok|23505|40001) ;; *) [ -n "$bad3" ] || bad3="$(cat "$TMP/u3.$k" 2>/dev/null)" ;; esac
	done
done
echo "     acknowledged $u3_ok of 20"
check "U3 never both of a pair acknowledged" "0" "$both"
[ -z "$bad3" ] && ok "U3 every refusal 23505 or 40001" || bad "U3 a refusal other than 23505/40001: ${bad3:0:200}"
DIG3="select md5(string_agg(id::text||':'||coalesce(code,'~'), ',' order by id)) from uq_e where id between 102 and 121"
same_everywhere U3 uq_e "$DIG3" 20
settle U3

# ── U4: NULLs of a nullable unique key never collide ────────────────────────
echo "  -- U4: 10 rounds, ${ORIG[*]} insert NULL emails at once (nodes>=1)"
race uq_n 10 0 "NULL"
acked="$(lines "$TMP/uq_n.ok")"
check "U4 every NULL email acknowledged" 30 "$acked"
[ ! -s "$TMP/uq_n.err" ] || echo "     first refusal: $(head -1 "$TMP/uq_n.err")"
DIG4="select md5(string_agg(id::text||':'||coalesce(email,'~'), ',' order by id)) from uq_n where id > 0"
same_everywhere U4 uq_n "$DIG4" 1

cleanup
summary
