#!/bin/bash
# The hot rows, on the node a copy is taken of (35_copy.sh): each transaction one statement -
# a cluster transaction of its own - updating two rows of mig_hot, the shared row 0 and the
# next row of its own (1, 2, 3 ... in turn, back to 1 past the last), as fast as the cluster
# commits them, over TCP with a password as an application connects. A copy pulls again what
# was committed while its backup ran: row 0 has moved on in the backup, so such a write misses
# there, and its own row is written by no later transaction that could carry it - the case a
# copy's window holds (problems.md P12), a CLUSTER DIVERGENCE without it.
#
#   hot.sh <rows>
#
# psql's answers go to /root/mig/hot.log, one `UPDATE 2` a committed transaction;
# /root/mig/hot.stop ends it after the batch running, /root/mig/hot.done is written when it ends.
n="${1:-20000}"
dir=/root/mig
mkdir -p "$dir"
rm -f "$dir/hot.stop" "$dir/hot.done"
k=0
while [ ! -e "$dir/hot.stop" ]; do
	batch=""
	for _ in $(seq 1 20); do
		k=$(( k % n + 1 ))
		batch="$batch
update mig_hot set n = n + 1 where id in (0, $k);"
	done
	# each line its own transaction: psql runs stdin statement by statement
	printf '%s\n' "$batch" | PGCONNECT_TIMEOUT=5 timeout 120 psql "host=127.0.0.1 dbname=${MIG_DB:-appdb} user=${MIG_USER:-app}" \
		-X -v ON_ERROR_STOP=0 >> "$dir/hot.log" 2>&1
done
touch "$dir/hot.done"
