#!/usr/bin/env bash
# The nightly end-to-end run: test what changed, publish what passed.
#
#   nightly/nightly.sh                # what cron runs at 05:00 UTC
#   nightly/nightly.sh --dry-run      # say what a run would do, run nothing
#   nightly/nightly.sh --no-publish   # build and test only
#   nightly/nightly.sh --suites "unit lxc"
#   nightly/nightly.sh --coverage     # measure coverage this run (--no-coverage: not)
#   nightly/locked.sh <command...>    # anything else on the test hosts, under the same lock
#
# Another run in progress (the lock, nightly/state/nightly.lock), or no code
# change: exit 75 at once, nothing run, nothing appended, nothing sent.
#
# 1. Changes: a fingerprint of the .rs files of every watched repository - their
#    content, committed or not, tracked or not (ignored ones never) - against the
#    one the last run tested. A code change is a .rs change and nothing else: no
#    .rs change, no run - nothing built, nothing appended, no package, no message,
#    whatever was asked: no change, no run, no publish, no message. This
#    repository is never watched: a change to a test is not a change to test.
# 2. Version: when the build in yt-cluster/ytctl/Cargo.toml (what ytctl --version
#    prints, 1.20.0) is the one last published, its patch is bumped - in the
#    working tree, uncommitted - and ytserv's version follows it: one number for
#    the package and the daemon. The deb carries only its major.minor (1.20):
#    each build of a release replaces the one before under the same name, in the
#    repository and on a node (apt install --reinstall).
# 3. Build: the extension for every PostgreSQL major, the release binaries, the
#    PostgreSQL 18 deb the suites install, the etcd example 93_etcd needs.
# 4. Suites (NIGHTLY_SUITES), each with its own log, its OK/PASS and FAIL lines
#    counted; a suite that exits non-zero with no FAIL line counts one failure.
#    Exit 77 is a skip: a suite whose outside service is not there (llm: the
#    model service) tested nothing - recorded as skipped, neither passed nor
#    failed, and it does not hold back the publish.
#    jepsen: four of jepsen/'s cases (jepsen/nightly_cases.sh) on YX_HOST, about
#    20 minutes - the ones that found most of jepsen/findings.md, judged as their
#    retests were, as a suite of its own.
#    LANE_HOST set: three lanes at once, one suites.tsv - unit here, the only
#    suite this host runs; LANE_SUITES (topology, topology-py) on LANE_HOST; the rest, in turn,
#    on YX_HOST and RMC_SSH, lxc and migrate on LXC_SSH. LANE_HOST's images are built
#    where the rest's are and carried over; it builds nothing.
# 5. Every suite passed (and NIGHTLY_PUBLISH=1): the release build - every glibc
#    target, EL9, musl, the extension - then the deb into the apt repository, the
#    EL9 rpm into REPO_DIR/yum/el9, the tarball of the static (musl) binaries into
#    REPO_DIR/paks (ytcluster_dist/build_tgz.sh), and the image dbinvent/yt
#    (ytcluster_dist/docker/publish.sh: built from the deb as apt serves it). And
#    sge, when its version (sge/Cargo.toml) is one the repository does not list:
#    its deb, its tarball and the image dbinvent/sge (sge/dist/publish.sh). A
#    failed build publishes nothing; a failed step stops the ones after it.
# 6. The run is appended to nightly/results.yaml, oldest first: a page shows it
#    newest first by reading the list in reverse.
# 7. A run that published (a promotion) renews the badge dbinvent.com shows:
#    drawn from its entry (nightly/badge.py: shields.io renders the SVG) into
#    REPO_DIR/paks/nightly/badge.svg - served by the apt host as
#    https://apt.dbinvent.com/paks/nightly/badge.svg, on the page within five
#    minutes, no push. Beside it the regular ytserv's own badge (nightly/safety_badge.py):
#    cargo audit over ytserv's tree, and its own crates compiled with unsafe code
#    forbidden - REPO_DIR/paks/nightly/ytserv-safety.svg, renewed the same way.
#    Any other run leaves the badges as they are. NIGHTLY_PUSH=1 commits results.yaml (and
#    nightly/coverage.yaml) and pushes them - the history on GitHub - on main
#    and only when no other commit is waiting to be pushed; otherwise they wait
#    for a hand push.
#
# Coverage: a run that finds nightly/coverage.yaml missing, or listing fewer
# suites than a whole run, measures it - so renaming or deleting that file has
# the next run with a code change measure again (a run of its own for it, with no
# change, there is not: no change, no run). Such a run builds an instrumented
# ytserv and ytctl into a second package (nightly/coverage.sh) that every suite
# installs in place of the plain one, runs the unit tests under cargo llvm-cov,
# collects each suite's counts from its docker volume (lxc: from the container)
# and writes nightly/coverage.yaml plus a `coverage:` percent in its results.yaml
# entry; the per-file report stays in the run's logs. A measurement that produced
# no report is not retried for the same sources (state/coverage.tried.fp) unless
# asked with --coverage.
#
# Settings: ../.env (see ../env.example). State (fingerprints, what was
# published) in nightly/state/, logs in nightly/logs/<run>/ - neither committed.
set -uo pipefail
export PATH="$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG=C.UTF-8
# cron sets LOGNAME, not USER - and rppd's default connection is $USER@$USER: under
# cron it fell back to `postgres` and 19 ytserv unit tests failed on peer auth
export USER="${USER:-$(id -un)}"

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TESTS="$(cd "$HERE/.." && pwd)"
if [ -f "$TESTS/.env" ]; then
	_keep="$(export -p)"; set -a; . "$TESTS/.env"; set +a; eval "$_keep"; unset _keep
fi
GIT_ROOT="$(cd "$TESTS/.." && pwd)"
YT_PGXT="${YT_PGXT:-$GIT_ROOT/yt-cluster}"
DIST="${DIST:-$GIT_ROOT/ytcluster_dist}"
INFRA_APT="${INFRA_APT:-$GIT_ROOT/infra_apt}"
REPO_DIR="${REPO_DIR:-}"   # the apt repository root, yum/el9 under it: .env
GPG_KEY="${GPG_KEY:-D9988976429AE53380B9E08C47C722E2BC8094E8}"
# the edge's copies of what a publish replaced (purge_edge): .env; the token stays
# in this shell, no suite needs it
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_PURGE_TOKEN="${CF_PURGE_TOKEN:-}"; export -n CF_PURGE_TOKEN
RMC_SSH="${RMC_SSH:-}"
RMC_DIR="${RMC_DIR:-rmc-run}"
# [lanes] LANE_HOST: a second docker host, an ssh target. The suites of LANE_SUITES
# (default topology and topology-py, fixture A's two halves - together as long as
# the rest) run there in a lane of their own, beside the rest on YX_HOST and
# RMC_SSH, and unit runs in a third, here: the one suite this host runs. LANE_HOST's
# images are built where the rest's are and carried over (docker save | docker
# load, topology/env.sh ship_image): nothing is built on it. Only suites whose
# images can be carried: topology, topology-py and the rmc layouts (topo,
# topo-faults, topo-membership, rmc). Empty: every suite in turn.
# topology-py alone on the other docker host (LANE_SUITES=topology) adds its
# length to the rest's lane: move rmc layouts here to even them up.
LANE_HOST="${LANE_HOST:-}"
LANE_SUITES="${LANE_SUITES:-topology topology-py}"
if [ -n "$LANE_HOST" ] && { [ -z "$RMC_SSH" ] || [ "${YX_HOST:-local}" = local ]; }; then
	echo "LANE_HOST set without RMC_SSH and YX_HOST, where its images are built - one lane" >&2
	LANE_HOST=""
fi
for _s in $LANE_SUITES; do
	case "$_s" in topology|topology-py|topo|topo-faults|topo-membership|rmc) ;;
		*) echo "LANE_SUITES: $_s cannot run on LANE_HOST - it stays with the rest" >&2 ;; esac
