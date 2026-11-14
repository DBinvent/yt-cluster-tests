#!/usr/bin/env bash
# [pgbench-m2m] Many writers to many copies (owner, 2026-11-09): six YT Cluster nodes over two
# docker hosts, each node running pgbench on its own tables - one data source per table - every
# table replicated to the other five; the load makes concurrent transactions on one row (two
# clients on pgbench's single branch row), which a commit mode that waits for no other copy
# lets diverge (owner, 2026-11-09: 2 clients a node, 0-400 ms between writes) - since 2026-11-10
# the origin refuses, 40001, the write its peers would apply out of order (README). A matrix of four cells:
#
#   cluster_commit  nodes=0 (the origin alone) and nodes=2, wal=half both
#   layout          db: a database per node (bench<i>); schema: one database `bench`,
#                   a schema per node (n<i>), each node's sessions on its own search_path
#
# and first, a backward-compatibility smoke test (owner, 2026-11-13: a basic cluster config and
# a smoke test - connected, rows both ways, no errors): one cluster of the image Docker Hub serves
# now (dbinvent/yt:latest, the last release, its own package) on the odd nodes and the deb under
# test on the even ones; it comes up, a row written on each node reaches every other one, and no
# node logs an error after it is up (M2M_COMPAT).
#
# A cell: a fresh cluster with the deb under test, M2M_SECONDS of pgbench on every node
# (M2M_CLIENTS clients, each sleeping 0..2*M2M_SLEEP_MS between transactions; a run a
# refused row aborts starts again), then the cluster must heal within 100 x the SQL timeout
# of the load's end - every node's tables one copy on all six, no row blocked (T3) - and
# the cell ends after M2M_COOL of cool-down. It fails when it does not heal in time.
#
#   pgbench-m2m/run.sh [--deb FILE] [--keep]     about 50 minutes: 4 cells of about 12
#
# Under the nightly's lock (nightly/locked.sh), as the nightly runs it (M2M_LOCKED).
# Settings: yt-cluster-tests/.env (env.example), a variable already set winning over it:
#   M2M_HOSTS       the two docker hosts, ssh targets or `local` (default: YX_HOST and
#                   LANE_HOST, the nightly's two); one host takes all six nodes
#   M2M_BUILD_HOST  where the image is built (default YX_HOST), carried to the other host
#   M2M_DEB         the deb under test (--deb; default the newest a nightly built)
#   M2M_NODES_SET   the cells' nodes values ("0 2"), M2M_LAYOUTS their layouts ("db schema")
#   M2M_COMPAT      the backward-compatibility smoke test: 1 (the default), or 0 to leave it out
#   M2M_SECONDS (300), M2M_CLIENTS (2), M2M_SLEEP_MS (200), M2M_COOL (300), M2M_SCALE (1)
#   M2M_CPUS, M2M_MEM  each node's limits (2, 2g)
#   YT_BASE_IMAGE   the image the node is built on (dbinvent/yt:latest)
#   M2M_OUT         where the run's logs and results go (default pgbench-m2m/logs/<stamp>)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
if [ -z "${M2M_LOCKED:-}" ]; then
	export M2M_LOCKED=1
	exec "$TESTS_ROOT/nightly/locked.sh" "$HERE/run.sh" "$@"
fi
if [ -f "$TESTS_ROOT/.env" ]; then
	_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_keep"; unset _keep
fi

KEEP=""
while [ $# -gt 0 ]; do
	case "$1" in
		--deb) M2M_DEB="$2"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done

