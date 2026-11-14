#!/usr/bin/env bash
# [load] ytlt.md: a cluster of 3 nodes under pgbench load, 3 leaves joining it one by one
# during that load, then every node's tables dumped and compared.
#
# The cluster: this fixture's upper cluster (u1 u2 u3), on the store and TLS as 15_store.sh
# leaves it - what a lite node needs. The leaves, by YX_LOAD_LEAF:
#   pg     (Phase 1, the default) containers lt1 lt2 lt3 of this fixture's image running
#          yt-lite beside PostgreSQL (85_lite.sh does the same for one)
#   turso  (Phase 2) containers tt1 tt2 tt3 running yt-turso-load: an application on Turso
#          with the lite node inside it (yt-cluster-lite yt-turso-load, built on this host:
#          YT_TURSO_LOAD_BIN, else its target/release), its load like pgbench's
#
# The database, the same on all 6 nodes before the load (one deterministic script, no
# copy): 7 schemas - `common`, with one table of YX_LOAD_ROWS rows (1M), and one schema of
# each node, named after it (s_u1 ... s_lt3, or s_tt3), with a pgbench-like pair of tables: accounts
# (YX_LOAD_ACCOUNTS rows) and history. Every table is routed to the upper cluster's az
# (`az=top`), so it crosses to its lite nodes both ways.
#
# The load: each cluster node runs pgbench on its own schema, 1 client, 1 s between
# transactions, for YX_LOAD_SEC seconds. Each lite node, started during it: signs in, is
# approved, pulls until it holds what the cluster had when it was let in, then runs pgbench
# for YX_LOAD_LITE_TX transactions on its own schema, without pause (a Turso leaf: its own
# load, the same transactions).
#
# What is compared, as the design is today (owner, 2026-11-13): a lite node's rows reach
# every cluster node, never another lite node - the cluster applies them as a read-only
# copy, outside the log lite nodes are fed from (TODO.md item 13, one hop). So:
#   - the 3 cluster nodes: every table the same
#   - each leaf: `common` and the cluster nodes' schemas the same as the cluster's; its own
#     schema the same as the cluster's copy of it; another leaf's schema as it was before
#     the load (no history, every balance 0) - but for the closing rows (P5)
#
# ## What is asserted
#
# P1 the database is the same on every node before the load (each table's digest)
# P2 the cluster's load runs on all 3 nodes
# P3 each lite node: approved, TLS, pulled what the cluster had, ran its pgbench to the end
# P4 every pgbench ended, none with a failed transaction
# P5 closing: a cluster node writes one closing row by hand - not pgbench - into each
#    leaf's tables (a history row, an update of accounts row 1): it reaches every leaf, the
#    leaf it belongs to and the others - the cluster's own writes cross both ways, a leaf's
#    tables included
# P5 settled: the digests stop changing and the cluster nodes agree
# P6 the dumps: the cluster nodes' alike; each leaf's as above, with the closing rows - in
#    another leaf's schema those alone: its history the closing row, its accounts as before
#    the load but row 1's filler
#
# Needs 10_up.sh and 15_store.sh on this fixture. Its rows go in schemas of its own; the
# lite containers are stopped at the end (90_down.sh removes them).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../topology/skv_lib.sh"
echo "== load: 3 cluster nodes under pgbench, 3 lite nodes joining one by one, 6 dumps compared =="

ROWS="${YX_LOAD_ROWS:-1000000}"
ACCOUNTS="${YX_LOAD_ACCOUNTS:-10000}"
LOAD_SEC="${YX_LOAD_SEC:-600}"
LITE_TX="${YX_LOAD_LITE_TX:-100}"
LEAF="${YX_LOAD_LEAF:-pg}"
case "$LEAF" in
	pg) LITES=(lt1 lt2 lt3) ;;
	turso)
		LITES=(tt1 tt2 tt3)
		TL_BIN="${YT_TURSO_LOAD_BIN:-$LITE_ROOT/target/release/yt-turso-load}"
		[ -x "$TL_BIN" ] || { bad "no $TL_BIN: cargo build --release -p yt-turso-load in yt-cluster-lite"; summary; } ;;
	*) bad "YX_LOAD_LEAF=$LEAF: pg or turso"; summary ;;