done; unset _s
in_lane() {
	[ -n "$LANE_HOST" ] || return 1
	case "$1" in topology|topology-py|topo|topo-faults|topo-membership|rmc) ;; *) return 1 ;; esac
	case " $LANE_SUITES " in *" $1 "*) true ;; *) false ;; esac
}
# [lanes] LXC_SSH: the host the lxc suite's LXD container runs on - an ssh target,
# its scripts and the build's files copied there (s_lxc); empty: here
LXC_SSH="${LXC_SSH:-}"
# topology-py: fixture A's server-function scripts, on ytserv-py (the build with
# Python functions); topology: the rest of it, on the regular ytserv
ALL_SUITES="unit topology topology-py hier lxc migrate llm topo topo-faults topo-membership rmc jepsen"
# suites a coverage measurement does not count: migrate installs the package as an
# operator does, with no instrumented binaries - asking for it would have every
# night measure again, since no measurement can list it; jepsen's nodes run the
# package in an image of their own, whose counts nothing collects
COV_EXEMPT="migrate jepsen"
NIGHTLY_SUITES="${NIGHTLY_SUITES:-$ALL_SUITES}"
NIGHTLY_PUBLISH="${NIGHTLY_PUBLISH:-1}"
# Where the builds' containers run (the extension, the glibc/EL9/musl targets):
# a docker daemon by DOCKER_HOST syntax - ssh://<host> to keep them off this host.
# Empty: this host's own. Every build here uses build contexts and `docker cp`,
# never a bind mount, so a remote daemon builds the same thing.
NIGHTLY_DOCKER_HOST="${NIGHTLY_DOCKER_HOST:-}"
if [ -n "$NIGHTLY_DOCKER_HOST" ]; then export DOCKER_HOST="$NIGHTLY_DOCKER_HOST"; else unset DOCKER_HOST; fi
STATE="$HERE/state"
RESULTS="$HERE/results.yaml"
mkdir -p "$STATE" "$HERE/logs"

COVERAGE_FILE="$HERE/coverage.yaml"
COVERAGE=auto; COV_ASKED=0
DRY=0; ARGS="$*"
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1; shift ;;
		--no-publish) NIGHTLY_PUBLISH=0; shift ;;
		--suites) NIGHTLY_SUITES="$2"; shift 2 ;;
		--coverage) COVERAGE=1; COV_ASKED=1; shift ;;
		--no-coverage) COVERAGE=0; shift ;;
		-h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

# One run at a time, on this host: the suites share one docker host, and two runs
# there tear down each other's clusters (2026-10-10: a manual run's rmc suite
# recreated the containers under another run's topo T6, and both reports were
# garbage). A run that finds the lock held does nothing at all - no build, no
# results.yaml entry, no Telegram message (cron skips the sender on exit 75) - and
# says who holds it. It has nothing to wait for either: whatever it would test,
# the running one is testing. nightly/locked.sh takes the same lock for a suite
# run by hand. A dry run changes nothing and takes no lock.
LOCK="$STATE/nightly.lock"
exec 9>> "$LOCK"
if [ "$DRY" != 1 ] && ! flock -n 9; then
	echo "$(date -u +%FT%TZ) not run: another run holds $LOCK - $(cat "$LOCK.who" 2>/dev/null || echo unknown)" >&2
	exit 75
fi
[ "$DRY" = 1 ] || echo "nightly.sh pid $$ since $(date -u +%FT%TZ) ${ARGS:-(cron)}" > "$LOCK.who"

now()  { date -u +%FT%TZ; }
secs() { date +%s; }
say()  { echo "$(date -u +%T) $*"; }

# ── 1. what changed ─────────────────────────────────────────────────────────────
watch_list() {
	if [ -n "${NIGHTLY_WATCH:-}" ]; then echo "$NIGHTLY_WATCH"; return; fi
	{
		echo yt-cluster
		# --filter-platform: unfiltered, the resolve also wants other platforms' crates
		# (macOS core-foundation) that no Linux build ever fetched, so --offline failed
		# and rppd, sge and diff-doc-rs silently fell off this list
		(cd "$YT_PGXT" && timeout 300 cargo metadata --format-version 1 --offline \
			--filter-platform "$(rustc -vV | sed -n 's/^host: //p')" 2>/dev/null) | python3 -c '
import json, os, subprocess, sys
try: m = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in m["packages"]:
    if p["source"] is None:
        d = os.path.dirname(p["manifest_path"])
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
        print(os.path.basename(r or d))'
		echo etcd ytcluster_dist infra_apt
	} | tr ' ' '\n' | grep -v '^$' | grep -vx "$(basename "$TESTS")" | sort -u | tr '\n' ' '
}

# fp <repo dir> [dir...]: the content of every .rs file under the repository (or
# under the dirs given) - committed or not, tracked or not, ignored ones never.
# Only code counts: a doc, a script, a Cargo.toml version bump changes nothing.
fp() {
	local d="$1"; shift
	[ -e "$d/.git" ] || { echo "absent"; return; }
	local specs=() p
	if [ $# -eq 0 ]; then specs=(':(glob)**/*.rs'); else for p in "$@"; do specs+=(":(glob)$p/**/*.rs"); done; fi
	(cd "$d" && git ls-files -co --exclude-standard -z -- "${specs[@]}" 2>/dev/null \
		| sort -zu | xargs -0 -r sha256sum 2>/dev/null) | sha256sum | cut -c1-16
}
short_rev() { # <repo dir>: the commit, +dirty when the working tree differs from it
	local d="$1" r
	r=$(git -C "$d" rev-parse --short HEAD 2>/dev/null) || { echo "absent"; return; }
	if [ -n "$(git -C "$d" status --porcelain 2>/dev/null | head -1)" ]; then echo "$r+dirty"; else echo "$r"; fi
}
fingerprints() { local r; for r in $WATCH; do echo "$r $(fp "$GIT_ROOT/$r")"; done; }

WATCH="$(watch_list)"
CUR="$(fingerprints)"
LAST="$(cat "$STATE/tested.fp" 2>/dev/null)"
CHANGED="$(join -a1 <(sort <<< "$CUR") <(sort <<< "$LAST") 2>/dev/null | awk 'NF < 3 || $2 != $3 {print $1}' | tr '\n' ' ')"
TRIGGER=changes
# coverage: measured when its file is missing; a failed measurement of these same
# sources is not tried again on its own
COV_TRIED="$(cat "$STATE/coverage.tried.fp" 2>/dev/null)"
cov_whole() { # coverage.yaml is there and measured every suite
	local have s
	have=" $(grep -m1 '^suites:' "$COVERAGE_FILE" 2>/dev/null | cut -d: -f2- | tr -d '[]",') "
	# one measured before fixture A was split in two lists topology for both halves
	case "$have" in *" topology-py "*) ;; *" topology "*) have="$have topology-py " ;; esac
	for s in $ALL_SUITES; do case " $COV_EXEMPT $have" in *" $s "*) ;; *) return 1 ;; esac; done
}
if [ "$COVERAGE" = auto ]; then
	# measured on its own only by a run of every suite, and until one has: a
	# partial measurement (--coverage --suites ...) stands in its file until then
	if cov_whole || [ "$NIGHTLY_SUITES" != "$ALL_SUITES" ]; then COVERAGE=0; else COVERAGE=1; fi
fi
# no code change, no run: not forced, not for coverage alone - exit 75, which cron's
# Telegram sender skips
if [ -z "$CHANGED" ]; then
	say "no .rs change since the last tested run in: $WATCH - nothing run, published or sent"; exit 75
fi

# ── 2. the version ──────────────────────────────────────────────────────────────
cargo_version() { grep -m1 -oP '(?<=^version = ")[^"]+' "$1"; }
bump_patch() { # <Cargo.toml>
	local v n; v="$(cargo_version "$1")"; n="${v%.*}.$(( ${v##*.} + 1 ))"
	sed -i "0,/^version = \"$v\"/s//version = \"$n\"/" "$1"; echo "$n"
}
# the package and the repository codename are both yt-cluster since 2026-10-18
published_deb() { reprepro -b "$REPO_DIR" list yt-cluster 2>/dev/null | awk '$2 == "yt-cluster" {print $NF; exit}'; }
# [deb-version] the file the repository keeps for it: one version stands for every
# build of a release, so the version it lists does not tell which build it holds
pool_deb() { reprepro -b "$REPO_DIR" --list-format '${$fullfilename}\n' list yt-cluster yt-cluster 2>/dev/null | head -1; }
DEB_V="$(cargo_version "$YT_PGXT/ytctl/Cargo.toml")"
PKG_V="${DEB_V%.*}"   # [deb-version] the package's version: major.minor
YTS_V="$(cargo_version "$YT_PGXT/ytserv/Cargo.toml")"
PUB_V="$(published_deb)"
# the build last published (written by the publish below): the repository's
# major.minor cannot say whether this build is a new one
LAST_V="$(cat "$STATE/published.version" 2>/dev/null)"
BUMPED=false
NEED_BUMP=0
if [ "$TRIGGER" != coverage ] && [ -n "$LAST_V" ] && dpkg --compare-versions "$DEB_V" le "$LAST_V"; then NEED_BUMP=1; fi

