#!/usr/bin/env bash
# [labac] The environment down: its containers, its network, and the run's folder with the keys
# and the tokens.
cd "$(dirname "$0")"
source ./env.sh
rh "docker rm -f ${LX_ALL[*]} >/dev/null 2>&1; docker network rm $LX_NET >/dev/null 2>&1; true"
case "$LX_RUN" in
	*/yxlabac-*) rm -rf "$LX_RUN" ;;
	*) echo "  the run's folder $LX_RUN is left: not one this script names" ;;
esac
echo "  labac environment down"