esac
echo "  leaves: $LEAF (${LITES[*]})"
TW=/var/lib/ytt   # a Turso leaf's files in its container: the database, w/ its status, go, stop and dumps
# a uuid of this run each: the cluster keeps a lite node's approval under its uuid, and a
# container made again has another CA
RUN="$(date +%s)"
declare -A LUUID=()
for i in 1 2 3; do LUUID[${LITES[$((i - 1))]}]="$(printf 'eeeeeeee-eeee-4eee-8eee-%012x' $(( RUN * 10 + i )))"; done
ALL=("${NODES[@]}")
SCHEMAS=(common)
for n in "${CL_UPPER[@]}" "${LITES[@]}"; do SCHEMAS+=("s_$n"); done
# each table and its key, for the digests and the dumps
TABLES=(common.big:id)
for n in "${CL_UPPER[@]}" "${LITES[@]}"; do TABLES+=("s_$n.accounts:aid" "s_$n.history:hid"); done
DUMPS="/tmp/yxload-dumps.$RUN"   # on the docker host

lt() { info "$1" I "$2"; }   # lt <lite> <yt_info I field>
# the database before the load, made the same way on every node
init_sql() {
	local s
	echo "set client_min_messages = warning;"
	for s in "${SCHEMAS[@]}"; do echo "drop schema if exists $s cascade;"; done
	echo "create schema common;
	      create table common.big (id bigint primary key, v text not null, n int not null);
	      insert into common.big select g, md5(g::text), (g::bigint * 7919) % 100003 from generate_series(1, $ROWS) g;"
	for s in "${SCHEMAS[@]:1}"; do
		echo "create schema $s;
		      create table $s.accounts (aid int primary key, abalance int not null default 0, filler text not null);
		      insert into $s.accounts select g, 0, md5(g::text || '$s') from generate_series(1, $ACCOUNTS) g;
		      create table $s.history (hid bigserial primary key, aid int not null, delta int not null,
		                               mtime timestamptz not null default now());"
	done
}
# a table's digest: its rows in key order
digest() { # digest <node> <schema.table:key>
	q "$1" "select coalesce(md5(string_agg(t::text, E'\n' order by t.${2#*:})), 'empty') from ${2%%:*} t"
}
# pgbench_script <schema> <pause>: one transaction on the schema's tables
pgbench_script() {
	cat <<SQL
\set aid random(1, $ACCOUNTS)
\set delta random(-5000, 5000)
BEGIN;
UPDATE $1.accounts SET abalance = abalance + :delta WHERE aid = :aid;
INSERT INTO $1.history (aid, delta) VALUES (:aid, :delta);
SELECT yt_complete(true);
END;
$2
SQL
}
# start_pgbench <node> <schema> <pause> <pgbench limit args>: in the background, its output
# in /tmp/load.out of the container
start_pgbench() {
	pgbench_script "$2" "$3" | rh "docker exec -i $1 sh -c 'cat > /tmp/load.sql'"
	rh "docker exec -d -u postgres $1 sh -c '\$(pg_config --bindir)/pgbench -n -c 1 -j 1 $4 -f /tmp/load.sql $YX_DB > /tmp/load.out 2>&1; echo done >> /tmp/load.out'"
}
pgbench_done() { rh "docker exec $1 grep -c '^done\$' /tmp/load.out 2>/dev/null; true"; }
pgbench_line() { rh "docker exec $1 grep -a -E '$2' /tmp/load.out 2>/dev/null | head -1; true"; }
wrote() { # wrote <node> <what> <sql>: the write's errors said, as a failed check
	local o; o="$(qe "$1" "$3")"
	case "$o" in *ERROR*|*FATAL*) bad "$2: $(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')" ;; esac
}
# put_file <local file> <container> <path>
put_file() {
	if [ "$YX_HOST" = local ]; then docker cp "$1" "$2:$3"
	else scp -q "$1" "$YX_HOST:/tmp/yx-load.$2" && rh "docker cp /tmp/yx-load.$2 $2:$3; rm -f /tmp/yx-load.$2"; fi
}
# ── a leaf, whatever kind ───────────────────────────────────────────────────────
st() { rh "docker exec $1 cat $TW/w/status 2>/dev/null; true" | sed -n "s/^$2=//p" | head -1; }   # st <turso leaf> <key>
csv() { local IFS=,; echo "$*"; }
# leaf_start <name> <uuid>: up, with the initial database, linking (not approved yet)
leaf_start() {
	local LN="$1" LU="$2" up o
	if [ "$LEAF" = turso ]; then
		rh "docker run -d --name $LN --hostname $LN --network $YX_NET --entrypoint sleep $YX_IMAGE infinity >/dev/null" || return 1
		put_file "$TL_BIN" "$LN" /usr/local/bin/yt-turso-load || return 1
		o="$(rh "docker exec $LN sh -c 'mkdir -p $TW/w && yt-turso-load init --db $TW/leaf.db --rows $ROWS --accounts $ACCOUNTS --schemas $(csv "${SCHEMAS[@]}")' 2>&1" || true)"
		case "$o" in *"init: done"*) ;; *) bad "P3 $LN: the initial database: $(printf '%s' "$o" | tail -2 | tr '\n' ' ')"; return 1 ;; esac
		# its initial database, dumped as the cluster's was before the load (review of 2026-11-13)
		rh "docker exec $LN yt-turso-load dump --db $TW/leaf.db --dir $TW/initial >/dev/null 2>&1; true"
		same=1
		for t in "${TABLES[@]}"; do
			# md5sum on the file in the container: a `<` would be read on the docker host
			[ "$(rh "docker exec $LN md5sum $TW/initial/${t%%:*}.tsv 2>/dev/null | cut -d' ' -f1; true")" = \
				"$(rh "md5sum < $DUMPS/initial/${t%%:*}.tsv | cut -d' ' -f1")" ] || { same=0; echo "     $LN ${t%%:*} differs before the load"; }
		done
		check "P1 $LN starts from the same database" "1" "$same"
		rh "docker exec -d $LN sh -c 'yt-turso-load run --db $TW/leaf.db --dir $TW/w --uuid $LU --upper $hosts --root $ROOT \
			--cluster-db $YX_DB --schema s_$LN --tx $LITE_TX > $TW/log 2>&1'"
		return 0
	fi
	rh "docker run -d --name $LN --hostname $LN --network $YX_NET -e NODE_UUID=$LU -e DB=$YX_DB -e CFG_TABLE=$YX_CFG \
		-e YT_SERVER_BIN=yt-lite $YX_IMAGE >/dev/null"
	up=0
	for _ in $(seq 1 90); do [ "$(q "$LN" "select 1 from pg_tables where schemaname='public' and tablename='yt_config'")" = 1 ] && { up=1; break; }; sleep 2; done
	[ "$up" = 1 ] || { bad "P3 $LN: its PostgreSQL did not come up in 180 s"; return 1; }
	# the initial database, before yt-lite runs: a row that comes down for a table not
	# here yet would be skipped for good
	o="$(init_sql | rh "docker exec -i -u postgres $LN psql -X -q -v ON_ERROR_STOP=1 -d $YX_DB" 2>&1 || true)"
	case "$o" in *ERROR*) bad "P3 the database on $LN: $(printf '%s\n' "$o" | grep -m1 ERROR)"; return 1 ;; esac
	same=1; for t in "${TABLES[@]}"; do [ "$(digest "$LN" "$t")" = "${INITIAL[$t]}" ] || same=0; done
	check "P1 $LN starts from the same database" "1" "$same"
	# which tables sync (yt-core sync.rs): every table, as on a cluster node by its A row - its
	# own schema's yt_setup writes theirs with the triggers (leaf_capture), the rest only come down
	for t in "${TABLES[@]}"; do
		case "${t%%:*}" in "s_$LN".*) ;; *) cfg_write "$LN" "${t%%:*}" A "" ;; esac
	done
	cfg_write "$LN" uuid L "$LU"
	cfg_write "$LN" upper L "$hosts"
	cfg_write "$LN" upper_root L "$ROOT"
	cfg_write "$LN" cfg_ready C 1
	return 0
}
leaf_fp() { if [ "$LEAF" = turso ]; then st "$1" fingerprint; else lt "$1" ca_fingerprint; fi; }
leaf_tls() { if [ "$LEAF" = turso ]; then [ "$(st "$1" tls)" = true ]; else case "$(lt "$1" link_tls)" in *"calls are TLS"*) return 0 ;; esac; return 1; fi; }
leaf_count() { if [ "$LEAF" = turso ]; then st "$1" "rows $2"; else q "$1" "select count(*) from $2"; fi; }
# its own schema captured, the rest only applied (a Turso leaf captures its own at its start)
leaf_capture() {
	if [ "$LEAF" = turso ]; then check "P3 $1 captures its own schema's two tables" "2" "$(st "$1" captured)"; return 0; fi
	q "$1" "select yt_setup('s_$1.accounts'); select yt_setup('s_$1.history');" >/dev/null
	check "P3 $1 captures its own schema's two tables" "2" \
		"$(q "$1" "select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace s on s.oid = c.relnamespace
		           where s.nspname = 's_$1' and t.tgname like 'zytsync%' and t.tgname not like 'zytsynct%'")"
}
leaf_load() { if [ "$LEAF" = turso ]; then rh "docker exec $1 touch $TW/w/go"; else start_pgbench "$1" "s_$1" "" "-t $LITE_TX"; fi; }
leaf_load_done() {
	if [ "$LEAF" = turso ]; then case "$(st "$1" load)" in "done $LITE_TX") echo 1 ;; *) echo 0 ;; esac
	else pgbench_done "$1"; fi
}
leaf_log() { if [ "$LEAF" = turso ]; then rh "docker exec $1 tail -3 $TW/log 2>/dev/null; true"; else rh "docker logs $1 2>&1 | tail -3"; fi; }
# leaf_dump <name> <dir on the docker host>: every table, in key order, as COPY's text
leaf_dump() {
	local t
	if [ "$LEAF" = turso ]; then
		rh "docker exec $1 touch $TW/w/stop"
		for _ in $(seq 1 90); do rh "docker exec $1 test -f $TW/w/dumped" && break; sleep 2; done
		rh "docker exec $1 test -f $TW/w/dumped" || { bad "P6 $1 did not dump its tables: $(leaf_log "$1" | tr '\n' ' ')"; return; }
		rh "docker cp $1:$TW/w/dump/. $2/"
		return
	fi
	for t in "${TABLES[@]}"; do
		rh "docker exec -u postgres $1 psql -X -q -d $YX_DB -c \"copy (select * from ${t%%:*} order by ${t#*:}) to stdout\" > $2/${t%%:*}.tsv"
	done
}