read -ra HOSTS <<< "${M2M_HOSTS:-${YX_HOST:-} ${LANE_HOST:-}}"
[ "${#HOSTS[@]}" -ge 1 ] || { echo "M2M_HOSTS (or YX_HOST, LANE_HOST) names no docker host" >&2; exit 2; }
[ "${#HOSTS[@]}" -ge 2 ] || HOSTS+=("${HOSTS[0]}")
BUILD_HOST="${M2M_BUILD_HOST:-${YX_HOST:-${HOSTS[0]}}}"
NODES_SET="${M2M_NODES_SET:-0 2}"
LAYOUTS="${M2M_LAYOUTS:-db schema}"
COMPAT="${M2M_COMPAT:-1}"
SECONDS_RUN="${M2M_SECONDS:-300}"
CLIENTS="${M2M_CLIENTS:-2}"
SLEEP_MS="${M2M_SLEEP_MS:-200}"
COOL="${M2M_COOL:-300}"
SCALE="${M2M_SCALE:-1}"
CPUS="${M2M_CPUS:-2}"
MEM="${M2M_MEM:-2g}"
YT_BASE_IMAGE="${YT_BASE_IMAGE:-dbinvent/yt:latest}"
IMAGE=yt-m2m-node:local
# the backward-compatibility cell's nodes of the last release: the published image, pulled
IMAGE_OLD=yt-m2m-node-published:local
MIXED=""   # the backward-compatibility smoke test is running
NET=ytm2m
N=6
PW=m2m
OUT="${M2M_OUT:-$HERE/logs/$(date -u +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

say() { echo "[$(date -u +%T)] $*"; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
on() { # on <host> <command>: a shell command on a docker host (local: here); a refused ssh
	# (255: sshd's limit on unauthenticated connections) is tried again, twice
	local h="$1" n rc; shift
	if [ "$h" = local ]; then bash -c "$*"; return; fi
	for n in 1 2 3; do
		"${SSH[@]}" "$h" "$*" && return 0
		rc=$?; [ "$rc" = 255 ] || return "$rc"; sleep $((n * 2))
	done
	return "$rc"
}
host_of() { echo "${HOSTS[$(( ($1 - 1) / (N / 2) ))]}"; }   # nodes 1-3 on the first host, 4-6 on the second
# a node's image: in the backward-compatibility smoke test the odd nodes the published one - so
# each host runs both - else the deb under test's
image_of() { if [ -n "$MIXED" ] && [ $(($1 % 2)) = 1 ]; then echo "$IMAGE_OLD"; else echo "$IMAGE"; fi; }
nodes() { seq 1 "$N"; }
db_of() { [ "$LAYOUT" = db ] && echo "bench$1" || echo bench; }
sch_of() { [ "$LAYOUT" = db ] && echo public || echo "n$1"; }
q() { # q <node> <db> <sql>: as postgres, on the node's own socket
	printf '%s' "$3" | on "$(host_of "$1")" "docker exec -i m2m-y$1 psql -U postgres -XtA -v ON_ERROR_STOP=1 -d $2"
}
dk_build() { # dk_build <tag> <context> [args]: on BUILD_HOST, the context sent from here
	local tag="$1" ctx="$2"; shift 2
	if [ "$BUILD_HOST" = local ]; then docker build -q "$@" -t "$tag" "$ctx"
	else DOCKER_HOST="ssh://$BUILD_HOST" docker build -q "$@" -t "$tag" "$ctx"; fi
}
ship() { # BUILD_HOST's image to the other host
	local h
	for h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do
		[ "$h" = "$BUILD_HOST" ] && continue
		DOCKER_HOST="ssh://$BUILD_HOST" docker save "$1" | DOCKER_HOST="ssh://$h" docker load -q >/dev/null
	done
}

# ── the hosts' overlay network (as mongodb/run.sh): a node reached by its name from either host ──
SWARM_MADE=""; SWARM_JOINED=""
net_up() {
	local a="${HOSTS[0]}" b="${HOSTS[1]}" ip
	if [ "$(on "$a" "docker info --format '{{.Swarm.LocalNodeState}}'")" != active ]; then
		ip="$(on "$a" "ip route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if (\$i == \"src\") print \$(i + 1)}'")"
		on "$a" "docker swarm init --advertise-addr $ip" >/dev/null
		SWARM_MADE="$ip"
	fi
	if [ "$b" != "$a" ] && [ "$(on "$b" "docker info --format '{{.Swarm.LocalNodeState}}'")" != active ]; then
		on "$b" "docker swarm join --token $(on "$a" "docker swarm join-token -q worker") ${SWARM_MADE:-$(on "$a" "docker info --format '{{.Swarm.NodeAddr}}'")}:2377" >/dev/null
		SWARM_JOINED=1
	fi
	on "$a" "docker network inspect $NET >/dev/null 2>&1 || docker network create -d overlay --attachable $NET >/dev/null"
}
net_down() {
	on "${HOSTS[0]}" "docker network rm $NET >/dev/null 2>&1" || true
	[ -z "$SWARM_JOINED" ] || on "${HOSTS[1]}" "docker swarm leave >/dev/null 2>&1" || true
	[ -z "$SWARM_MADE" ] || on "${HOSTS[0]}" "docker swarm leave --force >/dev/null 2>&1" || true
}
clear_nodes() {
	local h
	for h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do
		on "$h" "docker ps -aq --filter name=m2m-y | xargs -r docker rm -f -v >/dev/null" || true
	done
}
cleanup() { [ -n "$KEEP" ] && return; clear_nodes; net_down; }
trap cleanup EXIT

# the module-A value of each cell's rule, wal=half: ClusterCommitCfg{mode NODES, at_least}
cc_of() { case "$1" in 0) echo CggSAhACGgIQAQ== ;; 2) echo CgoSBAgCEAIaAhAB ;; *) return 1 ;; esac; }

