#!/usr/bin/env bash
# up.sh with its output in a file, as the nightly runs it (nightly.sh RMC_UP): every
# check line it printed is passed on, so the suite's log counts the layout's own
# checks whether it came up or not; when it stopped, its last lines and a FAIL.
#
#   ./up_logged.sh [log]      default /tmp/nightly-rmc-up.log
cd "$(dirname "$0")" || exit 1
log="${1:-/tmp/nightly-rmc-up.log}"
checks='^[[:space:]]*(OK|PASS|FAIL|GAP)([[:space:]:]|$)'
./up.sh > "$log" 2>&1
rc=$?
grep -aE "$checks" "$log"
if [ "$rc" -ne 0 ]; then
    tail -30 "$log" | grep -avE "$checks"
    echo "  FAIL  rmc up.sh"
fi
exit "$rc"