await_clusters
in_cluster upper
UL="$L"
[ -n "$UL" ] || { bad "the upper cluster has no leader"; summary; }
case "$(required_line "$UL")" in "TLS between members required:"*) ;;
	*) bad "the upper does not require TLS - 15_store.sh sets the hierarchy up: $(required_line "$UL")"; summary ;; esac
CAV="$(q "$UL" "select yt_info('X')" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
v = [int(r['name'][4:]) for r in rows if r.get('name', '').startswith('@ca/') and r['name'][4:].isdigit()]
print(max(v) if v else '')")"
ROOT="$(info "$UL" X "@ca/$CAV")"
case "$ROOT" in SHA256:*) ;; *) bad "the upper leader $UL holds no CA to pin: [$ROOT]"; summary ;; esac
CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg "az=top" 2>/dev/null | tail -1)"
[ -n "$CFG" ] || { bad "--encode-table-cfg az=top produced nothing"; summary; }

# ── the database, on the cluster nodes: made, then put under sync ────────────────
for n in "${CL_UPPER[@]}"; do
	o="$(init_sql | rh "docker exec -i -u postgres $n psql -X -q -v ON_ERROR_STOP=1 -d $YX_DB" 2>&1 || true)"
	case "$o" in *ERROR*) bad "the database on $n: $(printf '%s\n' "$o" | grep -m1 ERROR)"; summary ;; esac
