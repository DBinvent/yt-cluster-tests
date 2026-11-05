#!/usr/bin/env bash
# Concurrent writes of ONE document on two clusters of N nodes (PERF_PER_HOST on each of
# two docker hosts: 2 - a cluster of 4, 3 - of 6), the same hosts, limits and load, one
# after the other (README.md):
#   mongo  MongoDB, a replica set: every writer's write through the primary (w=majority,
#          j=true) - a replica set's one writer
#   yt     YT Cluster with DocumentDB: every writer writes to its own node's gateway, a 2PC
#          commit, the collection's table a merge table - the document merged path by path
#   yt1    the same with cluster_commit=nodes>=1: a write commits on its own node, the others
#          merge it in by path
#   yt2    yt1 with merge_async: a write committed at its own node first, checked in after
# The load: one document of one collection, every node's writer incrementing its own
# path of it at once (node i: PATHS[i-1].n, $inc) for the run's length, a refused increment
# tried again until it commits (writer/doc.py). After it every node's copy of the document
# must hold each path's count of committed increments.
#
#   run.sh [mongo] [yt] [yt1] [yt2]   (default mongo yt) - run it under ../nightly/locked.sh: the hosts
#                         are the nightly's
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

PHASES="${*:-mongo yt}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
LOG="$PERF_ROOT/logs/$STAMP"
RESULTS="$PERF_ROOT/results.yaml"
mkdir -p "$LOG"
exec > >(tee -a "$LOG/run.log") 2>&1