say "== nightly $(now): $TRIGGER - changed: ${CHANGED:-none} (watching: $WATCH)"
say "   deb $PKG_V, build $DEB_V (published: ${PUB_V:-none}, build ${LAST_V:-none}), ytserv $YTS_V; suites: $NIGHTLY_SUITES${LANE_HOST:+ (lanes: unit here, ${LANE_SUITES} on $LANE_HOST)}${LXC_SSH:+, lxc on $LXC_SSH}; publish: $NIGHTLY_PUBLISH; coverage: $( [ "$COVERAGE" = 1 ] && echo "measured$( [ -f "$COVERAGE_FILE" ] && { cov_whole || echo " (the last one was partial)"; } || echo " ($(basename "$COVERAGE_FILE") missing)")" || echo no)"
if [ "$DRY" = 1 ]; then
	[ "$NEED_BUMP" = 1 ] && say "   would bump the build's patch past $LAST_V, and set ytserv's version to it"
	[ "$NEED_BUMP" = 0 ] && [ "$YTS_V" != "$DEB_V" ] && say "   would set ytserv's version to the build's, $DEB_V"
	say "   dry run: nothing built, run or published"; exit 0
fi

if [ "$NEED_BUMP" = 1 ]; then
	while dpkg --compare-versions "$DEB_V" le "$LAST_V"; do DEB_V="$(bump_patch "$YT_PGXT/ytctl/Cargo.toml")"; done
	PKG_V="${DEB_V%.*}"
	BUMPED=true
	say "   bumped: build $DEB_V (deb $PKG_V)"
fi
# ytserv's version is the build's, bumped above or set by hand in ytctl/Cargo.toml:
# ytserv --version names the package it came in
if [ "$YTS_V" != "$DEB_V" ]; then
	sed -i "0,/^version = \"$YTS_V\"/s//version = \"$DEB_V\"/" "$YT_PGXT/ytserv/Cargo.toml"
	say "   ytserv $YTS_V -> $DEB_V, the build's"
	YTS_V="$(cargo_version "$YT_PGXT/ytserv/Cargo.toml")"
fi
# what this run tests, taken after the bump so the bump is not itself a change
TESTED_FP="$(fingerprints)"
declare -A REV
for r in $WATCH; do REV[$r]="$(short_rev "$GIT_ROOT/$r")"; done

RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
LOGS="$HERE/logs/$RUN_ID"
mkdir -p "$LOGS"
START="$(now)"; T0="$(secs)"
ROWS="$LOGS/suites.tsv"   # name passed failed seconds result log
: > "$ROWS"