done
NODES=("${CL_UPPER[@]}")
for t in "${TABLES[@]}"; do register_table "${t%%:*}" "$CFG"; done
NODES=("${ALL[@]}")
restart_all 30
await_clusters
in_cluster upper
UL="$L"
declare -A INITIAL=()
for t in "${TABLES[@]}"; do INITIAL[$t]="$(digest "${CL_UPPER[0]}" "$t")"; done
# ... and its dump, which a Turso leaf's initial tables are compared with
rh "rm -rf $DUMPS && mkdir -p $DUMPS/initial"
for t in "${TABLES[@]}"; do
	rh "docker exec -u postgres ${CL_UPPER[0]} psql -X -q -d $YX_DB -c \"copy (select * from ${t%%:*} order by ${t#*:}) to stdout\" > $DUMPS/initial/${t%%:*}.tsv"
done
same_start=1
for n in "${CL_UPPER[@]:1}"; do for t in "${TABLES[@]}"; do
	[ "$(digest "$n" "$t")" = "${INITIAL[$t]}" ] || { same_start=0; echo "     $n ${t%%:*} differs before the load"; }
done; done
check "P1 the database is the same on the 3 cluster nodes before the load (${#TABLES[@]} tables, $ROWS rows in common.big)" "1" "$same_start"