# ── one cell ──────────────────────────────────────────────────────────────────────
cell_up() { # a fresh cluster of N nodes, its pgbench tables under the cell's rule
	local i peers cluster tables db n done_on
	clear_nodes
	cluster="$(cat /proc/sys/kernel/random/uuid)"
	peers="$(for i in $(nodes); do printf 'm2m-y%s,' "$i"; done)"; peers="${peers%,}"
	if [ "$LAYOUT" = db ]; then DBS="$(for i in $(nodes); do printf 'bench%s,' "$i"; done)"; DBS="${DBS%,}"; tables="public.%"
	else DBS=bench; tables="n%.pgbench_%"; fi
	for i in $(nodes); do
		on "$(host_of "$i")" "docker run -d --name m2m-y$i --hostname m2m-y$i --network $NET --cpus $CPUS --memory $MEM \
			-e POSTGRES_PASSWORD=$PW -e YT_HOST=m2m-y$i -e YT_PEERS=$peers -e YT_CLUSTER=$cluster \
			-e YT_USERS_DB=$DBS -e YT_TABLES='$tables' -e M2M_LAYOUT=$LAYOUT -e M2M_SCALE=$SCALE -e M2M_NODES=$N \
			$(image_of "$i")" >/dev/null || return 1
	done
	for i in $(nodes); do
		for _ in $(seq 1 150); do q "$i" postgres "select 1 from yt_info('o')" >/dev/null 2>&1 && break; sleep 2; done
		q "$i" postgres "select 1 from yt_info('o')" >/dev/null 2>&1 || {
			say "m2m-y$i did not come up ($(image_of "$i")); the end of its log:"
			on "$(host_of "$i")" "docker logs --tail 25 m2m-y$i 2>&1" | sed 's/^/      /'
			return 1; }
	done
	# the rule on every pgbench table, written on the node that takes it - the leader
	for db in ${DBS//,/ }; do
		done_on=""; n=0
		for _ in $(seq 1 30); do
			for i in $(nodes); do
				n="$(q "$i" "$db" "WITH u AS (UPDATE public.yt_config SET value = '$CC' WHERE module = 'A'
					AND name LIKE '%.pgbench\\_%' RETURNING 1) SELECT count(*) FROM u" 2>/dev/null)" \
					&& { done_on="m2m-y$i"; break 2; }
			done
			sleep 2
		done
		[ -n "$done_on" ] && [ "$n" -gt 0 ] || { say "$db: the rule not written"; return 1; }
	done
	say "  up: $N nodes, rule $NODES (wal=half) on $DBS's pgbench tables"
	# which build each node runs: in the backward-compatibility smoke test, the two
	if [ -n "$MIXED" ]; then
		local vs=""
		for i in $(nodes); do vs="$vs m2m-y$i=$(q "$i" postgres "select x.value from json_to_recordset(yt_info('E')) \
			as x(name text, value text) where x.name = 'version'" 2>/dev/null || echo '?')"; done
		say "  builds:$vs"
	fi
}

cell_load() { # pgbench on every node against its own tables; a run a refused row aborted starts again
	local i db s
	for i in $(nodes); do
		db="$(db_of "$i")"; s="$(sch_of "$i")"
		on "$(host_of "$i")" "docker exec -i m2m-y$i sh -c 'cat > /tmp/bench.sql'" <<SQL || return 1
\\set aid random(1, 100000 * :scale)
\\set bid random(1, 1 * :scale)
\\set tid random(1, 10 * :scale)
\\set delta random(-5000, 5000)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;
\\set pause random(0, 2 * $SLEEP_MS)
\\sleep :pause ms
SQL
		on "$(host_of "$i")" "docker exec -d -e PGOPTIONS='-c search_path=$s' m2m-y$i sh -c 'end=\$((\$(date +%s) + $SECONDS_RUN)); \
			while [ \$(date +%s) -lt \$end ]; do pgbench -n -f /tmp/bench.sql -s $SCALE -c $CLIENTS -j 2 \
			-T \$((end - \$(date +%s) > 0 ? end - \$(date +%s) : 1)) -h /var/run/postgresql -U postgres $db; sleep 1; done \
			> /tmp/pgbench.log 2>&1'" || return 1
	done
}

load_wait() { # until no node runs its load any more
	local i busy
	sleep "$SECONDS_RUN"
	for _ in $(seq 1 30); do
		busy=0
		for i in $(nodes); do on "$(host_of "$i")" "docker exec m2m-y$i pgrep -f bench.sql" >/dev/null 2>&1 && busy=1; done
		[ "$busy" = 0 ] && return 0
		sleep 10
	done
}

load_result() { # transactions, failed, runs aborted and started again - over the six nodes
	local i p=0 f=0 a=0 line
	for i in $(nodes); do
		line="$(on "$(host_of "$i")" "docker exec m2m-y$i awk '/actually processed/{p+=\$NF} /number of failed/{f+=\$5} /Run was aborted/{a++} END{print p+0, f+0, a+0}' /tmp/pgbench.log" 2>/dev/null)"
		read -r x y z <<< "${line:-0 0 0}"; p=$((p + x)); f=$((f + y)); a=$((a + z))
	done
	echo "$p $f $a"
}

copy_sql() { # a fingerprint of node o's tables: tellers, branches, how many history rows, accounts' sum
	local s; s="$(sch_of "$1")"
	echo "select md5(coalesce((select string_agg(tid || ':' || tbalance, ',' order by tid) from $s.pgbench_tellers), '')
		|| coalesce((select string_agg(bid || ':' || bbalance, ',' order by bid) from $s.pgbench_branches), '')
		|| (select count(*) from $s.pgbench_history) || ':' || (select coalesce(sum(abalance), 0) from $s.pgbench_accounts))"
}

