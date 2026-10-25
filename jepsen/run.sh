#!/usr/bin/env bash
# [jepsen] Jepsen against YT Cluster - by hand, and four cases in the nightly
# (nightly_cases.sh):
#
#   jepsen/run.sh [--nodes N] [--base IMAGE] [--deb FILE|none] [--keep] [-- TEST OPTIONS]
#
# Takes the nightly's lock (nightly/locked.sh): never at the same time as a nightly
# or another locked run, and a nightly that starts meanwhile is skipped. Builds two
# images on the docker host (YX_HOST in ../.env, as topology/ uses): yt-jepsen-node -
# dbinvent/yt (--base) with sshd, sudo, iptables and tc, the newest deb of the
# yt-pgxt checkout over its package (--deb FILE, or none for the image's own) - and
# yt-jepsen-control - the JDK, Leiningen and this test (src/jepsen/ytcluster.clj).
# Starts N nodes (5, Jepsen's n1..n5; 3 to 9) and the control node on a network of
# their own, every run from nothing; runs `lein run test` there; copies Jepsen's
# store into store/ here with each node's container log beside it (docker/<node>.log)
# and how the test left it (docker/<node>.after.txt), writes the verdict to
# results.yaml - the latest run only, store/ too - and removes the containers
# (--keep leaves them).
# Exit: Jepsen's - 0 valid, 1 invalid, 2 unknown, 254 bad options, 255 the test
# crashed.
#
# TEST OPTIONS go to `lein run test` (README.md); without any:
#   --workload append --nemesis partition,kill,pause --time-limit 300 --rate 50
#   --concurrency 2n --isolation serializable --expected-consistency-model cursor-stability
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"

if [ -z "${JEPSEN_LOCKED:-}" ]; then
	export JEPSEN_LOCKED=1
	exec "$TESTS_ROOT/nightly/locked.sh" "$HERE/run.sh" "$@"
fi

# settings: yt-cluster-tests/.env, as topology/env.sh reads it - a variable set in
# the environment wins
if [ -f "$TESTS_ROOT/.env" ]; then
	_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_keep"; unset _keep
fi
REPO_ROOT="${YT_PGXT:-$(cd "$TESTS_ROOT/.." && pwd)/yt-cluster}"
YX_HOST="${YX_HOST:-local}"
YX_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
rh() { if [ "$YX_HOST" = local ]; then bash -c "$*"; else "${YX_SSH[@]}" "$YX_HOST" "$*"; fi; }

NODES=5; BASE=dbinvent/yt:1.20; DEB=auto; KEEP=0; TEST_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--nodes) NODES="$2"; shift 2 ;;
		--base)  BASE="$2"; shift 2 ;;
		--deb)   DEB="$2"; shift 2 ;;
		--keep)  KEEP=1; shift ;;
		--)      shift; TEST_ARGS=("$@"); break ;;
		-h|--help) sed -n '2,24s/^# \{0,1\}//p' "$0"; exit 0 ;;
		*) echo "unknown option $1 - test options go after --" >&2; exit 254 ;;
	esac
