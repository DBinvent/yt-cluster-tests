#!/usr/bin/env bash
# [tpl2] Remove the hierarchical fixture's containers - every node in NODES
# (env.sh: u1-u3, a1-a4, b1-b4). As ../topology/90_down.sh does for its own: the
# image and the network are left - a rebuild is the expensive part and nothing in
# them carries test state.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
for n in "${NODES[@]}"; do rh "docker rm -f $n >/dev/null 2>&1; true"; done
# [lite] and the lite node of 85_lite.sh, when it ran
# the leaves of 85_lite.sh and 87_load.sh
rh "docker rm -f l1 lt1 lt2 lt3 tt1 tt2 tt3 >/dev/null 2>&1; true"
echo "Removed ${#NODES[@]} containers. (docker network rm $YX_NET / docker rmi $YX_IMAGE to go further.)"
rh "free -m | awk '/Mem:/{print \"  host avail: \"\$7\" MB\"}'"