heal_state() { # "<tables one copy on all nodes> <T3 rows>"
	local o i same=0 n b
	for o in $(nodes); do
		n=$(for i in $(nodes); do q "$i" "$(db_of "$o")" "$(copy_sql "$o")" 2>/dev/null || echo "no answer $i"; done | sort -u | wc -l)
		[ "$n" = 1 ] && same=$((same + 1))
	done
	b="$(q 1 postgres "select count(*) from public.yt_config where module = 'Y' and name like '%|%'" 2>/dev/null || echo '?')"
	echo "$same $b"
}

# ── the run ───────────────────────────────────────────────────────────────────────
DEB="${M2M_DEB:-$(ls -t "$TESTS_ROOT"/nightly/logs/*/yt-cluster_*_amd64-pg18.deb 2>/dev/null | head -1)}"
[ -f "$DEB" ] || { say "FAIL no yt-cluster deb (--deb, M2M_DEB, or a nightly's under nightly/logs)"; exit 1; }
say "pgbench-m2m: hosts ${HOSTS[*]}, image built on $BUILD_HOST, deb $(basename "$DEB")"
# the base image as Docker Hub serves it now, for both images: a copy cached on the build host
# may be older than what is published
on "$BUILD_HOST" "docker pull -q $YT_BASE_IMAGE" >/dev/null || { say "FAIL $YT_BASE_IMAGE: no pull"; exit 1; }
CTX="$(mktemp -d)"; cp "$HERE/Dockerfile" "$HERE/10-m2m.sh" "$CTX/"; cp "$DEB" "$CTX/yt-cluster.deb"
dk_build "$IMAGE" "$CTX" --build-arg YT_BASE_IMAGE="$YT_BASE_IMAGE" >/dev/null || { say "FAIL the image did not build"; exit 1; }
rm -rf "$CTX"
ship "$IMAGE" || { say "FAIL the image did not reach the other host"; exit 1; }
net_up || { say "FAIL the overlay network"; exit 1; }

