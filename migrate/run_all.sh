#!/usr/bin/env bash
# The whole migration, start to end: the application's server becomes node 1 of a
# YT Cluster, then nodes 2, 3 and 4 join one by one, each from a dump of the node
# before it, every node writing all along; node 5 by `ytctl --copy` of the leader,
# its hot rows updated all through the backup; a new term; the databases compared.
#
# Every script runs while the containers exist; a red one is recorded and the run
# goes on, then exits 1 if anything failed. Ends with the line the nightly reads:
#   ---- migrate: <passed> passed, <failed> failed ----
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"

steps=("00_create.sh" "10_app.sh" "20_first.sh")
first=1
for n in $MIG_NODES; do [ "$first" = 1 ] && { first=0; continue; }; steps+=("30_join.sh $n"); done
# the copy's node, by ytctl --copy, before the new term: the election takes it in too
[ -n "$MIG_COPY" ] && steps+=("35_copy.sh")
steps+=("40_term.sh" "50_compare.sh")

passed=0; failed=0
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
for s in "${steps[@]}"; do
	echo "──── $s $(date -u +%T)"
	# shellcheck disable=SC2086
	"$HERE"/$s 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	p=$(grep -c '^  OK ' "$out"); f=$(grep -c '^  FAIL ' "$out")
	if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then echo "  FAIL  $s exited $rc without a FAIL line"; f=1; fi
	passed=$((passed + p)); failed=$((failed + f))
	# no containers: nothing after it can run
	if [ "$s" = 00_create.sh ] && [ "$rc" -ne 0 ]; then break; fi
done
[ "$failed" -eq 0 ] || "$HERE/inspect.sh"
"$HERE/90_destroy.sh"
echo "---- migrate: $passed passed, $failed failed ----"
[ "$failed" -eq 0 ]
