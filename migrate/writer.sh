#!/bin/bash
# The application on one server: rows (this node's uuid, 1 .. count) into mig_seq,
# one transaction a second, each a plain BEGIN / INSERT / COMMIT as an application
# sends it - nothing of YT Cluster in it. Runs on the server's own box, over TCP
# with a password, through the server's restart and the cluster's changes.
#
#   writer.sh <node uuid> <count> [pause seconds]
#
# The uuid is the node's yt.node; on node 1 the writer starts before YT Cluster is
# installed, and the test checks the installed yt.node is this one. Log lines, in
# /root/mig/writer.log:
#
#   <epoch-seconds> <seq> <outcome> <message>
#
#   OK   the commit returned success
#   ERR  a clean SQL error: nothing committed
#   NOC  no connection: nothing sent
#   UNK  the connection broke or a timeout hit mid-transaction: the row may or may
#        not exist, and every node must agree which
#
# /root/mig/stop ends it early; /root/mig/done is written when it ends.
u="$1"; count="$2"; pause="${3:-1}"
dir=/root/mig
log="$dir/writer.log"
mkdir -p "$dir"
rm -f "$dir/done"
seq=$(tail -1 "$log" 2>/dev/null | awk '{print $2}')
seq=${seq:-0}
while [ "$seq" -lt "$count" ] && [ ! -e "$dir/stop" ]; do
	seq=$((seq + 1))
	out=$(PGCONNECT_TIMEOUT=5 timeout 45 psql "host=127.0.0.1 dbname=${MIG_DB:-appdb} user=${MIG_USER:-app}" \
		-X -q -At -v ON_ERROR_STOP=1 \
		-c "set statement_timeout = '30s'" \
		-c "begin" \
		-c "insert into mig_seq (node, seq) values ('$u', $seq)" \
		-c "commit" 2>&1)
	rc=$?
	msg=$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-240)
	if [ "$rc" -eq 0 ]; then
		r=OK
	elif [ "$rc" -eq 124 ]; then
		r=UNK
	else
		# unknown before refused: a broken connection taken for a clean error would
		# count a row that did commit as one that must not exist (rmc/load/writer.sh)
		case "$out" in
			*"server closed the connection"*|*"terminating connection"*|*"could not receive data"*|\
			*"no connection to the server"*|*"statement timeout"*|*"canceling statement"*|*"SSL SYSCALL"*|\
			*"connection to server was lost"*|*"SSL error"*) r=UNK;;
			*"connection to server"*"failed"*|*"the database system is"*) r=NOC;;
			*) r=ERR;;
		esac
	fi
	printf '%s %s %s %s\n' "$(date +%s)" "$seq" "$r" "$msg" >> "$log"
	sleep "$pause"
done
touch "$dir/done"