# the backward-compatibility smoke test's image of the last release: Docker Hub's, pulled above
if [ "$COMPAT" = 1 ]; then
	CTX="$(mktemp -d)"; cp "$HERE/Dockerfile" "$HERE/10-m2m.sh" "$CTX/"; : > "$CTX/yt-cluster.deb"
	dk_build "$IMAGE_OLD" "$CTX" --build-arg YT_BASE_IMAGE="$YT_BASE_IMAGE" --build-arg WITH_DEB=0 >/dev/null \
		|| { say "FAIL the image of the published release did not build"; exit 1; }
	rm -rf "$CTX"
	ship "$IMAGE_OLD" || { say "FAIL the published release's image did not reach the other host"; exit 1; }
	say "the published release: $YT_BASE_IMAGE, $(on "$BUILD_HOST" "docker image inspect -f '{{.Id}}' $YT_BASE_IMAGE" | cut -c1-19)"
fi

RESULTS="$OUT/results.tsv"
printf 'images\tnodes\tlayout\ttransactions\tfailed\taborted\tdivergence\thealed_s\tlimit_s\tafter_cool\n' > "$RESULTS"
RC=0
# compat_smoke: the backward-compatibility smoke test - the published release (odd nodes) and
# this build (even nodes) in one cluster: it comes up and takes its config, one row written on
# each node - a transaction on its own schema - reaches every other node, and no node logs an
# error, a panic or a divergence once it is up
compat_smoke() {
	local i n t0 el same blocked errs=0 bad=0 o
	MIXED=1; NODES=2; LAYOUT=schema; CC="$(cc_of 2)"
	say "== backward compatibility: the published release (odd nodes) with this build (even nodes)"
	if ! cell_up; then
		say "FAIL compat: the cluster did not come up"; RC=1
		for i in $(nodes); do on "$(host_of "$i")" "docker logs m2m-y$i" > "$OUT/compat-m2m-y$i.log" 2>&1 || true; done
		printf 'mixed\tsmoke\t-\t-\t-\t-\t-\tno cluster\t-\t-\n' >> "$RESULTS"; MIXED=""; return
	fi
	# each node's write, tried again while the cluster settles: one in its first seconds can be
	# refused while a node still counts a peer as off (the nightly of 2026-11-14: "need 3 of a
	# party of 2" on m2m-y1, 3 s after up) - rolled back whole, so tried again as it was. It
	# commits within a minute, or it fails. The tries said; the error check starts once every
	# write committed: it is for the cluster that took them
	local tries first
	for i in $(nodes); do
		tries=0; first=""
		while :; do
			tries=$((tries + 1))
			o="$(q "$i" bench "SET search_path = n$i; BEGIN;
				UPDATE pgbench_branches SET bbalance = bbalance + $i WHERE bid = 1;
				INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (1, 1, 1, $i, now());
				COMMIT;" 2>&1)" && break
			[ -n "$first" ] || first="$(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')"
			[ "$tries" -ge 30 ] && { say "  FAIL the write on m2m-y$i ($(image_of "$i")), $tries tries: $o"; bad=$((bad + 1)); break; }
			sleep 2
		done
		[ "$tries" = 1 ] || [ "$tries" -ge 30 ] || say "  m2m-y$i ($(image_of "$i")): its write committed on try $tries (the first refused: $first)"
	done
	t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; el=$(date +%s)
	# each node's tables one copy on all six: its write reached every other node
	for _ in $(seq 1 30); do
		read -r same blocked <<< "$(heal_state)"
		[ "$same" = "$N" ] && break
		sleep 4
	done
	el=$(( $(date +%s) - el ))
	n="$(for i in $(nodes); do q 1 bench "select count(*) from n$i.pgbench_history" 2>/dev/null; done | tr '\n' ' ')"
	# not counted: a peer's ask for a sub-term this node's wal-file does not hold, which each
	# version answers as none here - 1.20 logs it at ERRO (YT-E460), in a cluster of one version
	# too: 400 to 1,200 a node in the nightly's cells of 2026-11-12, all healed. 1.21 logs it
	# at debug since 2026-11-14 (ytserv wal_api.rs, [wal-miss]): a 1.21 node's line is a bug
	local miss='no data for requested subterm: .* not found in wal-file' skipped=0 k
	for i in $(nodes); do
		# the published release's nodes only: on this build's, the line counts
		if [ "$(image_of "$i")" = "$IMAGE_OLD" ]; then
			o="$(on "$(host_of "$i")" "docker logs --since $t0 m2m-y$i 2>&1 | grep -E ' ERRO | CRIT |panicked|CLUSTER DIVERGENCE' | grep -vE '$miss' | head -3")"
			k="$(on "$(host_of "$i")" "docker logs --since $t0 m2m-y$i 2>&1 | grep -cE '$miss'" 2>/dev/null)"
			skipped=$((skipped + ${k:-0}))
		else
			o="$(on "$(host_of "$i")" "docker logs --since $t0 m2m-y$i 2>&1 | grep -E ' ERRO | CRIT |panicked|CLUSTER DIVERGENCE' | head -3")"
		fi
		[ -z "$o" ] || { errs=$((errs + 1)); say "  m2m-y$i ($(image_of "$i")) logged:"; printf '%s\n' "$o" | sed 's/^/      /'; }
	done
	[ "$skipped" = 0 ] || say "  not counted: $skipped line(s) of the published release's nodes, a sub-term not in a node's wal-file (YT-E460, as in a cluster of 1.20 alone)"
	for i in $(nodes); do on "$(host_of "$i")" "docker logs m2m-y$i" > "$OUT/compat-m2m-y$i.log" 2>&1 || true; done
	if [ "$bad" = 0 ] && [ "$same" = "$N" ] && [ "$blocked" = 0 ] && [ "$errs" = 0 ]; then
		say "  OK the published release and this build: one cluster, each node's row on all $N in ${el}s (history rows on m2m-y1: $n), no error"
	else
		say "  FAIL compat: $bad write(s) refused, $same of $N nodes' tables one copy, $blocked T3 row(s), $errs node(s) logged an error"
		RC=1
	fi
	printf 'mixed\tsmoke\t-\t%s\t%s\t-\t-\t%s\t-\t%s/%s %s errors=%s\n' "$N" "$bad" "$el" "$same" "$N" "$blocked" "$errs" >> "$RESULTS"
	MIXED=""
}