# ── the cluster's load ───────────────────────────────────────────────────────
for n in "${CL_UPPER[@]}"; do start_pgbench "$n" "s_$n" '\sleep 1 s' "-T $LOAD_SEC"; done
T_LOAD="$(date +%s)"
sleep 20
running=0
for n in "${CL_UPPER[@]}"; do
	[ "$(q "$n" "select count(*) from s_$n.history")" -gt 0 ] 2>/dev/null && running=$((running + 1))
done
check "P2 the load runs on the 3 cluster nodes: each wrote its own schema" "3" "$running"

# ── the lite nodes, one by one ──────────────────────────────────────────────
hosts=""; for n in "${CL_UPPER[@]}"; do hosts="${hosts:+$hosts,}http://$n:$YX_PORT"; done
for LN in "${LITES[@]}"; do
	LU="${LUUID[$LN]}"
	rh "docker rm -f $LN >/dev/null 2>&1; true"
	leaf_start "$LN" "$LU" || continue
	for _ in $(seq 1 60); do [ -n "$(leaf_fp "$LN")" ] && break; sleep 2; done
	FP="$(leaf_fp "$LN")"
	[ -n "$FP" ] || { bad "P3 the leaf $LN did not come up: $(leaf_log "$LN" | tr '\n' ' ')"; continue; }
	leaf_capture "$LN"
	in_cluster upper
	UL="$L"
	pend() { q "$UL" "select count(*) from $YX_CFG where module='J' and name='$LU' and value like 'pending:%'"; }
	for _ in $(seq 1 45); do [ "$(pend)" -ge 1 ] 2>/dev/null && break; sleep 2; done
	o="$(yx "$UL" --skv-approve "$LU" --fingerprint "$FP" --yes)"
	case "$o" in *"Approved - "*) ;; *) bad "P3 $LN: the approval on $UL failed: $(echo "$o" | tail -2 | tr '\n' ' ')"; continue ;; esac
	for _ in $(seq 1 60); do leaf_tls "$LN" && break; sleep 2; done
	leaf_tls "$LN" || { bad "P3 $LN not countersigned: $(leaf_log "$LN" | tr '\n' ' ')"; continue; }
	# pulled: what each cluster node had written to its schema when the leaf was let in
	pulled=1
	for n in "${CL_UPPER[@]}"; do
		want="$(q "$n" "select count(*) from s_$n.history")"
		for _ in $(seq 1 90); do [ "$(leaf_count "$LN" "s_$n.history")" -ge "${want:-0}" ] 2>/dev/null && break; sleep 2; done
		[ "$(leaf_count "$LN" "s_$n.history")" -ge "${want:-0}" ] 2>/dev/null || { pulled=0; echo "     $LN holds fewer than $want rows of s_$n.history"; }
	done
	check "P3 $LN approved, on TLS, and pulled what the cluster had written when it came in" "1" "$pulled"
	leaf_load "$LN"
	echo "  $LN: its load of $LITE_TX transactions started, $(( $(date +%s) - T_LOAD )) s into the cluster's load"