# count <log> <exit code>: "<passed> <failed>"
count() {
	local log="$1" rc="$2" p f
	p=$(grep -cE '^[[:space:]]*(OK|PASS)([[:space:]:]|$)' "$log")
	f=$(grep -cE '^[[:space:]]*(FAIL|GAP)([[:space:]:]|$)' "$log")
	if grep -qE '^test result: ' "$log"; then # cargo test
		p=$(grep -oE '^test result: [a-zA-Z]+\. [0-9]+ passed; [0-9]+ failed' "$log" | awk '{s+=$4} END {print s+0}')
		f=$(grep -oE '^test result: [a-zA-Z]+\. [0-9]+ passed; [0-9]+ failed' "$log" | awk '{s+=$6} END {print s+0}')
	fi
	[ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && f=1
	echo "$p $f"
}
# suite <name> <command...>: run it, log it, record it
SKIPPED=""
suite() {
	local name="$1"; shift
	local log="$LOGS/$name.log" t rc p f
	say "-- $name"
	t="$(secs)"
	( "$@" ) 9>&- > "$log" 2>&1; rc=$?   # 9>&-: a daemon a suite leaves behind (its ssh master) must not hold the lock
	if [ "$rc" -eq 77 ]; then
		printf '%s\t0\t0\t%s\tskipped\t%s\n' "$name" "$(( $(secs) - t ))" "$name.log" >> "$ROWS"
		SKIPPED="${SKIPPED:+$SKIPPED }$name"
		say "   $name: skipped - $(grep '^SKIP ' "$log" | tail -1 | sed 's/^SKIP [^:]*: //')"
		return 0
	fi
	read -r p f <<< "$(count "$log" "$rc")"
	local res=pass; [ "$f" -gt 0 ] && res=fail
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$p" "$f" "$(( $(secs) - t ))" "$res" "$name.log" >> "$ROWS"
	say "   $name: $p passed, $f failed, $(( ($(secs) - t) / 60 )) min ($res)"
	[ "$res" = pass ]
}

# ── 3. the build the suites install ─────────────────────────────────────────────
DEB="$LOGS/yt-cluster_${DEB_V}_amd64-pg18.deb"   # named by its build; inside, version $PKG_V
SUITE_DEB="$DEB"   # a coverage run: the instrumented one
COV="$LOGS/coverage"
# Each step checked by hand, as release() below: `if suite build build` is where
# bash ignores `set -e`, and a failed cargo build went on to copy whatever deb of
# this version target/debian still held - the suites would test an older build.
build() {
	cd "$YT_PGXT" || return 1
	FORCE=1 bash ytpgc/build-all-ytpgc.sh || { echo "  FAIL  build: the extension (build-all-ytpgc.sh)"; return 1; }
	cargo build --release -p ytserv -p ytctl || { echo "  FAIL  build: cargo build ytserv ytctl"; return 1; }
	# ytserv-py, the build with rppd (Python functions): the one the test clusters run
	cargo build --release -p ytserv --features ytserv/rppd --bin ytserv-py || { echo "  FAIL  build: cargo build ytserv-py"; return 1; }
	# the third-party crates by license tag, shipped beside LICENSE (the list in the
	# tree stays when this fails)
	python3 -I ytctl/lib-licenses.py || echo "  WARN  lib-licenses.txt not refreshed"
	rm -f "target/debian/yt-cluster_${PKG_V}_amd64.deb"
	(cd ytctl && cargo deb --variant pg18 --no-build --deb-version "$PKG_V") || { echo "  FAIL  build: cargo deb"; return 1; }
	cp "target/debian/yt-cluster_${PKG_V}_amd64.deb" "$DEB" || { echo "  FAIL  build: no yt-cluster_${PKG_V}_amd64.deb"; return 1; }
	if [ -d "$GIT_ROOT/etcd" ]; then
		(cd "$GIT_ROOT/etcd" && cargo build --release --example yxetcd) || { echo "  FAIL  build: etcd's yxetcd"; return 1; }
	fi
	echo "  OK    built $(basename "$DEB")"
}

# ── 4. the suites ───────────────────────────────────────────────────────────────
# the workspace, then ytserv's tests again as ytserv-py: its rppd code builds only
# with the feature
s_unit() {
	cd "$YT_PGXT" || return 1
	local rc=0
	cargo test --workspace --no-fail-fast || rc=1
	cargo test -p ytserv --features ytserv/rppd --bin ytserv-py --no-fail-fast || rc=1
	return $rc
}
# a command on topology's and hier's docker host (YX_HOST: an ssh target, or local)
on_docker_host() {
	if [ "${YX_HOST:-local}" = local ]; then bash -c "$1"; else
		ssh -o BatchMode=yes -o ConnectTimeout=8 "$YX_HOST" "$1"; fi
}
# fixture A in two halves (topology/run_a.sh YX_GROUP), each a fixture of its own:
# topology the regular ytserv's, topology-py the server-function scripts' on
# ytserv-py - under an image name of its own, so the two can build on one host at once
s_topology() {
	cd "$TESTS/topology"
	export YT_CLUSTER_DEB="$SUITE_DEB" YX_NODES="n1 n2 n3 n4 n5 n6 n7" YX_GROUP=regular
	# a failed script's ytserv logs, one file per node (topology/env.sh save_node_logs)
	export YX_FAIL_LOGS="$LOGS/topology-nodes"
	local rc=0
	./run_all.sh || rc=1
	./90_down.sh || true
	on_docker_host "docker rm -f gitsrv chsrv >/dev/null 2>&1; true" || true
	return $rc
}
s_topology_py() {
	cd "$TESTS/topology"
	export YT_CLUSTER_DEB="$SUITE_DEB" YX_NODES="n1 n2 n3 n4 n5 n6 n7" YX_GROUP=py \
		YX_IMAGE="${YX_PY_IMAGE:-yxtopo-py-node}" YX_FAIL_LOGS="$LOGS/topology-py-nodes"
	local rc=0
	./run_all.sh || rc=1
	./90_down.sh || true
	on_docker_host "docker rm -f gitsrv chsrv otelcol >/dev/null 2>&1; true" || true
	return $rc
}
s_hier() {
	cd "$TESTS/hier"
	export YT_CLUSTER_DEB="$SUITE_DEB"
	# a failed script's ytserv logs, one file per node (hier/run_all.sh, as topology's)
	export YX_FAIL_LOGS="$LOGS/hier-nodes"
	local rc=0
	./00_build.sh && ./run_all.sh || rc=1
	[ -x ./90_down.sh ] && ./90_down.sh || true
	return $rc
}
s_lxc() {
	[ -n "$LXC_SSH" ] || { cd "$TESTS/lxc" && ./run_all.sh; return; }
	# [lanes] on LXC_SSH: the scripts, and the files 10_push.sh takes from a build
	# tree - yt-pgxt's layout, the binaries YX_BIN_DIR names - under RMC_DIR there;
	# a coverage run's counts (YX_COV_OUT) come back after
	local at="$RMC_DIR/lxc-run" bin="target/release" rc=0 f files=()
	[ -n "${YX_BIN_DIR:-}" ] && bin="${YX_BIN_DIR#"$YT_PGXT"/}"
	# globbed inside the build tree (relative to here they matched nothing - the
	# extension's SQL went missing), listed relative to it
	for f in "$YT_PGXT/$bin/ytctl" "$YT_PGXT/$bin/ytserv" "$YT_PGXT"/target/glibc*/ytserv-glibc* \
		"$YT_PGXT"/target/glibc*/ytctl-glibc* "$YT_PGXT/target/musl/ytserv-musl" \
		"$YT_PGXT/$bin/ytserv-py" "$YT_PGXT"/target/glibc*/ytserv-py-glibc* "$YT_PGXT/target/musl/ytserv-py-musl" \
		"$YT_PGXT/ytpgc/dist" \
		"$YT_PGXT/ytpgc/yt_cluster.control" "$YT_PGXT"/ytpgc/yt_cluster--*.sql; do
		[ -e "$f" ] && files+=("${f#"$YT_PGXT"/}")
	done
	ssh -o BatchMode=yes "$LXC_SSH" "rm -rf $at && mkdir -p $at/tests $at/pgxt" \
		&& rsync -a "$TESTS/lxc" "$LXC_SSH:$at/tests/" \
		&& (cd "$YT_PGXT" && rsync -aR "${files[@]}" "$LXC_SSH:$at/pgxt/") || return 1
	ssh -o BatchMode=yes -o ServerAliveInterval=30 "$LXC_SSH" "cd $at/tests/lxc && unset DOCKER_HOST \
		&& export YT_PGXT=\$HOME/$at/pgxt YX_BIN_DIR=\$HOME/$at/pgxt/$bin YX_NIC=${YX_NIC:-bridge} \
		YX_COV_OUT=${YX_COV_OUT:+\$HOME/$at/cov} && ./run_all.sh" || rc=1
	if [ -n "${YX_COV_OUT:-}" ]; then
		mkdir -p "$YX_COV_OUT" && rsync -a "$LXC_SSH:$at/cov/" "$YX_COV_OUT/" || true
	fi
	return $rc
}
# The migration (migrate/): a running database into a four-node cluster, node by
# node from dumps, under load - LXD containers like lxc's, on LXC_SSH (empty: here),
# the scripts and the package copied there. About 30 minutes.
s_migrate() {
	if [ -z "$LXC_SSH" ]; then
		cd "$TESTS/migrate" && MIG_DEB="$SUITE_DEB" MIG_NIC="${YX_NIC:-bridge}" ./run_all.sh; return
	fi
	local at="$RMC_DIR/migrate-run"
	ssh -o BatchMode=yes "$LXC_SSH" "rm -rf $at && mkdir -p $at" \
		&& rsync -a --exclude run "$TESTS/migrate" "$LXC_SSH:$at/" \
		&& rsync -a "$SUITE_DEB" "$LXC_SSH:$at/" || return 1
	ssh -o BatchMode=yes -o ServerAliveInterval=30 "$LXC_SSH" "cd $at/migrate && unset DOCKER_HOST \
		&& MIG_DEB=\$HOME/$at/$(basename "$SUITE_DEB") MIG_NIC=${YX_NIC:-bridge} ./run_all.sh"
}
# the llm stack runs where LLM_SSH says (default: the rmc host), over ssh like rmc:
# the suite synced next to the package, its own .env there kept (the model host's
# address and the mTLS client certs of that host); empty: here.
# The model service is asked first (llm/probe.sh): not answering, the suite is
# skipped (77) before anything is built. Asked again after a failed run: if it
# stopped answering meanwhile, the failures say nothing about the cluster - skipped too.
LLM_SSH="${LLM_SSH-$RMC_SSH}"
s_llm() {
	local rc=0
	if [ -z "$LLM_SSH" ]; then
		cd "$TESTS/llm"
		export YT_CLUSTER_DEB="$SUITE_DEB"
		./probe.sh || return $?
		./build.sh && ./up.sh && ./test.sh || rc=1
		./down.sh || true
		[ "$rc" -eq 0 ] || PROBE_WAIT=60 ./probe.sh || return $?
		return $rc
	fi
	local at="cd $RMC_DIR/llm && unset DOCKER_HOST"
	ssh -o BatchMode=yes "$LLM_SSH" "mkdir -p $RMC_DIR/llm" \
	&& rsync -a --exclude .env --exclude run --exclude results --exclude build "$TESTS/llm/" "$LLM_SSH:$RMC_DIR/llm/" \
	|| return 1
	ssh -o BatchMode=yes "$LLM_SSH" "$at && ./probe.sh" || return $?
	rsync -a "$SUITE_DEB" "$LLM_SSH:$RMC_DIR/" \
	&& ssh -o BatchMode=yes -o ServerAliveInterval=30 "$LLM_SSH" "$at \
		&& export YT_CLUSTER_DEB=\$HOME/$RMC_DIR/$(basename "$SUITE_DEB") YX_COV_MOUNT='${YX_COV_MOUNT:-}' && rc=0; ./build.sh && ./up.sh && ./test.sh || rc=1; ./down.sh >/dev/null 2>&1; exit \$rc" \
	|| rc=1
	[ "$rc" -eq 0 ] || ssh -o BatchMode=yes "$LLM_SSH" "$at && PROBE_WAIT=60 ./probe.sh" || return $?
	return $rc
}
# the rmc host: a copy of rmc/ and topo/ next to the package, its own rmc/.env kept
rmc_sync() {
	[ -n "$RMC_SSH" ] || return 0
	ssh -o BatchMode=yes "$RMC_SSH" "mkdir -p $RMC_DIR" \
	&& rsync -a --exclude results --exclude run --exclude .env "$TESTS/rmc/" "$RMC_SSH:$RMC_DIR/rmc/" \
	&& rsync -a --exclude results "$TESTS/topo/" "$RMC_SSH:$RMC_DIR/topo/" \
	&& rsync -a "$SUITE_DEB" "$RMC_SSH:$RMC_DIR/"
}
rmc_deb() { if [ -n "$RMC_SSH" ]; then echo "\$HOME/$RMC_DIR/$(basename "$SUITE_DEB")"; else echo "$SUITE_DEB"; fi; }
on_rmc() { # <command line, run in the rmc/ folder>
	local env="unset DOCKER_HOST; export YT_CLUSTER_DEB=$(rmc_deb) YX_COV_MOUNT='${YX_COV_MOUNT:-}' RMC_ORIGIN=\${RMC_ORIGIN:-all} RMC_JOIN=\${RMC_JOIN:-clone} RMC_LOG_LEVEL=\${RMC_LOG_LEVEL:-info}"
	if [ -n "$RMC_SSH" ]; then
		ssh -o BatchMode=yes -o ServerAliveInterval=30 "$RMC_SSH" "cd $RMC_DIR/rmc && $env && $1"
	else
		(cd "$TESTS/rmc" && eval "$env" && eval "$1")
	fi
}
RMC_BUILT=0
# [lanes] RMC_FROM: the topo lane's - the image is built on that host, for both lanes
# before they start (RMC_READY), and carried onto RMC_SSH
RMC_FROM=""; RMC_READY=1
rmc_prepare() {
	[ "$RMC_BUILT" = 1 ] && return 0
	rmc_sync || return 1
	if [ -n "$RMC_FROM" ]; then
		[ "$RMC_READY" = 0 ] || { echo "  FAIL  rmc-node was not built on $RMC_FROM (rmc-build.log)"; return 1; }
		ship_host_image rmc-node "$RMC_FROM" "$RMC_SSH"
	else on_rmc "./build.sh"; fi && RMC_BUILT=1
}
# ship_host_image <image> <from> <to>: an image of ssh host <from> onto <to>, same
# name and id, through this host - as topology/env.sh ship_image
ship_host_image() {
	local id at="unset DOCKER_HOST; docker image inspect -f '{{.Id}}' $1 2>/dev/null"
	id="$(ssh -o BatchMode=yes "$2" "$at")"
	[ -n "$id" ] || { echo "  FAIL  no $1 on $2"; return 1; }
	[ "$(ssh -o BatchMode=yes "$3" "$at")" = "$id" ] && return 0
	ssh -o BatchMode=yes "$2" "unset DOCKER_HOST; docker save $1" \
		| ssh -o BatchMode=yes "$3" "unset DOCKER_HOST; docker load -q" >/dev/null
	[ "$(ssh -o BatchMode=yes "$3" "$at")" = "$id" ] || { echo "  FAIL  $1 not carried from $2 to $3"; return 1; }
	echo "  OK    $1 carried from $2 to $3"
}
# a fresh layout: up.sh's own checks counted in the suite's log, and on a stop its
# last lines and a FAIL (rmc/up_logged.sh). A step of up.sh that fails reports and
# goes on - only a layout that cannot come up at all stops the suite
RMC_UP="./up_logged.sh /tmp/nightly-rmc-up.log"
s_topo()            { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && rc=0 && for t in t0_jobs t1_az t2_move t3_group t6_negative t4_split; do [ -x ./\$t.sh ] || continue; echo \"== \$t\"; ./\$t.sh || rc=1; done; exit \$rc" || rmc_logs topo; }
s_topo_faults()     { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && ./t5_faults.sh" || rmc_logs topo-faults; }
s_topo_membership() { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && ./t7_membership.sh" || rmc_logs topo-membership; }
s_rmc()             { rmc_prepare && on_rmc "$RMC_UP && ./test.sh" || rmc_logs rmc; }
# [jepsen] four of jepsen/'s cases on YX_HOST (jepsen/nightly_cases.sh): this run holds
# the lock (JEPSEN_LOCKED); each run's output, and a failed run's store, in the run's
# logs (jepsen/)
s_jepsen() {
	cd "$TESTS/jepsen" && JEPSEN_LOCKED=1 JEPSEN_OUT="$LOGS/jepsen" ./nightly_cases.sh --deb "$SUITE_DEB"
}
# a failed suite's node logs, one file per container, before the next suite's
# layout replaces the containers; returns 1, the suite stays failed
rmc_logs() { # <suite>
	local d="$LOGS/$1-nodes" c
	mkdir -p "$d" 2>/dev/null || return 1
	for c in $(on_rmc "docker ps -a --format '{{.Names}}' | grep '^rmc-'" 2>/dev/null); do
		on_rmc "docker logs $c 2>&1 | tail -c 20000000" > "$d/$c.log" 2>/dev/null || true
	done
	return 1
}
rmc_down() { on_rmc "./down.sh >/dev/null 2>&1; true" || true; }

# ── coverage (a run that measures it) ───────────────────────────────────────────
# A suite's instrumented processes write their counts into a docker volume of its
# own, yt-cluster-cov-<suite>, on the host its containers run on - the suites add
# YX_COV_MOUNT to their `docker run`. lxc pulls the directory out of its container
# before deleting it (YX_COV_OUT) and pushes the instrumented binaries (YX_BIN_DIR).
cov_vol() { echo "yt-cluster-cov-$1"; }
cov_on() { # <suite> <command line>: run it where that suite's containers run
	local to
	case "$1" in
		topology|topology-py|hier) in_lane "$1" || { on_docker_host "$2"; return; }; to="$LANE_HOST" ;;
		llm) to="$LLM_SSH" ;;
		topo|topo-faults|topo-membership|rmc) to="$RMC_SSH"; in_lane "$1" && to="$LANE_HOST" ;;
		*) return 0 ;;
	esac
	if [ -n "$to" ]; then ssh -o BatchMode=yes -o ConnectTimeout=8 "$to" "unset DOCKER_HOST; $2"
	else (unset DOCKER_HOST; bash -c "$2"); fi
}
cov_image() { # an image with tar, there: the suite's own node image
	case "$1" in
		topology) echo "${YX_IMAGE:-yxtopo-node}" ;;
		topology-py) echo "${YX_PY_IMAGE:-yxtopo-py-node}" ;;
		hier) echo "${YX_HIER_IMAGE:-yxhier-node}" ;;
		llm) echo ytllm-node ;;
		*) echo rmc-node ;;
	esac
}
cov_suite() { # <suite>: where it writes its counts - a fresh volume, or lxc's folder
	unset YX_COV_MOUNT YX_COV_OUT YX_BIN_DIR
	[ "$COVERAGE" = 1 ] || return 0
	case "$1" in
		unit|none|migrate) ;;
		lxc) mkdir -p "$COV/e2e/lxc"
			export YX_COV_OUT="$COV/e2e/lxc" YX_BIN_DIR="$YT_PGXT/target/coverage/release" ;;
		*) export YX_COV_MOUNT="-v $(cov_vol "$1"):/var/lib/yt-cluster-cov"
			cov_on "$1" "docker volume rm -f $(cov_vol "$1") >/dev/null 2>&1; true" ;;
	esac
}
cov_build() { bash "$HERE/coverage.sh" build "$DEB" "$LOGS/yt-cluster_${DEB_V}_amd64-pg18-coverage.deb"; }
s_unit_cov() { bash "$HERE/coverage.sh" unit; }
cov_report() {
	local s
	for s in $NIGHTLY_SUITES; do
		case "$s" in unit|lxc|migrate) continue ;; esac
		mkdir -p "$COV/e2e/$s"
		cov_on "$s" "docker run --rm -u 0 -v $(cov_vol "$s"):/c --entrypoint tar $(cov_image "$s") -C /c -cf - . 2>/dev/null; docker volume rm -f $(cov_vol "$s") >/dev/null 2>&1; true" \
			| tar -x -C "$COV/e2e/$s" 2>/dev/null
		echo "  $s: $(find "$COV/e2e/$s" -name '*.profraw' | wc -l) profile files"
	done
	RUN_ID="$RUN_ID" MEASURED="$(now)" DEB_V="$DEB_V" YTS_V="$YTS_V" SOURCE="${REV[yt-cluster]:-}" RESULT="$RESULT" SUITES="$NIGHTLY_SUITES" \
		bash "$HERE/coverage.sh" report "$COV" "$COV/coverage.yaml" && [ -s "$COV/coverage.yaml" ]
}