# run_cell: one cell of the matrix, NODES and LAYOUT set
run_cell() {
	local images=new; [ -n "$MIXED" ] && images=mixed
	CC="$(cc_of "$NODES")" || { say "FAIL nodes=$NODES: no rule for it"; RC=1; return; }
	say "== ${MIXED:+the published release with this build, }nodes=$NODES, $LAYOUT layout"
	if ! cell_up; then
		say "FAIL $images nodes=$NODES $LAYOUT: the cluster did not come up"; RC=1
		for i in $(nodes); do on "$(host_of "$i")" "docker logs m2m-y$i" > "$OUT/$images-nodes$NODES-$LAYOUT-m2m-y$i.log" 2>&1 || true; done
		printf '%s\t%s\t%s\t-\t-\t-\t-\tno cluster\t-\t-\n' "$images" "$NODES" "$LAYOUT" >> "$RESULTS"; return
	fi
	started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if ! cell_load; then
		say "FAIL $images nodes=$NODES $LAYOUT: the load did not start"; RC=1
		printf '%s\t%s\t%s\t-\t-\t-\t-\tno load\t-\t-\n' "$images" "$NODES" "$LAYOUT" >> "$RESULTS"; return
	fi
	load_wait
	done_at=$(date +%s)
	read -r tx failed aborted <<< "$(load_result)"
	div=0
	for i in $(nodes); do
		d="$(on "$(host_of "$i")" "docker logs --since $started m2m-y$i 2>&1 | grep -c 'CLUSTER DIVERGENCE'" 2>/dev/null)"
		div=$((div + ${d:-0}))
	done
	say "  load: $tx transactions, $failed failed, $aborted runs aborted and started again, $div CLUSTER DIVERGENCE lines"
	t="$(q 1 postgres "select value from public.yt_config where module = 'C' and name = 'def_sql_timeout_sec'" 2>/dev/null || true)"
	LIMIT=$((100 * ${t:-1}))
	healed="no"
	while :; do
		el=$(( $(date +%s) - done_at ))
		read -r same blocked <<< "$(heal_state)"
		if [ "$same" = "$N" ] && [ "$blocked" = 0 ]; then healed="$el"; break; fi
		[ "$el" -ge "$LIMIT" ] && break
		sleep 10
	done
	if [ "$healed" = no ]; then
		say "  NOT healed within ${LIMIT}s (100 x the SQL timeout): $same of $N nodes' tables one copy, $blocked T3 row(s)"
		RC=1
	else
		say "  healed in ${healed}s of ${LIMIT}s"
	fi
	left=$(( COOL - ($(date +%s) - done_at) )); [ "$left" -gt 0 ] && sleep "$left"
	read -r same blocked <<< "$(heal_state)"
	say "  after the ${COOL}s cool-down: $same of $N nodes' tables one copy, $blocked T3 row(s)"
	for i in $(nodes); do on "$(host_of "$i")" "docker logs m2m-y$i" > "$OUT/$images-nodes$NODES-$LAYOUT-m2m-y$i.log" 2>&1 || true; done
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s/%s %s\n' "$images" "$NODES" "$LAYOUT" "$tx" "$failed" "$aborted" "$div" "$healed" "$LIMIT" \
		"$same" "$N" "$blocked" >> "$RESULTS"
}
[ "$COMPAT" = 1 ] && compat_smoke
for NODES in $NODES_SET; do for LAYOUT in $LAYOUTS; do run_cell; done; done
say "results ($OUT/results.tsv):"; column -t -s $'\t' "$RESULTS" 2>/dev/null || cat "$RESULTS"
exit "$RC"