done

# ── every pgbench to its end ─────────────────────────────────────────────────
left=$(( LOAD_SEC - ($(date +%s) - T_LOAD) ))
[ "$left" -gt 0 ] && { echo "  the cluster's load runs $left s more"; sleep "$left"; }
for n in "${CL_UPPER[@]}"; do
	for _ in $(seq 1 90); do [ "$(pgbench_done "$n")" = 1 ] && break; sleep 2; done
	check "P4 pgbench on $n ended" "1" "$(pgbench_done "$n")"
	done_tx="$(pgbench_line "$n" 'number of transactions actually processed')"
	failed="$(pgbench_line "$n" 'number of failed transactions|aborted in command')"
	echo "     $n: ${done_tx:-no summary}${failed:+; $failed}"
	# a pgbench that died before its summary has no summary: that is no pass (review of 2026-11-13)
	if [ -z "$done_tx" ]; then bad "P4 pgbench on $n ended without its summary"
	else case "$failed" in ""|*"failed transactions: 0 "*) ok "P4 ...with no failed transaction on $n" ;;
		*) bad "P4 pgbench on $n: $failed" ;; esac; fi
done
# the leaves' load is a fixed count: all of it went through
for LN in "${LITES[@]}"; do
	for _ in $(seq 1 90); do [ "$(leaf_load_done "$LN")" = 1 ] && break; sleep 2; done
	check "P4 the load on $LN ended" "1" "$(leaf_load_done "$LN")"
	check "P4 $LN wrote its $LITE_TX rows" "$LITE_TX" "$(leaf_count "$LN" "s_$LN.history")"
done

# ── closing: one row by hand from a cluster node into each leaf's tables ────────
CLOSER="${CL_UPPER[0]}"
CLOSE_TS="2000-01-01 00:00:00+00"
i=0
for LN in "${LITES[@]}"; do
	i=$((i + 1))
	wrote "$CLOSER" "P5 the closing write into s_$LN on $CLOSER" "begin;
		insert into s_$LN.history (hid, aid, delta, mtime) values ($((900000000 + i)), 1, 0, '$CLOSE_TS');
		update s_$LN.accounts set filler = 'closed by $CLOSER' where aid = 1;
		select yt_complete(true); commit;"
done
for LN in "${LITES[@]}"; do
	for n in "${LITES[@]}"; do
		got=0
		for _ in $(seq 1 60); do
			if [ "$LEAF" = turso ]; then
				# its status counts rows, not values: the owner's load and the closing row, or the
				# closing row alone; the dumps say the rest
				want_n=1; [ "$n" = "$LN" ] && want_n=$((LITE_TX + 1))
				# the history row, and the update of accounts row 1 (its status says that filler)
				[ "$(leaf_count "$n" "s_$LN.history")" = "$want_n" ] \
					&& [ "$(st "$n" "filler1 s_$LN.accounts")" = "closed by $CLOSER" ] && { got=1; break; }
			else
				[ "$(q "$n" "select count(*) from s_$LN.history where hid > 900000000")" = 1 ] \
					&& [ "$(q "$n" "select filler from s_$LN.accounts where aid = 1")" = "closed by $CLOSER" ] && { got=1; break; }
			fi
			sleep 2
		done
		check "P5 the closing rows of s_$LN reached $n" "1" "$got"
	done
done

# ── settled: nothing changes any more, the cluster nodes agree ───────────────
round() { local n t; for n in "${CL_UPPER[@]}" "${LITES[@]}"; do for t in "${TABLES[@]}"; do
	[ "$t" = common.big:id ] && continue
	if [ "$LEAF" = turso ] && [[ " ${LITES[*]} " == *" $n "* ]]; then
		# the md5 of its dump it reports each few seconds: a balance that still changes shows
		printf '%s %s %s\n' "$n" "${t%%:*}" "$(st "$n" "sum ${t%%:*}")"
	else printf '%s %s %s\n' "$n" "${t%%:*}" "$(digest "$n" "$t")"; fi
	done; done; }