run_suite() { # <suite>: where it writes its counts, then the suite
	cov_suite "$1"
	case "$1" in
		unit) if [ "$COVERAGE" = 1 ]; then suite unit s_unit_cov; else suite unit s_unit; fi ;;
		topology) suite topology s_topology ;;
		topology-py) suite topology-py s_topology_py ;;
		hier) suite hier s_hier ;;
		lxc) suite lxc s_lxc ;;
		migrate) suite migrate s_migrate ;;
		llm) suite llm s_llm ;;
		topo) suite topo s_topo ;;
		topo-faults) suite topo-faults s_topo_faults ;;
		topo-membership) suite topo-membership s_topo_membership ;;
		rmc) suite rmc s_rmc ;;
		jepsen) suite jepsen s_jepsen ;;
		*) printf '%s\t0\t1\t0\tfail\t-\n' "$1" >> "$ROWS"; say "   unknown suite $1"; return 1 ;;
	esac
}
# [lanes] LANE_HOST's lane, in a shell of its own: its suites in turn there, the
# images built where the rest's are - topology's on YX_HOST (YX_BUILD_HOST), rmc-node
# on RMC_SSH (RMC_FROM). Its rows go to the same suites.tsv.
host_lane() {
	export YX_BUILD_HOST="$YX_HOST" YX_HOST="$LANE_HOST"
	RMC_FROM="$RMC_SSH"; RMC_SSH="$LANE_HOST"; RMC_BUILT=0
	local s rc=0
	for s in $LANE_B; do run_suite "$s" || rc=1; done
	cov_suite none
	case " $LANE_B " in *" topo "*|*" topo-faults "*|*" topo-membership "*|*" rmc "*) rmc_down ;; esac
	return $rc
}