done
case "$NODES" in [3-9]) ;; *) echo "--nodes: 3 to 9, not $NODES" >&2; exit 254 ;; esac
# Every table sequentially consistent with `all` (the test's --sc, its default),
# each party member at the transaction's SERIALIZABLE. The goal is strong writes
# and eventually consistent reads: no write lost or applied twice, no two writes
# of one row both standing - one refused is right - and copies that converge; a
# read may be stale. Elle's cursor-stability
# is that: G0, G1, lost update, incompatible order out; G-single and G2 (read
# skew, write skew from stale reads) allowed. `converged` (results.yaml) is the
# rest.
[ ${#TEST_ARGS[@]} -gt 0 ] || TEST_ARGS=(--workload append --nemesis partition,kill,pause --time-limit 300
	--rate 50 --concurrency 2n --isolation serializable --expected-consistency-model cursor-stability)
if [ "$DEB" = auto ]; then
	DEB="$(ls -t "$REPO_ROOT"/target/debian/yt-cluster_*_amd64.deb 2>/dev/null | head -1 || true)"
fi
[ "$DEB" = none ] && DEB=""
[ -z "$DEB" ] || [ -f "$DEB" ] || { echo "--deb $DEB: no such file" >&2; exit 254; }

NET=yt-jepsen
PW=jepsen                                        # the nodes' postgres password (--pg-password)
CLUSTER=6a7e0000-0000-5000-8000-000000000035     # their cluster's uuid
STAGE=/tmp/yt-jepsen-build
names=(); for i in $(seq 1 "$NODES"); do names+=("n$i"); done

down() {
	local i
	rh "docker rm -f yt-jepsen-control >/dev/null 2>&1 || true"
	for i in $(seq 1 9); do rh "docker rm -f yt-jepsen-n$i >/dev/null 2>&1 || true"; done
	rh "docker network rm $NET >/dev/null 2>&1 || true"
}
trap '[ "$KEEP" = 1 ] || down' EXIT

started="$(date -u +%FT%TZ)"
echo "== jepsen: $NODES node(s), base $BASE, $([ -n "$DEB" ] && basename "$DEB" || echo "the base image's own package")"

# ── the images ────────────────────────────────────────────────────────────────
rh "rm -rf $STAGE && mkdir -p $STAGE/node/deb $STAGE/control"
tar -C "$HERE/docker" -cf - Dockerfile.node node-entrypoint.sh | rh "tar -C $STAGE/node -xf -"
tar -C "$HERE/docker" -cf - Dockerfile.control | rh "tar -C $STAGE/control -xf -"
tar -C "$HERE" -cf - project.clj src | rh "tar -C $STAGE/control -xf -"
[ -z "$DEB" ] || rh "cat > $STAGE/node/deb/yt-cluster.deb" < "$DEB"
echo "-- building yt-jepsen-node and yt-jepsen-control (a first build fetches the JDK, Leiningen and the test's dependencies)"
rh "docker build -q --build-arg BASE=$BASE -t yt-jepsen-node -f $STAGE/node/Dockerfile.node $STAGE/node" >/dev/null
rh "docker build -q -t yt-jepsen-control -f $STAGE/control/Dockerfile.control $STAGE/control" >/dev/null

# ── the cluster, from nothing ─────────────────────────────────────────────────
down
rh "docker network create $NET >/dev/null"
for n in "${names[@]}"; do
	rh "docker run -d --name yt-jepsen-$n --hostname $n --network $NET --network-alias $n --privileged \
		--restart unless-stopped -e POSTGRES_PASSWORD=$PW -e POSTGRES_DB=app \
		-e YT_PEERS='${names[*]}' -e YT_CLUSTER=$CLUSTER yt-jepsen-node >/dev/null"
done
rh "docker run -d --name yt-jepsen-control --hostname control --network $NET yt-jepsen-control >/dev/null"
# the control node's key, on every node: generated there, never leaves the docker host
rh "docker exec yt-jepsen-control ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa"
pub="$(rh "docker exec yt-jepsen-control cat /root/.ssh/id_rsa.pub")"
for n in "${names[@]}"; do
	printf '%s\n' "$pub" | rh "docker exec -i yt-jepsen-$n sh -c 'cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
done
await_nodes() {
	echo "-- waiting for each node's ytserv"
	for n in "${names[@]}"; do
		up=0
		for _ in $(seq 1 90); do
			rh "docker exec yt-jepsen-$n psql -X -tA -U postgres -d app -c \"select 1 from yt_info('o')\"" >/dev/null 2>&1 \
				&& { up=1; break; }
			sleep 2
		done
		[ "$up" = 1 ] || { echo "ERROR: $n did not come up" >&2; rh "docker logs --tail 40 yt-jepsen-$n" >&2 || true; exit 1; }
	done
}
await_nodes
# YT_LOG_LEVEL (by hand, e.g. debug): ytserv's log level on every node. Read only at
# its start, so the row is written with the triggers off - as yt_setup writes - and
# each ytserv is stopped for its entrypoint to start it again.
if [ -n "${YT_LOG_LEVEL:-}" ]; then
	echo "-- ytserv log level $YT_LOG_LEVEL"
	for n in "${names[@]}"; do
		rh "docker exec yt-jepsen-$n psql -X -q -U postgres -d postgres -c \"set session_replication_role = replica; \
			delete from yt_config where module = 'C' and name = 'log_level'; \
			insert into yt_config (name, module, value) values ('log_level', 'C', '$YT_LOG_LEVEL')\"" >/dev/null
		rh "docker exec yt-jepsen-$n sh -c 'pkill -x ytserv || true'"
	done
	sleep 8
	await_nodes
fi
build="$(rh "docker exec yt-jepsen-n1 /usr/local/bin/yt-cluster/ytserv --version" 2>/dev/null | awk 'NR == 1 {print $2}')"
build="${build:-unknown}"
echo "   yt-cluster $build on ${names[*]}"

# ── the test ──────────────────────────────────────────────────────────────────
nodes_csv="$(IFS=,; echo "${names[*]}")"
echo "-- lein run test --nodes $nodes_csv ${TEST_ARGS[*]}"
set +e
rh "docker exec yt-jepsen-control lein run test --nodes $nodes_csv --username root \
	--ssh-private-key /root/.ssh/id_rsa $(printf '%q ' "${TEST_ARGS[@]}")"
rc=$?
set -e

# ── the results, here ─────────────────────────────────────────────────────────
# the latest run only: the store and results.yaml hold no history
rm -rf "$HERE/store"; mkdir -p "$HERE/store"
rh "docker exec yt-jepsen-control tar -C /jepsen -cf - store" | tar -C "$HERE" -xf - 2>/dev/null \
	|| echo "WARN: no store copied from the control node" >&2
# store/<test>/<start time>/ - not store/latest, store/current or <test>/latest,
# Jepsen's links to it
run_dir="$(ls -td "$HERE"/store/*/20*/ 2>/dev/null | head -1 || true)"
run_dir="${run_dir%/}"
# Each node as the test left it: its cluster row, the sessions a transaction has
# held for over a minute - the workload's ended before the checkers ran, so these
# are writes the cluster never finished - and its prepared transactions
AFTER_SQL="$(cat <<'SQL'
\pset footer off
select value as cluster from json_to_recordset(yt_info('o')) as x(name text, value text) where name = 'cluster';
select pid, coalesce(nullif(application_name, ''), '(ytserv)') as client, state,
       wait_event_type || ':' || wait_event as waits, date_trunc('second', now() - xact_start) as held,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) as query
  from pg_stat_activity
 where datname = 'app' and pid <> pg_backend_pid() and xact_start < now() - interval '60 seconds'
 order by xact_start;