dk_build() { # dk_build <tag> <context> [build args]: on BUILD_HOST, the context sent from here
	local tag="$1" ctx="$2"; shift 2
	if [ "$BUILD_HOST" = local ]; then docker build -q "$@" -t "$tag" "$ctx"
	else DOCKER_HOST="ssh://$BUILD_HOST" docker build -q "$@" -t "$tag" "$ctx"; fi
}
ship() { # ship <image>: BUILD_HOST's image to every other host
	local h
	for h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do
		[ "$h" = "$BUILD_HOST" ] && continue
		say "carrying $1 to the other host"
		DOCKER_HOST="ssh://$BUILD_HOST" docker save "$1" | DOCKER_HOST="ssh://$h" docker load -q
	done
}
deb_under_test() {
	if [ -n "${PERF_DEB:-}" ]; then echo "$PERF_DEB"; return; fi
	ls -t "$TESTS_ROOT"/nightly/logs/*/yt-cluster_*_amd64-pg18.deb 2>/dev/null | head -1
}

# ── the hosts' overlay network: a container is reached by its name from either host ──
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
clear_nodes() { # every container of this suite, on every host
	local h
	for h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do
		on "$h" "docker ps -aq --filter name=ytperf- | xargs -r docker rm -f >/dev/null" || true
	done
}
# PERF_KEEP=1: a failed run leaves its containers and network for a look (run.sh again clears them)
cleanup() { local rc=$?; set +e; if [ "${PERF_KEEP:-0}" = 1 ] && { [ "$rc" != 0 ] || [ "${PERF_KEEP_ALL:-0}" = 1 ]; }; then say "kept the containers (PERF_KEEP)"; return; fi; clear_nodes; net_down; }
trap cleanup EXIT

# ── the writers ─────────────────────────────────────────────────────────────
wr() { # wr <host> <name> <doc.py args...>: writer/doc.py in a container of its own
	local h="$1" name="$2"; shift 2
	on "$h" "docker run --rm --name $name --network $NET --cpus $YCSB_CPUS $WRITER_IMAGE $(printf '%q ' "$@")"
}
writes() { # writes <url of node 1> .. <url of node N>: N writers at once, each its own path
	local i pids=()
	for i in $(nodes); do
		wr "$(host_of $i)" "ytperf-w$i" write "${!i}" "${PATHS[i-1]}" "$SECONDS_RUN" "$THREADS" \
			> "$LOG/$PHASE.w$i.json" 2> "$LOG/$PHASE.w$i.err" & pids+=($!)
	done
	for i in "${pids[@]}"; do wait "$i" || true; done
}
reads() { # reads <url of node 1> .. <url of node 4>: each node's counters, a line each
	local i
	for i in $(nodes); do wr "$(host_of $i)" "ytperf-r$i" read "${!i}" 2>/dev/null || echo '{}'; done
}
# every node's counter of every path is that path's writer's committed increments:
# what each node holds, read until it is so or 90 s are gone
check_counters() { # check_counters <url of node 1> .. <url of node 4>
	local want got
	want="$(cat "$LOG/$PHASE".w*.json | python3 -c "
import json, sys
print(json.dumps({json.loads(l)['path']: json.loads(l)['ok'] for l in sys.stdin if l.strip()}, sort_keys=True))")"
	local t0=$SECONDS
	for _ in $(seq 1 45); do
		reads "$@" > "$LOG/$PHASE.counters"
		got="$(python3 -c "
import json, sys
want = json.loads(sys.argv[1])
rows = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
print('yes' if len(rows) == int(sys.argv[3]) and all({k: r.get(k) for k in want} == want for r in rows) else 'no')" "$want" "$LOG/$PHASE.counters" "$N")"
		[ "$got" = yes ] && break
		sleep 2
	done
	# how long after the writes every node held every count (the reads' own time in it)
	[ "$got" = yes ] && echo "$((SECONDS - t0))" > "$LOG/$PHASE.converged_s"
	echo "$got"
}
phase_yaml() { # phase_yaml <counters match: yes/no> <extra yaml lines, indented 4>
	local match="$1"; shift
	echo "  $PHASE:"
	printf '%s\n' "$@"
	python3 - "$LOG" "$PHASE" "$match" "$N" <<'EOF'
import json, sys
log, phase, match = sys.argv[1:4]
w = []
for i in range(1, int(sys.argv[4]) + 1):
    try:
        w.append(json.loads(open(f"{log}/{phase}.w{i}.json").read().strip().splitlines()[-1]))
    except Exception:
        w.append({"path": "?", "ok": 0, "retries": 0, "abandoned": 0, "ops_s": 0, "avg_ms": 0, "p95_ms": 0, "p99_ms": 0, "errors": {"no result": 1}})
print("    writers:")
for x in w:
    print(f"      - {{path: {x['path']}, committed: {x['ok']}, retries: {x['retries']}, abandoned: {x['abandoned']}, "
          f"ops_s: {x['ops_s']}, avg_ms: {x['avg_ms']}, p95_ms: {x['p95_ms']}, p99_ms: {x['p99_ms']}}}")
    for e, n in x.get("errors", {}).items():
        print(f"        # {n} x {e}")
print(f"    total: {{ops_s: {round(sum(x['ops_s'] for x in w), 1)}, committed: {sum(x['ok'] for x in w)}, "
      f"retries: {sum(x['retries'] for x in w)}}}")
print("    nodes:")
for i, l in enumerate(l for l in open(f"{log}/{phase}.counters") if l.strip()):
    print(f"      - {{node: {i + 1}, counters: {l.strip()}}}")
print(f"    counters_match_on_every_node: {match}")
try:
    print(f"    converged_after_s: {int(open(f'{log}/{phase}.converged_s').read())}")
except Exception:
    pass
EOF
}

# ── MongoDB: a replica set of N ─────────────────────────────────────────────
mongo_phase() {
	PHASE=mongo
	local i members="" url hosts="" keys
	say "mongo: $N nodes, $PER_HOST on each host, $CPUS cpu and $MEM each"
	for i in $(nodes); do
		on "$(host_of $i)" "docker run -d --name ytperf-m$i --hostname ytperf-m$i --network $NET --cpus $CPUS --memory $MEM \
			$MONGO_IMAGE mongod --replSet rs0 --bind_ip_all" >/dev/null
		members+="${members:+,}{_id: $((i - 1)), host: 'ytperf-m$i:27017'}"
		hosts+="${hosts:+,}ytperf-m$i:27017"
	done
	for _ in $(seq 1 30); do
		on "${HOSTS[0]}" "docker exec ytperf-m1 mongosh --quiet --eval 'db.runCommand({ping: 1}).ok'" 2>/dev/null | grep -q 1 && break
		sleep 2
	done
	on "${HOSTS[0]}" "docker exec ytperf-m1 mongosh --quiet --eval \"rs.initiate({_id: 'rs0', members: [$members]})\"" >/dev/null
	for _ in $(seq 1 60); do
		[ "$(on "${HOSTS[0]}" "docker exec ytperf-m1 mongosh --quiet --eval \
			\"rs.status().members.filter(m => m.stateStr == 'PRIMARY' || m.stateStr == 'SECONDARY').length\"" 2>/dev/null)" = "$N" ] && break
		sleep 2
	done
	url="mongodb://$hosts/?replicaSet=rs0&w=majority&journal=true"
	wr "${HOSTS[0]}" ytperf-create create "$url" || die "mongo: the document was not written"
	say "mongo: $SECONDS_RUN s, $N writers, $THREADS threads each, one document, each its own path (w=majority, j=true)"
	local m=() u=() i
	for i in $(nodes); do u+=("$url"); done
	writes "${u[@]}"
	for i in $(nodes); do m+=("mongodb://ytperf-m$i:27017/?directConnection=true&readPreference=secondaryPreferred"); done
	phase_yaml "$(check_counters "${m[@]}")" "    image: $MONGO_IMAGE" "    write_concern: {w: majority, j: true}" \
		"    writes_to: the primary (a replica set's one writer)" >> "$LOG/result.yaml"
	[ "${PERF_KEEP_ALL:-0}" = 1 ] || clear_nodes
}

# ── YT Cluster with DocumentDB ──────────────────────────────────────────────
ysql() { # ysql <node> <sql> [db]: as postgres
	printf '%s\n' "$2" | on "$(host_of "$1")" "docker exec -i ytperf-y$1 psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d ${3:-$DOCDB_DB}"
}
yt_leader() { # every node names a leader: yt_info('O')'s row `cluster`, as topology's await_cluster
	local i v
	for i in $(nodes); do
		v="$(ysql "$i" "select yt_info('O')" postgres 2>/dev/null | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
print(next((r.get('value', '') for r in rows if r.get('name') == 'cluster'), ''))")"
		case "$v" in *"Leader: None"*) return 1 ;; *Leader*) ;; *) return 1 ;; esac
	done
}
yt_phase() {
	PHASE="${YT_PHASE:-yt}"
	local i peers cluster tbl t cfg ver docs
	cluster="$(cat /proc/sys/kernel/random/uuid)"
	peers="$(for i in $(nodes); do printf 'ytperf-y%s,' "$i"; done)"; peers="${peers%,}"
	say "yt: $N nodes, $PER_HOST on each host, $CPUS cpu and $MEM each, DocumentDB in $DOCDB_DB"
	for i in $(nodes); do
		on "$(host_of $i)" "docker run -d --name ytperf-y$i --hostname ytperf-y$i --network $NET --cpus $CPUS --memory $MEM \
			-e POSTGRES_PASSWORD=perf -e YT_HOST=ytperf-y$i -e YT_PEERS=$peers -e YT_CLUSTER=$cluster \
			-e YT_USERS_DB=$DOCDB_DB -e DOCDB_DB=$DOCDB_DB $YTDOC_IMAGE" >/dev/null
	done
	for i in $(nodes); do
		for _ in $(seq 1 90); do
			[ "$(on "$(host_of $i)" "docker inspect --format '{{.State.Health.Status}}' ytperf-y$i")" = healthy ] && break
			sleep 2
		done
	done
	for _ in $(seq 1 60); do yt_leader && break; sleep 3; done
	yt_leader || die "yt: no leader on every node"
	# DocumentDB on every node alike: the extension, the collection - the same table on
	# each - and the gateway's user
	for i in $(nodes); do
		ysql "$i" "set client_min_messages = warning; create extension if not exists documentdb cascade;
			select documentdb_api.create_collection('perf', 'doc');
			select documentdb_api.create_user('{\"createUser\": \"$YCSB_USER\", \"pwd\": \"$YCSB_PASS\",
				\"roles\": [{\"role\": \"readWriteAnyDatabase\", \"db\": \"admin\"}, {\"role\": \"clusterAdmin\", \"db\": \"admin\"}]}');" >/dev/null
		t="$(ysql "$i" "select 'documentdb_data.documents_' || collection_id from documentdb_api_catalog.collections
			where database_name = 'perf' and collection_name = 'doc'")"
		[ -z "${tbl:-}" ] || [ "$t" = "$tbl" ] || die "yt: the collection's table is $t on node $i, $tbl on node 1"
		tbl="$t"
	done
	# [documentdb] a merge table: its document merged path by path
	cfg="$(on "${HOSTS[0]}" "docker exec ytperf-y1 ytctl --encode-table-cfg 'merge${YT_CFG_EXTRA:-}'" | tail -1)"
	for i in $(nodes); do
		ysql "$i" "begin;
			alter table public.yt_config disable trigger user;
			delete from public.yt_config where module = 'A' and name = '$tbl';
			insert into public.yt_config (name, module, value) values ('$tbl', 'A', '$cfg');
			alter table public.yt_config enable trigger user;
			commit;
			drop trigger if exists zytsync_${tbl//./_}_trigger on $tbl;
			create trigger zytsync_${tbl//./_}_trigger after insert or update or delete on $tbl
				for each row execute procedure yt_synchronize();
			drop trigger if exists zytsynct_${tbl//./_} on $tbl;
			create trigger zytsynct_${tbl//./_} after truncate on $tbl
				for each statement execute procedure yt_synchronize();" >/dev/null
	done
	# PERF_DEBUG=1: ytserv's debug log on every node, to trace a write
	if [ "${PERF_DEBUG:-0}" = 1 ]; then
		for i in $(nodes); do
			ysql "$i" "begin; alter table public.yt_config disable trigger user;
				delete from public.yt_config where module = 'C' and name = 'log_level';
				insert into public.yt_config (name, module, value) values ('log_level', 'C', 'debug');
				alter table public.yt_config enable trigger user; commit;" postgres >/dev/null
		done
	fi
	# the table's rule is read when ytserv starts: each starts again (the entrypoint, 5 s on)
	for i in $(nodes); do on "$(host_of $i)" "docker exec ytperf-y$i bash -c 'kill \$(cat /run/ytserv.pid)'"; done
	sleep 10
	for _ in $(seq 1 60); do yt_leader && break; sleep 3; done
	yt_leader || die "yt: no leader after the restart"
	ver="$(on "${HOSTS[0]}" "docker exec ytperf-y1 /usr/local/bin/yt-cluster/ytserv --version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	url() { echo "mongodb://$YCSB_USER:$YCSB_PASS@ytperf-y$1:10260/?authSource=admin&authMechanism=SCRAM-SHA-256&directConnection=true"; }
	for _ in $(seq 1 30); do wr "${HOSTS[0]}" ytperf-create create "$(url 1)" 2>/dev/null && break; sleep 3; done
	for _ in $(seq 1 30); do
		docs=0; for i in $(nodes); do [ "$(ysql "$i" "select count(*) from $tbl")" = 1 ] && docs=$((docs + 1)); done
		[ "$docs" = "$N" ] && break; sleep 2
	done
	[ "$docs" = "$N" ] || die "yt: the document reached $docs node(s) of $N"
	say "yt: $SECONDS_RUN s, $N writers, each to its own node's gateway, $THREADS threads each, one document, each its own path"
	local u=()
	for i in $(nodes); do u+=("$(url $i)"); done
	writes "${u[@]}"
	phase_yaml "$(check_counters "${u[@]}")" "    yt: $ver" \
		"    documentdb: ${DOCDB_IMAGE##*:}" "    commit: ${YT_COMMIT_SAID:-2PC (the party)}, the document merged path by path" \
		"    table: $tbl" >> "$LOG/result.yaml"
	[ "${PERF_KEEP_ALL:-0}" = 1 ] || clear_nodes
}

yt2_phase() { # yt with merge_async under cluster_commit=nodes>=1: committed first, checked in after
	YT_PHASE=yt2 YT_CFG_EXTRA='; merge_async; cluster_commit=nodes>=1' \
		YT_COMMIT_SAID='async merge (committed at its own node first, checked in after; the others merge it in)' yt_phase
}

yt1_phase() { # yt with cluster_commit=nodes>=1
	YT_PHASE=yt1 YT_CFG_EXTRA='; cluster_commit=nodes>=1' \
		YT_COMMIT_SAID='nodes>=1 (its own node; the others merge it in)' yt_phase
}

# ── the run ─────────────────────────────────────────────────────────────────
DEB="$(deb_under_test)"
[ -f "$DEB" ] || die "no yt-cluster deb (PERF_DEB, or a nightly's under ../nightly/logs)"
say "hosts: ${#HOSTS[@]} ($(printf '%s\n' "${HOSTS[@]}" | sort -u | wc -l) distinct), images built on the first; deb $(basename "$DEB")"
clear_nodes
CTX="$(mktemp -d)"
cp -r "$PERF_ROOT/ytdoc/." "$CTX/"
cp "$DEB" "$CTX/yt-cluster.deb"
say "building $YTDOC_IMAGE and $WRITER_IMAGE"
dk_build "$YTDOC_IMAGE" "$CTX" --build-arg YT_BASE_IMAGE="$YT_BASE_IMAGE" --build-arg DOCDB_IMAGE="$DOCDB_IMAGE" >/dev/null
dk_build "$WRITER_IMAGE" "$PERF_ROOT/writer" >/dev/null
ship "$YTDOC_IMAGE"; ship "$WRITER_IMAGE"
for h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do on "$h" "docker pull -q $MONGO_IMAGE" >/dev/null; done
net_up
{
	echo "- run: $STAMP"
	echo "  nodes: $N  # $PER_HOST on each of two hosts"
	echo "  limits: {cpus: $CPUS, mem: $MEM, writer_cpus: $YCSB_CPUS}"
	echo "  workload: {seconds: $SECONDS_RUN, threads_per_client: $THREADS, field_len: $FIELD_LEN, documents: 1, \
clients: $N, paths: [${PATHS[*]:0:N}]}"
} > "$LOG/result.yaml"
for p in $PHASES; do "${p}_phase"; done
cat "$LOG/result.yaml" >> "$RESULTS"
say "done: $LOG/result.yaml, appended to $(basename "$RESULTS")"
cat "$LOG/result.yaml"
