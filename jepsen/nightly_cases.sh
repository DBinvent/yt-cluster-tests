#!/usr/bin/env bash
# [jepsen] The nightly's jepsen suite: the four cases that found most of findings.md's
# issues (28 to 49), each run once on the build under test and judged as the retests
# were - a regression of their fixes shows the next morning, not first at a run by
# hand:
#
#   case 2   sequential, rw, partition + kill + pause, 60 s
#   case 20  half, node bouncing (kill + pause), append, 60 s
#   case 24  sequential, rw, partition + kill + pause, 300 s
#   case 25  sequential + recon, rw, partition + kill + pause + packet, 300 s
#
#   jepsen/nightly_cases.sh [--deb FILE]      about 20 minutes, run.sh's --deb default
#
# Under the nightly's lock, as run.sh takes it: by hand it takes it once for the four
# cases; the nightly holds it itself and sets JEPSEN_LOCKED. One line a case for the
# nightly's count - `OK` passed, `FAIL` not - then "---- jepsen: <p> passed, <f>
# failed ----". Each run's output, and a failed run's store, go to JEPSEN_OUT (the
# nightly: its run's logs; by hand: a new directory under /tmp, named at the start).
#   strict:   Elle valid (cursor-stability), the copies converged, nothing stuck, a
#             leader on every node, no CLUSTER DIVERGENCE
#   eventual: the same, Elle reported only (`half`, findings.md)
# A run that committed no write and is otherwise clean is no data - Elle has nothing
# to check (unknown, an empty graph), the faults left no leader through the client
# phase: run again, three times at most, never a pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEB=""
while [ $# -gt 0 ]; do
	case "$1" in
		--deb) DEB="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "${JEPSEN_LOCKED:-}" ]; then
	export JEPSEN_LOCKED=1
	exec "$HERE/../nightly/locked.sh" "$HERE/nightly_cases.sh" ${DEB:+--deb "$DEB"}
fi
OUT="${JEPSEN_OUT:-$(mktemp -d /tmp/yt-jepsen-cases.XXXXXX)}"
mkdir -p "$OUT"
echo "== jepsen cases: output in $OUT"

COMMON=(--rate 50 --concurrency 2n --isolation serializable --expected-consistency-model cursor-stability)
PKP=partition,kill,pause
CASES=(
	# case|config|judge|workload|nemesis|seconds|extra
	"2|sequential|strict|rw|$PKP|60|"
	"20|half, node bouncing|eventual|append|kill,pause|60|--commit half"
	"24|sequential|strict|rw|$PKP|300|"
	"25|sequential + recon|strict|rw|$PKP,packet|300|--recon"
)
field() { sed -n "s/^  $1: //p" "$HERE/results.yaml" | head -1; }

# run_case <case> <judge> <workload> <nemesis> <seconds> <extra> <try>: one run -
# 0 passed, 1 failed, 2 no data; DETAIL says what it found
DETAIL=""
run_case() {
	local n="$1" judge="$2" w="$3" nem="$4" secs="$5" extra="$6" try="$7"
	local verdict stuck div ll conv store anomalies writes=0 ok=1
	rm -f "$HERE/results.yaml"
	# shellcheck disable=SC2086
	"$HERE/run.sh" ${DEB:+--deb "$DEB"} -- --workload "$w" --nemesis "$nem" --time-limit "$secs" \
		"${COMMON[@]}" $extra > "$OUT/case$n.$try.out" 2>&1
	verdict="$(field verdict)"; stuck="$(field stuck)"; div="$(field divergence)"
	ll="$(field leaderless)"; conv="$(field converged)"; store="$(field store)"; anomalies="$(field anomalies)"
	if [ -n "$store" ] && [ -f "$HERE/$store/history.txt" ]; then
		writes="$(grep -P '^\d+\t:ok\t:txn\t' "$HERE/$store/history.txt" | grep -oE '\[:(w|append) ' | wc -l)"
	fi
	DETAIL="${verdict:-no result}, writes $writes, stuck ${stuck:-?}, divergence ${div:-?}, leaderless ${ll:-?}, converged ${conv:-?}"
	case "$conv" in yes*) ;; *) ok=0 ;; esac
	[ "$stuck" = 0 ] && [ "$ll" = 0 ] && [ "$div" = 0 ] || ok=0
	if [ "$ok" = 1 ] && [ "$verdict" = unknown ] && [ "$writes" = 0 ] && [[ "$anomalies" == *empty-transaction-graph* ]]; then
		return 2
	fi
	[ "$judge" = eventual ] || [ "$verdict" = valid ] || ok=0
	if [ "$ok" = 0 ]; then
		[ -z "$store" ] || cp -a "$HERE/$store" "$OUT/case$n.store" 2>/dev/null
		return 1
	fi
	return 0
}

passed=0; failed=0
for c in "${CASES[@]}"; do
	IFS='|' read -r n cfg judge w nem secs extra <<<"$c"
	name="case $n ($cfg, $w, ${nem//,/ + }, $secs s)"
	echo "-- $(date -u +%T) $name"
	try=1
	while :; do
		run_case "$n" "$judge" "$w" "$nem" "$secs" "$extra" "$try"; rc=$?
		[ "$rc" = 2 ] && [ "$try" -le 3 ] || break
		echo "   no data: no write committed, nothing for Elle to check - again"
		try=$((try + 1))
	done
	if [ "$rc" = 0 ]; then
		echo "  OK   $name: $DETAIL"
		passed=$((passed + 1))
	else
		echo "  FAIL $name: $DETAIL$([ "$rc" = 2 ] && echo " - no data four times")$([ -d "$OUT/case$n.store" ] && echo " - store: $OUT/case$n.store")"
		failed=$((failed + 1))
	fi
done
echo "---- jepsen: $passed passed, $failed failed ----"
[ "$failed" = 0 ]
