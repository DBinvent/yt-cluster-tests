#!/usr/bin/env bash
# Delete the containers. MIG_KEEP=1 keeps them for a look (inspect.sh).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ "${MIG_KEEP:-0}" = 1 ]; then
	say "MIG_KEEP=1: the containers stay ($(for n in $MIG_NODES $MIG_COPY; do printf '%s ' "$(cname "$n")"; done))"
	exit 0
fi
for c in "$MIG_PREFIX-base" $(for n in $MIG_NODES $MIG_COPY; do cname "$n"; done); do
	lxc delete --force "$c" >/dev/null 2>&1 && say "deleted $c"
done
exit 0