agree() { # the cluster nodes' digests of every table alike
	local t first n
	for t in "${TABLES[@]}"; do [ "$t" = common.big:id ] && continue
		first="$(grep "^${CL_UPPER[0]} ${t%%:*} " <<< "$1" | cut -d' ' -f3)"
		for n in "${CL_UPPER[@]:1}"; do [ "$(grep "^$n ${t%%:*} " <<< "$1" | cut -d' ' -f3)" = "$first" ] || return 1; done
	done
}
prev=""; settled=0
for i in $(seq 1 40); do
	cur="$(round)"
	if [ "$cur" = "$prev" ] && agree "$cur"; then settled=1; break; fi
	prev="$cur"; sleep 15
done
check "P5 settled: two rounds alike and the cluster nodes agree on every table" "1" "$settled"

# ── the dumps: every table in key order, a file of each on the docker host ───
LEAF_KIND="$LEAF"
for n in "${CL_UPPER[@]}" "${LITES[@]}"; do
	rh "mkdir -p $DUMPS/$n"
	# the cluster's nodes are PostgreSQL's, whatever the leaves are
	if [[ " ${CL_UPPER[*]} " == *" $n "* ]]; then LEAF=pg; fi
	leaf_dump "$n" "$DUMPS/$n"
	LEAF="$LEAF_KIND"
done
echo "  dumps of $((${#CL_UPPER[@]} + ${#LITES[@]})) nodes in $YX_HOST:$DUMPS"
# ... and the cluster stopped: its load ended above; the lite nodes go
rh "docker stop ${LITES[*]} >/dev/null; true"
sum() { rh "md5sum < $DUMPS/$1/$2.tsv | cut -d' ' -f1"; }
rows() { rh "wc -l < $DUMPS/$1/$2.tsv"; }
for t in "${TABLES[@]}"; do
	t="${t%%:*}"; base="$(sum "${CL_UPPER[0]}" "$t")"
	# two empty or missing dumps are alike: a table that has rows must have them in the dump
	[ "$(rows "${CL_UPPER[0]}" "$t" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null \
		|| bad "P6 $t: ${CL_UPPER[0]}'s dump holds no row ($YX_HOST:$DUMPS/${CL_UPPER[0]}/$t.tsv)"
	for n in "${CL_UPPER[@]:1}"; do check "P6 $t: $n's dump is ${CL_UPPER[0]}'s ($(rows "$n" "$t") rows)" "$base" "$(sum "$n" "$t")"; done
	case "$t" in
		common.*|s_u*)
			for LN in "${LITES[@]}"; do check "P6 $t: $LN's dump is the cluster's" "$base" "$(sum "$LN" "$t")"; done ;;
		*)   # a leaf's schema
			owner="${t#s_}"; owner="${owner%%.*}"
			# another leaf's copy of this schema, as the cluster computes it: none of its owner's
			# rows (one hop), the closing rows only - the history row, and row 1's filler with
			# the balance as before the load. This follows the closing step above, which sets
			# filler alone: the extension sends an update's changed columns only, so a closing
			# update of another column needs its value here instead of the 0 (review of 2026-11-13)
			case "$t" in
				*.history) rh "docker exec -u postgres $CLOSER psql -X -q -d $YX_DB -c \"copy (select * from $t where hid > 900000000 order by hid) to stdout\" > $DUMPS/expected.$t.tsv" ;;
				*) rh "docker exec -u postgres $CLOSER psql -X -q -d $YX_DB -c \"copy (select aid, 0, filler from $t order by aid) to stdout\" > $DUMPS/expected.$t.tsv" ;;
			esac
			want="$(rh "md5sum < $DUMPS/expected.$t.tsv | cut -d' ' -f1")"
			for LN in "${LITES[@]}"; do
				if [ "$LN" = "$owner" ]; then check "P6 $t: its own leaf $LN's dump is the cluster's, the closing rows in it" "$base" "$(sum "$LN" "$t")"
				else check "P6 $t on $LN: the closing rows alone, its owner's never (one hop) - $(rows "$LN" "$t") rows" "$want" "$(sum "$LN" "$t")"
				fi
			done ;;
	esac
done

# the dumps stay for a look when something failed; otherwise they go (300 MB or so)
[ "$fail" -eq 0 ] && rh "rm -rf $DUMPS"
summary
