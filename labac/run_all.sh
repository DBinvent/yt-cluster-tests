#!/usr/bin/env bash
# [labac] The whole run: build, up, the identity provider's side, signon's and ytproxy's, the
# sign-ins, every person against every table in both modes, the groups changed - and down.
#
#   labac/run_all.sh            the run; the environment is taken down at its end
#   LABAC_KEEP=1 labac/run_all.sh   leave it up (90_down.sh takes it down)
#
# On hosts the nightly also uses, run it under the nightly's lock: nightly/locked.sh labac/run_all.sh
set -uo pipefail
cd "$(dirname "$0")"
failed=()
for s in 00_build.sh 10_up.sh 20_ferriskey.sh 30_setup.sh 40_login.sh 50_queries.sh 60_regroup.sh; do
	echo "######## $s"
	if ! ./"$s"; then
		failed+=("$s")
		# what is built on a step that failed would only fail after it
		case "$s" in 00_*|10_*|20_*|30_*) break ;; esac
	fi
done
[ "${LABAC_KEEP:-0}" = 1 ] || ./90_down.sh
if [ ${#failed[@]} -eq 0 ]; then echo "######## labac: all passed"; else echo "######## labac: FAILED ${failed[*]}"; exit 1; fi