select gid, prepared from pg_prepared_xacts;
select value as recon from json_to_recordset(yt_info('E')) as x(name text, value text) where name = 'recon';
select t.name as table_cfg, (select string_agg(x.name || '=' || x.value, ', ') from json_to_recordset(yt_info('a:' || t.name)) as x(name text, value text)
        where x.name in ('sequential_consistency', 'cluster_commit', 'source.cluster_commit')) as cfg
  from yt_config t where t.module = 'A' and t.name like 'public.%' and t.name not like 'public.yt\_%' order by 1;
SQL
)"
STUCK_SQL="select count(*) from pg_stat_activity where datname = 'app' and pid <> pg_backend_pid() and xact_start < now() - interval '60 seconds'"
# the workload's tables, one checksum each: the copies converged when every node
# has the same: no divergence in the end, what every case is held to
SUMS_SQL="$(cat <<'SQL'
select string_agg(t || '=' || s, ' ' order by t) from (
  select c.relname as t, (xpath('/row/s/text()', query_to_xml(format(
    'select md5(coalesce(string_agg(t::text, %L order by t::text), %L)) as s from %I.%I t', ',', '', n.nspname, c.relname),
    false, true, '')))[1]::text as s
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'r' and n.nspname = 'public' and c.relname not like 'yt\_%') x
SQL
)"
# a node's data version (yt_info('I')): per term, the subterms it holds complete,
# the ones it misses, its last
DV_SQL="select name || ' = ' || value from json_to_recordset(yt_info('I')) as x(name text, value text) where name like 'data_version%' order by name"
CLUSTER_SQL="select value from json_to_recordset(yt_info('o')) as x(name text, value text) where name = 'cluster'"
# recon's counters (--recon): rows a round repaired, rows it blocked - a row
# whose copies it could not resolve takes no write, so it cannot drift further
RECON_SQL="select value from json_to_recordset(yt_info('E')) as x(name text, value text) where name = 'recon'"
# eventually: the copies may still be settling - a catch-up, a recon round - so
# they get CONVERGE_WAIT seconds to become equal, the time it took recorded
CONVERGE_WAIT="${CONVERGE_WAIT:-60}"
stuck=0; divergence=0; leaderless=0; converged=""; sums=(); repaired=0; blocked=0
sums_now() {
	sums=()
	for n in "${names[@]}"; do
		sums+=("$(printf '%s\n' "$SUMS_SQL" | rh "timeout 60 docker exec -i yt-jepsen-$n psql -X -tA -U postgres -d app" 2>/dev/null || echo "?")")
	done
}
sums_equal() {
	local s
	for s in "${sums[@]}"; do
		{ [ "$s" = "${sums[0]}" ] && [ -n "$s" ] && [ "$s" != "?" ]; } || return 1
	done
}
if [ -n "$run_dir" ]; then
	mkdir -p "$run_dir/docker"
	waited=0
	sums_now
	until sums_equal || [ "$waited" -ge "$CONVERGE_WAIT" ]; do
		sleep 5; waited=$((waited + 5)); sums_now
	done
	if sums_equal; then converged=yes; [ "$waited" = 0 ] || converged="yes, after ${waited}s"; else converged=no; fi
	# not converged: every node's rows, table by table (docker/<node>.rows.txt) - the
	# checksums say that the copies differ, the rows say where
	if [ "$converged" = no ]; then
		tables="$(sed 's/=[^ ]*//g' <<<"${sums[0]}")"
		for n in "${names[@]}"; do
			for t in $tables; do
				echo "== $t"
				rh "timeout 30 docker exec yt-jepsen-$n psql -X -tA -U postgres -d app -c 'select * from $t order by 1'" 2>&1 || true
			done > "$run_dir/docker/$n.rows.txt"
			# and what the node itself counts held and missing, term by term
			# (docker/<node>.dv.txt): a node short of rows that names no gap reads
			# itself complete, and pulls nothing more
			printf '%s\n' "$DV_SQL" | rh "timeout 30 docker exec -i yt-jepsen-$n psql -X -tA -U postgres -d app" \
				> "$run_dir/docker/$n.dv.txt" 2>&1 || true
		done
	fi
	i=0
	for n in "${names[@]}"; do
		printf '%s\n' "${sums[$i]}" > "$run_dir/docker/$n.sums.txt"; i=$((i + 1))
		r="$(printf '%s\n' "$RECON_SQL" | rh "timeout 30 docker exec -i yt-jepsen-$n psql -X -tA -U postgres -d app" 2>/dev/null || true)"
		[[ "$r" =~ ([0-9]+)\ repaired ]] && repaired=$((repaired + BASH_REMATCH[1]))
		[[ "$r" =~ ([0-9]+)\ blocked ]] && blocked=$((blocked + BASH_REMATCH[1]))
		printf '%s\n' "$AFTER_SQL" | rh "timeout 30 docker exec -i yt-jepsen-$n psql -X -U postgres -d app" \
			> "$run_dir/docker/$n.after.txt" 2>&1 || true
		s="$(printf '%s\n' "$STUCK_SQL" | rh "timeout 30 docker exec -i yt-jepsen-$n psql -X -tA -U postgres -d app" 2>/dev/null || true)"
		[[ "$s" =~ ^[0-9]+$ ]] && stuck=$((stuck + s))
		# a node naming no leader after the heal and the recovery time
		s="$(printf '%s\n' "$CLUSTER_SQL" | rh "timeout 30 docker exec -i yt-jepsen-$n psql -X -tA -U postgres -d app" 2>/dev/null || true)"
		if ! grep -q 'Leader' <<<"$s" || grep -qE 'None|discrepancy' <<<"$s"; then leaderless=$((leaderless + 1)); fi
		rh "docker logs yt-jepsen-$n" > "$run_dir/docker/$n.log" 2>&1 || true
		d="$(grep -c 'CLUSTER DIVERGENCE' "$run_dir/docker/$n.log" || true)"
		divergence=$((divergence + ${d:-0}))
	done