RESULT=pass; BUILD=pass; PUBLISHED_DEB=""; PUBLISHED_RPM=""; PUBLISHED_TGZ=""; PUBLISHED_IMAGE=""; PUBLISHED_SGE=""; NOTE=""; COVERAGE_PCT=""; COV_NOTE=""
if suite build build; then
	if [ "$COVERAGE" = 1 ]; then
		if suite coverage-build cov_build; then SUITE_DEB="$LOGS/yt-cluster_${DEB_V}_amd64-pg18-coverage.deb"
		else COVERAGE=0; COV_NOTE="coverage not measured: its build failed"; echo "$TESTED_FP" > "$STATE/coverage.tried.fp"; fi
	fi
	# [lanes] unit here (LANE_U), LANE_SUITES on LANE_HOST (LANE_B), the rest in turn
	LANE_B=""; LANE_U=""; LANE_REST=""
	for s in $NIGHTLY_SUITES; do
		if in_lane "$s"; then LANE_B="${LANE_B:+$LANE_B }$s"
		elif [ -n "$LANE_HOST" ] && [ "$s" = unit ]; then LANE_U=unit
		else LANE_REST="${LANE_REST:+$LANE_REST }$s"; fi
	done
	B_PID=""; U_PID=""
	if [ -n "$LANE_B$LANE_U" ]; then
		# rmc-node for both docker lanes, before either starts: the rest's rmc finds it built
		case " $LANE_B " in *" topo "*|*" topo-faults "*|*" topo-membership "*|*" rmc "*)
			rmc_prepare > "$LOGS/rmc-build.log" 2>&1; RMC_READY=$?
			[ "$RMC_READY" = 0 ] || say "   rmc-node not built on $RMC_SSH - $LOGS/rmc-build.log" ;;
		esac
		say "   lanes: ${LANE_U:+unit here; }${LANE_B:+$LANE_B on $LANE_HOST; }the rest in turn: ${LANE_REST:-nothing}"
		[ -n "$LANE_B" ] && { host_lane & B_PID=$!; }
		[ -n "$LANE_U" ] && { run_suite unit & U_PID=$!; }
	fi
	for s in $LANE_REST; do run_suite "$s" || RESULT=fail; done
	cov_suite none
	case " $LANE_REST " in *" topo"*|*" rmc "*) rmc_down ;; esac
	for p in $B_PID $U_PID; do wait "$p" || RESULT=fail; done
	# the lanes' skips are in their rows, not in this shell
	[ -n "$B_PID$U_PID" ] && SKIPPED="$(awk -F'\t' '$5 == "skipped" {printf "%s%s", (n++ ? " " : ""), $1}' "$ROWS")"
	if [ "$COVERAGE" = 1 ]; then
		if suite coverage cov_report; then
			COVERAGE_PCT="$(grep -oP '^coverage=\K.*' "$LOGS/coverage.log" | tail -1)"
			cp "$COV/coverage.yaml" "$COVERAGE_FILE"; rm -f "$STATE/coverage.tried.fp"
			# both: the workspace's here, ytserv's on the badge (badge.py) - one alone read
			# as a drop, 81 -> 74, when both had gone up
			YTS_PCT="$(grep -oP 'name: "ytserv", lines: [0-9]+, percent: \K[0-9.]+' "$COVERAGE_FILE" | head -1)"
			COV_NOTE="coverage ${COVERAGE_PCT}% of yt-cluster's lines${YTS_PCT:+, ytserv ${YTS_PCT}% (on the badge)} (nightly/$(basename "$COVERAGE_FILE"))"
		else
			COV_NOTE="coverage not measured: no report"; echo "$TESTED_FP" > "$STATE/coverage.tried.fp"
		fi
	fi
else
	BUILD=fail; RESULT=fail; NOTE="the build failed - no suite ran"
fi
# tested, whatever the outcome: the same sources are not run again tomorrow
echo "$TESTED_FP" > "$STATE/tested.fp"

