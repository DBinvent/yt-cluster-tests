#!/usr/bin/env bash
# Step 2, for one new node, while every node already in the cluster writes:
# the dump of the node that joined before it, YT Cluster installed, the dump
# restored, then the cluster told of the node. It follows, and starts writing.
#
#   30_join.sh <node>
#
# The order is the procedure's (yt-cluster migration.md): installed first, the new
# node's ytserv waits - it is in no member's roster, so nobody answers it; the
# restore lands while it waits; only the roster row on the leader lets it in, and
# it then copies every synced table from a member and replays what the copy
# missed. A node told of before its restore would copy tables it does not have yet.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

k="${1:?usage: 30_join.sh <node>}"
p=$(members | tail -1)
[ -n "$p" ] || { bad "node $k: no node in the cluster yet (20_first.sh)"; finish; }
say "-- $(now) node $k joins from a dump of node $p, members $(members | tr '\n' ' ')"
refused0=$(refused_all)

# 1. the dump of the previous node, taken while it writes (node 1's is the backup)
if [ ! -s "$RUN/dump.$p" ]; then
	if dump_on "$p"; then
		lxc file pull "$(cname "$p")$DUMP_AT/mig.dump" "$RUN/dump.$p" && lxc file pull "$(cname "$p")$DUMP_AT/mig-roles.sql" "$RUN/roles.$p" \
			&& ok "node $p: pg_dump of $MIG_DB under load, $(du -h "$RUN/dump.$p" | cut -f1)" || bad "node $p: the dump did not copy out"
	else
		bad "node $p: pg_dump"
	fi
fi
# 2. the transfer
lxc file push "$RUN/dump.$p" "$(cname "$k")/tmp/mig.dump" >/dev/null && lxc file push "$RUN/roles.$p" "$(cname "$k")/tmp/mig-roles.sql" >/dev/null \
	&& xn "$k" chmod 644 /tmp/mig.dump /tmp/mig-roles.sql || { bad "node $k: the dump did not copy in"; finish; }

# 3. YT Cluster: the package, then ytctl with the roster - every member and itself -
# and the cluster's uuid. PostgreSQL restarts once; ytserv starts and waits.
lxc file push "$MIG_DEB" "$(cname "$k")/tmp/yt-cluster.deb" >/dev/null
xn "$k" env DEBIAN_FRONTEND=noninteractive apt-get install -qy /tmp/yt-cluster.deb >/dev/null 2>&1 \
	&& ok "node $k: apt installs $(basename "$MIG_DEB")" || { bad "node $k: apt install"; finish; }
for m in $(members) "$k"; do ipn "$m"; done > "$RUN/peers.$k"
xn "$k" mkdir -p /etc/yt-cluster && lxc file push "$RUN/peers.$k" "$(cname "$k")/etc/yt-cluster/peers" >/dev/null
check "node $k: the roster file lists every member and itself" "$(members | wc -l | awk '{print $1 + 1}')" "$(xn "$k" grep -c . /etc/yt-cluster/peers)"
xn "$k" ytctl -v --batch -t "$CFG" --peers /etc/yt-cluster/peers --cluster "$(cat "$RUN/cluster")" --config-trigger \
	--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql" > "$RUN/ytctl.$k.log" 2>&1
rc=$?
check "node $k: ytctl --batch exits 0" 0 "$rc"
[ "$rc" -eq 0 ] || say "$(tail -5 "$RUN/ytctl.$k.log")"
check "node $k: max_prepared_transactions from yt.conf (a restart)" 100 "$(qc "$k" "show max_prepared_transactions" postgres)"
check "node $k: yt.node is the uuid its address gives" "$(nuuid "$k")" "$(qc "$k" "show yt.node" postgres)"
waiting() { qc "$k" "select value from json_to_recordset(yt_info('E')) as x(name text, value text, module text) where name = 'fill'" postgres 2>/dev/null; }
w="$(waiting)"
case "$w" in
	*"waiting to hear"*|*"no data and no position"*) ok "node $k waits, held back: [$w]" ;;
	*) bad "node $k should wait for the cluster before its restore: fill [$w], state [$(state_of "$k")]" ;;
esac

# 4. the restore: the roles, the database, then the database registered as ytctl's
# --users-db does it - the dump holds its tables' triggers and A rows, not the
# trigger on its own config table (an extension table's triggers are not dumped)
xn "$k" su postgres -c "psql -X -q -f /tmp/mig-roles.sql" 2>&1 | grep -v 'already exists' | sed 's/^/   /'
if xn "$k" su postgres -c "createdb -O $MIG_USER $MIG_DB && pg_restore -d $MIG_DB /tmp/mig.dump"; then
	ok "node $k: pg_restore of node $p's dump"
else
	bad "node $k: createdb / pg_restore"
fi
q "$k" <<'SQL' >/dev/null || bad "node $k: the database registered"
select yt_info('U+');
select * from yt_setup('public.yt_config', '', true, 'public.yt_config');
SQL
trg() { qc "$1" "select string_agg(tgrelid::regclass || '.' || tgname, ' ' order by 1) from pg_trigger where not tgisinternal"; }
check "node $k: the restored database has node $p's sync triggers" "$(trg "$p")" "$(trg "$k")"
check "node $k: mig_local came in the dump" "$MIG_LOCAL_ROWS" "$(qc "$k" "select count(*) from mig_local")"

check "node $k still waits after its restore: no term, no cluster of its own" "0 no" \
	"$(term_of "$k") $(is_state "$k" Leader && echo yes || echo no)"

# 5. the cluster config: the node's roster row, on the leader - a cluster write
l=$(leader)
[ -n "$l" ] || { bad "node $k: the cluster has no leader"; finish; }
t0=$(date +%s)
err="$(qc "$l" "insert into $CFG (name, module, value) values ('$(nuuid "$k")', 'N', '$(ipn "$k"):$PORT')" postgres)" \
	&& ok "node $k: its N row commits on the leader, node $l" || bad "node $k: its N row on the leader, node $l: $err"
if wait_for "$MIG_WAIT" follows "$k"; then
	ok "node $k follows after $(( $(date +%s) - t0 ))s ($(waiting))"
else
	bad "node $k does not follow within ${MIG_WAIT}s: [$(state_of "$k")], fill [$(waiting)]"
	"$MIG_HERE/inspect.sh" "$k" "$l"
fi
roster() { qc "$1" "select count(*) from $CFG where module = 'N' and name = '$(nuuid "$k")'" postgres; }
for m in $(members) "$k"; do
	has() { [ "$(roster "$m")" = 1 ]; }
	wait_for 60 has && ok "node $m's roster holds node $k" || bad "node $m's roster lacks node $k"
done

# 6. it writes too, now that it is in
add_member "$k"
writer_start "$k" || bad "node $k: the writer did not start"
first() { [ "$(qc "$k" "select count(*) from mig_seq where node = '$(nuuid "$k")'")" -ge 5 ] 2>/dev/null; }
wait_for 60 first && ok "node $k: its writer's rows commit ($(writer_counts "$k"))" \
	|| bad "node $k: its writer's rows do not commit: $(writer_counts "$k"), last [$(xn "$k" tail -1 /root/mig/writer.log 2>/dev/null)]"
check "node $k's join refused no application write on any node" "$refused0" "$(refused_all)"
for m in $(members); do say "   ....  node $m writer: $(writer_counts "$m")"; done
finish