fi
case $rc in
	0) verdict=valid ;; 1) verdict=invalid ;; 2) verdict=unknown ;;
	254) verdict="bad options" ;; *) verdict="crashed, exit $rc" ;;
esac
anomalies=""; not=""
if [ -n "$run_dir" ] && [ -f "$run_dir/results.edn" ]; then
	# results.edn is pretty-printed: a list spans lines
	flat="$(tr -s '\n ' '  ' < "$run_dir/results.edn")"
	anomalies="$(grep -o ':anomaly-types ([^)]*)' <<<"$flat" | head -1 \
		| sed 's/^:anomaly-types (//; s/)$//; s/:\([^ ]*\)/\1/g' || true)"
	not="$(grep -o ':not #{[^}]*}' <<<"$flat" | head -1 \
		| sed 's/^:not #{//; s/}$//; s/:\([^ ]*\)/\1/g' || true)"
fi
{
	sed -n '1,/^# its store is/p' "$HERE/results.yaml" 2>/dev/null | grep '^#' || true
	echo "- run: $started"
	echo "  build: $build"
	echo "  nodes: $NODES"
	echo "  options: \"${TEST_ARGS[*]}\""
	echo "  verdict: $verdict"
	[ -z "$anomalies" ] || echo "  anomalies: [${anomalies// /, }]"
	[ -z "$not" ] || echo "  not: [${not// /, }]"
	[ -z "$run_dir" ] || echo "  stuck: $stuck"
	[ -z "$run_dir" ] || echo "  divergence: $divergence"
	[ -z "$run_dir" ] || echo "  leaderless: $leaderless"
	[ -z "$run_dir" ] || echo "  converged: $converged"
	[ -z "$run_dir" ] || echo "  recon: {repaired: $repaired, blocked: $blocked}"
	[ -z "$run_dir" ] || echo "  store: ${run_dir#"$HERE"/}"
} > "$HERE/results.yaml.new" && mv "$HERE/results.yaml.new" "$HERE/results.yaml"
echo "== $verdict${anomalies:+ - anomalies: $anomalies}${run_dir:+ - stuck $stuck, divergence $divergence, leaderless $leaderless, converged $converged, repaired $repaired, blocked $blocked - ${run_dir#"$HERE"/}}"
if [ "$KEEP" = 1 ]; then
	echo "-- left running: yt-jepsen-control and yt-jepsen-n1..n$NODES on network $NET"
fi
exit $rc