# ── 5. publish ──────────────────────────────────────────────────────────────────
# Every step checked by hand, never by `set -e`: these run as the condition of an
# `if` (suite release release && suite publish publish), where bash ignores it - so
# a failed release build went on to "OK" with no file, publish "published" nothing,
# and the runs of 2026-10-12 and 13 recorded 0.18.81 and 1.18.86 as published and
# renewed the badge while apt still served 0.12.1.
release() {
	cd "$YT_PGXT" || return 1
	BASE_IMAGE=almalinux:9 GLIBC_TAG=2_34 ./build_glibc.sh \
		|| { echo "  FAIL  release: build_glibc.sh (EL9, glibc 2.34) exited $?"; return 1; }
	local out; out="$(mktemp)"
	EL9=1 FORCE=1 BUILD_HOST="${DOCKER_HOST:-}" GITHUB_OUTPUT="$out" "$DIST/build.sh" "$GIT_ROOT" \
		|| { echo "  FAIL  release: ytcluster_dist build.sh exited $?"; rm -f "$out"; return 1; }
	SKIP_EXT=1 SKIP_GLIBC=1 GITHUB_OUTPUT="$out" "$DIST/build_rpm.sh" "$GIT_ROOT" \
		|| { echo "  FAIL  release: ytcluster_dist build_rpm.sh exited $?"; rm -f "$out"; return 1; }
	REL_DEB="$(grep -oP '(?<=^deb=).*' "$out" | tail -1)"
	REL_RPM="$(grep -oP '(?<=^rpm=).*' "$out" | tail -1)"
	rm -f "$out"
	{ [ -f "$REL_DEB" ] && [ -f "$REL_RPM" ]; } \
		|| { echo "  FAIL  release: the build named no deb or rpm that exists (deb=${REL_DEB:-none} rpm=${REL_RPM:-none})"; return 1; }
	echo "deb=$REL_DEB" > "$LOGS/release.out"; echo "rpm=$REL_RPM" >> "$LOGS/release.out"
	echo "  OK    release build: $(basename "$REL_DEB"), $(basename "$REL_RPM")"
}
publish() {
	local deb rpm
	deb="$(grep -oP '(?<=^deb=).*' "$LOGS/release.out" 2>/dev/null)"; rpm="$(grep -oP '(?<=^rpm=).*' "$LOGS/release.out" 2>/dev/null)"
	{ [ -f "$deb" ] && [ -f "$rpm" ]; } \
		|| { echo "  FAIL  publish: no release build to publish (deb=${deb:-none} rpm=${rpm:-none})"; return 1; }
	DEB="$deb" REPO_DIR="$REPO_DIR" CONF_DIR="$DIST/repo-conf" CODENAME=yt-cluster PACKAGE=yt-cluster GPG_KEY="$GPG_KEY" \
		INSTALL_HTML="$DIST/install.html" "$INFRA_APT/scripts/publish-apt.sh" \
		|| { echo "  FAIL  deb not published: publish-apt.sh exited $?"; return 1; }
	# what apt now serves: the version this run built, or it was not published -
	# and, the version being the release's, this run's build of it
	local now; now="$(published_deb)"
	[ "$now" = "$PKG_V" ] || { echo "  FAIL  deb not published: the repository lists ${now:-nothing}, not $PKG_V"; return 1; }
	cmp -s "$deb" "$(pool_deb)" || { echo "  FAIL  deb not published: the repository's $PKG_V ($(pool_deb)) is not this run's build $DEB_V"; return 1; }
	# only the latest: the signatures of the versions before it go
	find "$REPO_DIR" -maxdepth 1 -name 'yt-cluster_*_amd64.deb.sig' ! -name "$(basename "$deb").sig" -delete
	echo "  OK    deb published: $(basename "$deb"), build $DEB_V"
	# [deb-version] the edge holds both a day (the apt host's nginx, $pool_cache) and
	# this build replaced them at the same path: its copies of the earlier one go
	purge_edge "$PUBLIC_APT/$(reprepro -b "$REPO_DIR" --list-format '${$filekey}\n' list yt-cluster yt-cluster | head -1)" \
		"$PUBLIC_APT/$(basename "$deb").sig"
	# its createrepo fallback bind-mounts the local repository: this host's daemon;
	# KEEP=1: only the latest rpm stays in yum/el9
	DOCKER_HOST=unix:///var/run/docker.sock KEEP=1 RPM="$rpm" REPO_DIR="$REPO_DIR" GPG_KEY="$GPG_KEY" "$DIST/publish_rpm.sh" \
		|| { echo "  FAIL  rpm not published: publish_rpm.sh exited $?"; return 1; }
	echo "  OK    rpm published: $(basename "$rpm")"
	# what anyone can install now, as the internet sees it
	public_available "$PKG_V" "$(sha256sum < "$deb" | cut -d' ' -f1)" "$(basename "$rpm")" || return 1
	# apt serves this build from here on, whatever fails after: the next run bumps
	echo "$DEB_V" > "$STATE/published.version"
	publish_tgz || return 1
	publish_image || return 1
	publish_sge
}
# What the publish step put out besides the deb and the rpm, a line each, for the
# record (publish runs in a shell of its own): tgz=<build>, image=<ref>, sge=<version>
PUBLISHED_OUT="$LOGS/published.out"
# [tgz] The static (musl) ytctl and ytserv and every major's extension, for a host
# with no deb or rpm (ytcluster_dist/build_tgz.sh, from the release build), into
# REPO_DIR/paks by its convention (infra_apt publish-pak.sh):
# yt-cluster-<build>-<sha8>.tar.gz with its .sha256 and .sig, the
# yt-cluster-latest.tar.gz link to it, and the manifest yt-cluster.json.
publish_tgz() {
	local out tgz sum got art i
	out="$(mktemp)"
	GITHUB_OUTPUT="$out" "$DIST/build_tgz.sh" "$GIT_ROOT" \
		|| { echo "  FAIL  tgz: build_tgz.sh exited $?"; rm -f "$out"; return 1; }
	tgz="$(grep -oP '(?<=^tgz=).*' "$out" | tail -1)"; rm -f "$out"
	[ -f "$tgz" ] || { echo "  FAIL  tgz: build_tgz.sh named no tarball"; return 1; }
	TGZ="$tgz" NAME=yt-cluster VERSION="$DEB_V" REPO_DIR="$REPO_DIR" GPG_KEY="$GPG_KEY" "$INFRA_APT/scripts/publish-pak.sh" \
		|| { echo "  FAIL  tgz not published: publish-pak.sh exited $?"; return 1; }
	sum="$(sha256sum < "$tgz" | cut -d' ' -f1)"; art="yt-cluster-$DEB_V-${sum:0:8}.tar.gz"
	# the link and the manifest revalidate within minutes; the edge's copies go now
	purge_edge "$PUBLIC_APT/paks/yt-cluster-latest.tar.gz" "$PUBLIC_APT/paks/yt-cluster-latest.tar.gz.sha256" \
		"$PUBLIC_APT/paks/yt-cluster-latest.tar.gz.sig" "$PUBLIC_APT/paks/yt-cluster.json"
	for i in $(seq 1 6); do
		got="$(public_get -m 120 "$PUBLIC_APT/paks/$art" 2>/dev/null | sha256sum | cut -d' ' -f1)"
		[ "$got" = "$sum" ] && break
		sleep 10
	done
	[ "$got" = "$sum" ] || { echo "  FAIL  tgz not available: $PUBLIC_APT/paks/$art (sha256 ${got:0:12})"; return 1; }
	echo "  OK    tgz available: $PUBLIC_APT/paks/$art, and as paks/yt-cluster-latest.tar.gz"
	echo "tgz=$DEB_V" >> "$PUBLISHED_OUT"
}
# [image] dbinvent/yt of this build (ytcluster_dist/docker/publish.sh): built on
# DOCKER_HOST from the package as apt.dbinvent.com serves it - checked above -,
# started and checked there (docker/smoke.sh), pushed as the build, its major.minor
# and latest. The Docker Hub token: DOCKER_TOKEN in infra_apt/.env, read by infra_apt
# publish-docker.sh and kept out of this shell.
publish_image() {
	PUSH=1 REPO_DIR="$REPO_DIR" INFRA_APT="$INFRA_APT" "$DIST/docker/publish.sh" "$DEB_V" \
		|| { echo "  FAIL  image not published: docker/publish.sh exited $?"; return 1; }
	echo "image=dbinvent/yt:$DEB_V" >> "$PUBLISHED_OUT"
}
# [sge] Schema Guard, when its version (sge/Cargo.toml) is one the repository does
# not list: its deb into the same distribution, its tarball and the image
# dbinvent/sge (sge/dist/publish.sh). A version it lists stays as it is.
publish_sge() {
	local sge="$GIT_ROOT/sge" v listed
	[ -x "$sge/dist/publish.sh" ] || { echo "  sge: no $sge/dist/publish.sh - not published"; return 0; }
	v="$(cargo_version "$sge/Cargo.toml")"
	listed="$(reprepro -b "$REPO_DIR" list yt-cluster schema-guard 2>/dev/null | awk '{print $NF; exit}')"
	if [ "${listed%-*}" = "$v" ]; then echo "  sge $v: the repository lists it already ($listed)"; return 0; fi
	PUSH=1 REPO_DIR="$REPO_DIR" GPG_KEY="$GPG_KEY" INFRA_APT="$INFRA_APT" "$sge/dist/publish.sh" \
		|| { echo "  FAIL  sge $v not published: sge/dist/publish.sh exited $?"; return 1; }
	purge_edge "$PUBLIC_APT/paks/sge-latest.tar.gz" "$PUBLIC_APT/paks/sge-latest.tar.gz.sha256" \
		"$PUBLIC_APT/paks/sge-latest.tar.gz.sig" "$PUBLIC_APT/paks/sge.json"
	echo "  OK    sge $v published: the deb, paks/sge-latest.tar.gz, dbinvent/sge:$v"
	echo "sge=$v" >> "$PUBLISHED_OUT"
}
# [publish] The apt index and the rpm as the internet sees them: through public
# DNS, not this host's /etc/hosts, which may name the apt host's LAN address. Up to
# a minute, for the edge to revalidate (the index is served max-age=0).
PUBLIC_APT="${PUBLIC_APT:-https://apt.dbinvent.com}"
public_get() { curl -fsS -m 20 --doh-url https://1.1.1.1/dns-query "$@"; }
# [deb-version] Cloudflare's copies of these URLs dropped (purge by URL), with
# CF_ZONE_ID and CF_PURGE_TOKEN (an API token: Zone - Cache Purge - Purge, on
# dbinvent.com) from .env. Best effort: what decides is public_available below,
# which reads the bytes the edge serves. The token goes to curl on stdin, never
# on a command line.
purge_edge() { # <url>...
	if [ -z "$CF_ZONE_ID" ] || [ -z "$CF_PURGE_TOKEN" ]; then
		echo "  WARN  edge not purged: no CF_ZONE_ID or CF_PURGE_TOKEN in .env"; return 0
	fi
	local r
	r="$(printf 'header = "Authorization: Bearer %s"\n' "$CF_PURGE_TOKEN" \
		| curl -sS -m 20 -K - -X POST -H 'Content-Type: application/json' \
			--data "{\"files\": [$(printf '"%s",' "$@" | sed 's/,$//')]}" \
			"https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" 2>&1)"
	if grep -q '"success": *true' <<< "$r"; then echo "  OK    edge purged: $*"
	else echo "  WARN  edge not purged: $(tr -d '\n' <<< "$r" | cut -c1-300)"; fi
}
# [deb-version] By checksum, not version: the release's version stands for each of
# its builds. And the file itself, as the edge hands it out - the pool path is the
# release's too, and an earlier build held at the edge against this index is apt's
# "Hash Sum mismatch" (the apt host's nginx: raw/nginx-apt.conf, $pool_cache).
public_available() { # <deb version> <its sha256> <rpm file name>
	local v="" s="" f="" i
	for i in $(seq 1 12); do
		read -r v s f <<< "$(public_get "$PUBLIC_APT/dists/yt-cluster/restricted/binary-amd64/Packages" 2>/dev/null \
			| awk '/^Package: yt-cluster$/ {p = 1} p && /^Version:/ {v = $2} p && /^SHA256:/ {s = $2} p && /^Filename:/ {f = $2} p && /^$/ {exit} END {print v, s, f}')"
		[ "$v" = "$1" ] && [ "$s" = "$2" ] && break
		sleep 5
	done
	{ [ "$v" = "$1" ] && [ "$s" = "$2" ]; } \
		|| { echo "  FAIL  deb not available: $PUBLIC_APT serves ${v:-nothing}${s:+ (sha256 ${s:0:12})}, not $1 (sha256 ${2:0:12})"; return 1; }
	echo "  OK    deb available: $PUBLIC_APT serves yt-cluster $1 (sha256 ${2:0:12})"
	for i in $(seq 1 6); do
		s="$(public_get -m 120 "$PUBLIC_APT/$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"
		[ "$s" = "$2" ] && break
		sleep 10
	done
	[ "$s" = "$2" ] || { echo "  FAIL  deb not available: $PUBLIC_APT/$f is another build (sha256 ${s:0:12}) - held at the edge?"; return 1; }
	echo "  OK    deb file: $PUBLIC_APT/$f is this build"
	public_get -o /dev/null -I "$PUBLIC_APT/yum/el9/packages/$3" 2>/dev/null \
		|| { echo "  FAIL  rpm not available: $PUBLIC_APT/yum/el9/packages/$3"; return 1; }
	echo "  OK    rpm available: $PUBLIC_APT/yum/el9/packages/$3"
}
if [ "$RESULT" = pass ] && [ "$NIGHTLY_PUBLISH" = 1 ]; then
	if suite release release && suite publish publish; then
		PUBLISHED_DEB="$PKG_V"; PUBLISHED_RPM="$DEB_V"   # the deb as apt lists it; its build: version.deb
		echo "$DEB_V" > "$STATE/published.version"
		PUBLISHED_TGZ="$(grep -oP '(?<=^tgz=).*' "$PUBLISHED_OUT" 2>/dev/null | tail -1)"
		PUBLISHED_IMAGE="$(grep -oP '(?<=^image=).*' "$PUBLISHED_OUT" 2>/dev/null | tail -1)"
		PUBLISHED_SGE="$(grep -oP '(?<=^sge=).*' "$PUBLISHED_OUT" 2>/dev/null | tail -1)"
	else
		RESULT=fail; NOTE="tested green, but the release build or the publish failed"
	fi
elif [ "$TRIGGER" = coverage ] && [ "$RESULT" = pass ]; then
	NOTE="tested green; a coverage run of published sources publishes nothing"
elif [ "$RESULT" = pass ]; then
	NOTE="tested green; publishing is off (NIGHTLY_PUBLISH=0)"
elif [ -z "$NOTE" ]; then
	NOTE="not published: a suite failed"
fi
[ -n "$COV_NOTE" ] && NOTE="${NOTE:+$NOTE; }$COV_NOTE"
# no host names here: results.yaml is committed (the reason is in the suite's log)
[ -n "$SKIPPED" ] && NOTE="${NOTE:+$NOTE; }skipped: $SKIPPED (its outside service did not answer)"

# ── 6. the record ───────────────────────────────────────────────────────────────
END="$(now)"
# [flags-ab] topology 29b_flags_ab's one-line measurement of the flags that are off by
# default (peer_stream, one_pc): informational, it never fails the run
AB_LINE="$(grep -h '^  AB: ' "$LOGS/topology.log" 2>/dev/null | tail -1 | sed 's/^  AB: //' || true)"
export START END TRIGGER CHANGED DEB_V YTS_V BUMPED RESULT BUILD NOTE PUBLISHED_DEB PUBLISHED_RPM PUBLISHED_TGZ PUBLISHED_IMAGE PUBLISHED_SGE RUN_ID ROWS RESULTS COVERAGE_PCT AB_LINE
export DURATION=$(( $(secs) - T0 ))
export REVS="$(for r in $WATCH; do echo "$r=${REV[$r]}"; done)"
python3 - <<'EOF'
import json, os
q = json.dumps  # a JSON string is a YAML double-quoted scalar
e = os.environ
rows = []
for line in open(e["ROWS"]):
    n, p, f, s, r, log = line.rstrip("\n").split("\t")
    rows.append((n, int(p), int(f), int(s), r))
STEPS = ("build", "coverage-build", "coverage", "release", "publish")
suites = [r for r in rows if r[0] not in STEPS]
steps = [r for r in rows if r[0] in STEPS]
out = []
if not os.path.exists(e["RESULTS"]) or os.path.getsize(e["RESULTS"]) == 0:
    out.append("# YT Cluster nightly end-to-end runs, oldest first - one entry per run, appended by\n"
               "# nightly/nightly.sh. A page lists them newest first by reading in reverse.\n")
out.append(f"- run: {q(e['RUN_ID'])}")
out.append(f"  started: {q(e['START'])}")
out.append(f"  finished: {q(e['END'])}")
out.append(f"  minutes: {round(int(e['DURATION']) / 60)}")
out.append(f"  trigger: {e['TRIGGER']}")
out.append(f"  changed: [{', '.join(q(c) for c in e['CHANGED'].split())}]")
out.append(f"  sources: {{{', '.join(q(k) + ': ' + q(v) for k, v in (x.split('=', 1) for x in e['REVS'].split()))}}}")
out.append(f"  version: {{deb: {q(e['DEB_V'])}, ytserv: {q(e['YTS_V'])}, bumped: {e['BUMPED']}}}")
out.append("  steps:")
for n, p, f, s, r in steps:
    out.append(f"    - {{name: {n}, result: {r}, minutes: {round(s / 60)}}}")
out.append("  suites:")
for n, p, f, s, r in suites:
    out.append(f"    - {{name: {q(n)}, passed: {p}, failed: {f}, minutes: {round(s / 60)}, result: {r}}}")
if not suites:
    out[-1] = "  suites: []"
out.append(f"  totals: {{passed: {sum(r[1] for r in suites)}, failed: {sum(r[2] for r in suites)}}}")
out.append(f"  result: {e['RESULT']}")
if e.get("COVERAGE_PCT"):
    out.append(f"  coverage: {e['COVERAGE_PCT']}")
pub = {k: v for k, v in (("deb", e["PUBLISHED_DEB"]), ("rpm", e["PUBLISHED_RPM"]), ("tgz", e.get("PUBLISHED_TGZ")),
                         ("image", e.get("PUBLISHED_IMAGE")), ("sge", e.get("PUBLISHED_SGE"))) if v}
out.append("  published: " + ("{" + ", ".join(f"{k}: {q(v)}" for k, v in pub.items()) + "}" if pub else "null"))
if e.get("AB_LINE"):
    out.append(f"  ab: {q(e['AB_LINE'])}")
if e["NOTE"]:
    out.append(f"  note: {q(e['NOTE'])}")
with open(e["RESULTS"], "a") as fh:
    fh.write("\n".join(out) + "\n")
EOF

# ── 7. the badge, the history ───────────────────────────────────────────────────
# the badge vouches for what can be installed: only a promotion renews it, straight
# on the apt host
if [ -z "$PUBLISHED_DEB" ]; then
	say "   badge kept: this run published nothing"
elif python3 "$HERE/badge.py" --out "$REPO_DIR/paks/nightly/badge.svg"; then
	say "   badge renewed: $PUBLISHED_DEB"
else
	say "   badge not written: the previous one stays"
fi
# [safety] the regular ytserv's: what it links audited, its own crates unsafe-free
if [ -n "$PUBLISHED_DEB" ]; then
	if YT_PGXT="$YT_PGXT" python3 "$HERE/safety_badge.py" --out "$REPO_DIR/paks/nightly/ytserv-safety.svg"; then
		say "   safety badge renewed"
	else
		say "   safety badge not written: the previous one stays"
	fi
fi
# a run never pushes work in progress along with its history: not on main, or
# with commits of its own waiting there, the files wait for a hand push
if [ "${NIGHTLY_PUSH:-0}" = 1 ]; then
	if [ "$(git -C "$TESTS" rev-parse --abbrev-ref HEAD)" != main ] \
	   || [ -n "$(git -C "$TESTS" rev-list origin/main..HEAD 2>/dev/null)" ]; then
		say "   results not pushed: not on main, or unpushed commits wait there"
	elif PUSHED=(nightly/results.yaml) \
	     && { [ ! -f "$COVERAGE_FILE" ] || PUSHED+=(nightly/coverage.yaml); } \
	     && git -C "$TESTS" add -- "${PUSHED[@]}" \
	     && git -C "$TESTS" commit -q -m "nightly $RUN_ID: $RESULT" -- "${PUSHED[@]}" \
	     && git -C "$TESTS" push -q origin HEAD:main; then
		say "   results pushed"
	else
		say "   results not pushed"
	fi
fi
say "== nightly $RESULT: $(awk -F'\t' '$1!="build"&&$1!="coverage-build"&&$1!="coverage"&&$1!="release"&&$1!="publish"{p+=$2;f+=$3} END{print p+0" passed, "f+0" failed"}' "$ROWS"), $(( ($(secs) - T0) / 60 )) min${PUBLISHED_DEB:+, published $PUBLISHED_DEB}${NOTE:+ - $NOTE}"
say "   logs: $LOGS"
[ "$RESULT" = pass ]
