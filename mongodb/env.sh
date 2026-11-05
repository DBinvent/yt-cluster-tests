#!/usr/bin/env bash
# mongodb/: one document every node writes at once, each its own path - MongoDB, a replica
# set, and YT Cluster with DocumentDB and its gateway, the document merged path by path - on
# a cluster of 4 or 6 nodes over two docker hosts, CPU-limited. Settings and helpers; run.sh
# runs it (README.md).
#
# Settings: yt-cluster-tests/.env (not committed, see env.example), a variable already
# set in the environment winning over it.
#   PERF_HOSTS       the two docker hosts, ssh targets (default: YX_HOST and LANE_HOST,
#                    the nightly's two); one host takes all four nodes
#   PERF_BUILD_HOST  where the images are built (default: YX_HOST) - carried to the
#                    other host by docker save | docker load, never built there
#   PERF_DEB         the yt-cluster deb under test (default: the newest a nightly built)
#   PERF_PER_HOST                the database nodes on each host (default 2: a cluster of 4;
#                                3: a cluster of 6)
#   PERF_CPUS, PERF_MEM          each database node's limits (default 2, 2g)
#   PERF_YCSB_CPUS               each writer's (default 1)
#   PERF_SECONDS, PERF_THREADS   each phase's writes and each writer's threads (120, 4)
#   PERF_FIELD_LEN               the bytes a YCSB write set (100; the writer increments)
#   MONGO_IMAGE, YT_BASE_IMAGE, DOCDB_IMAGE  the images built on (mongo:7.0,
#                    dbinvent/yt:latest, DocumentDB's own image of its 1.0 release)
PERF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$PERF_ROOT/.." && pwd)"
if [ -f "$TESTS_ROOT/.env" ]; then
	_yx_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_yx_keep"; unset _yx_keep
fi

read -ra HOSTS <<< "${PERF_HOSTS:-${YX_HOST:-} ${LANE_HOST:-}}"
[ "${#HOSTS[@]}" -ge 1 ] || { echo "PERF_HOSTS (or YX_HOST, LANE_HOST) names no docker host" >&2; exit 2; }
[ "${#HOSTS[@]}" -ge 2 ] || HOSTS+=("${HOSTS[0]}")
BUILD_HOST="${PERF_BUILD_HOST:-${YX_HOST:-${HOSTS[0]}}}"
CPUS="${PERF_CPUS:-2}"
MEM="${PERF_MEM:-2g}"
PER_HOST="${PERF_PER_HOST:-2}"
N=$((PER_HOST * 2))   # the cluster's nodes: PER_HOST on each of the two hosts
YCSB_CPUS="${PERF_YCSB_CPUS:-1}"
SECONDS_RUN="${PERF_SECONDS:-120}"
THREADS="${PERF_THREADS:-4}"
FIELD_LEN="${PERF_FIELD_LEN:-100}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7.0}"
YT_BASE_IMAGE="${YT_BASE_IMAGE:-dbinvent/yt:latest}"
DOCDB_IMAGE="${DOCDB_IMAGE:-ghcr.io/documentdb/documentdb/documentdb-local:pg18-1.0.0}"
YTDOC_IMAGE=ytperf-ytdoc:local
YCSB_IMAGE=ytperf-ycsb:local
WRITER_IMAGE=ytperf-writer:local
NET=ytperf
DOCDB_DB=docdb
# the one document every node writes, each node its own path of it: node i PATHS[i-1]
PATHS=(education jobs achievement awards social hobby)
YCSB_USER=ycsb
YCSB_PASS=ycsb-perf

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
on() { # on <host> <command>: run on a docker host (local: here)
	local h="$1"; shift
	if [ "$h" = local ]; then bash -c "$*"; else "${SSH[@]}" "$h" "$*"; fi
}
host_of() { echo "${HOSTS[$(( ($1 - 1) / PER_HOST ))]}"; } # nodes 1..PER_HOST on the first host, the rest on the second
nodes() { seq 1 "$N"; }
say() { echo "[$(date -u +%T)] $*"; }
die() { say "FAIL $*"; exit 1; }
