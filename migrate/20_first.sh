#!/usr/bin/env bash
# Step 1, on the server the application runs on, while it writes:
# YT Cluster installed, PostgreSQL restarted (the one restart: ytctl's yt.conf sets
# max_prepared_transactions and shared_preload_libraries), then the backup.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

say "-- $(now) node 1: YT Cluster on the running server"
[ -n "$MIG_DEB" ] && [ -f "$MIG_DEB" ] || { bad "no package: MIG_DEB (or YT_CLUSTER_DEB) names none"; finish; }
t0="$(qc 1 "select pg_postmaster_start_time()" postgres)"
before="$(qc 1 "select count(*) from mig_seq")"

# the package
lxc file push "$MIG_DEB" "$(cname 1)/tmp/yt-cluster.deb" >/dev/null
if xn 1 env DEBIAN_FRONTEND=noninteractive apt-get install -qy /tmp/yt-cluster.deb >/dev/null 2>&1; then
	ok "node 1: apt installs $(basename "$MIG_DEB")"
else
	bad "node 1: apt install $(basename "$MIG_DEB")"; finish
fi
# the node: its own address is the whole roster, so its uuid is the one every
# later node's --peers derives for it
ipn 1 > "$RUN/peers.1"
push_peers 1 "$RUN/peers.1" && ok "node 1: its roster file is in place" || { bad "node 1: its roster file"; finish; }
xn 1 ytctl -v --batch -t "$CFG" --peers /etc/yt-cluster/peers --config-trigger \
	--users-db "$MIG_DB" --tables public.mig_seq \
	--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql" > "$RUN/ytctl.1.log" 2>&1
rc=$?
check "node 1: ytctl --batch exits 0" 0 "$rc"
[ "$rc" -eq 0 ] || say "$(tail -5 "$RUN/ytctl.1.log")"

t1="$(qc 1 "select pg_postmaster_start_time()" postgres)"
[ -n "$t1" ] && [ "$t1" != "$t0" ] && ok "node 1: PostgreSQL was restarted (started $t1)" \
	|| bad "node 1: PostgreSQL restart: started $t0 before, $t1 after"
check "node 1: max_prepared_transactions, 0 before, now from yt.conf" 100 \
	"$(qc 1 "show max_prepared_transactions" postgres)"
check "node 1: shared_preload_libraries has yt_cluster" 1 \
	"$(qc 1 "select count(*) from regexp_split_to_table(current_setting('shared_preload_libraries'), '\s*,\s*') l where l = 'yt_cluster'" postgres)"
check "node 1: yt.node is the uuid its address gives" "$(nuuid 1)" "$(qc 1 "show yt.node" postgres)"
wait_for 60 is_state 1 Leader && ok "node 1 leads its cluster of one, term $(term_of 1)" \
	|| bad "node 1 does not lead: [$(state_of 1)]"
check "node 1: mig_seq has its sync trigger" 1 \
	"$(qc 1 "select count(*) from pg_trigger where tgrelid = 'mig_seq'::regclass and tgname = 'zytsync_public_mig_seq_trigger'")"
# mig_hot on the cluster too, as yt_setup registers a table by hand: the copy's hot rows
q 1 <<'SQL' >/dev/null || bad "node 1: mig_hot registered"
select * from yt_setup('public.mig_hot', '', true, 'public.yt_config');
SQL
check "node 1: mig_hot has its sync trigger" 1 \
	"$(qc 1 "select count(*) from pg_trigger where tgrelid = 'mig_hot'::regclass and tgname = 'zytsync_public_mig_hot_trigger'")"
qc 1 "select value from $CFG where module = 'C' and name = 'cluster'" postgres > "$RUN/cluster"
[ -s "$RUN/cluster" ] && ok "node 1: cluster uuid $(cat "$RUN/cluster")" || bad "node 1: no C cluster row"
add_member 1

# the application went on through the restart: a few refused connections, and
# its rows commit into the cluster now
after() { [ "$(qc 1 "select count(*) from mig_seq")" -ge $(( before + 10 )) ] 2>/dev/null; }
wait_for 60 after && ok "node 1: the application writes on through the cluster ($(writer_counts 1))" \
	|| bad "node 1: the application's rows stopped: $(qc 1 "select count(*) from mig_seq") rows, $(writer_counts 1)"
# a transaction the restart cut is UNK - judged at the end like any other; a
# clean refusal (ERR) would be the cluster turning the application away
refused="$(xn 1 sh -c "grep -c ' ERR ' /root/mig/writer.log" 2>/dev/null)"
check "node 1: through the install no transaction was refused" 0 "${refused:-0}"

# the backup: the application's database and the roles, as pg_dump makes them
say "-- $(now) node 1: the backup"
if dump_on 1; then
	lxc file pull "$(cname 1)$DUMP_AT/mig.dump" "$RUN/dump.1" && lxc file pull "$(cname 1)$DUMP_AT/mig-roles.sql" "$RUN/roles.1" \
		&& ok "node 1: pg_dump of $MIG_DB under load, $(du -h "$RUN/dump.1" | cut -f1)" || bad "node 1: the dump did not copy out"
else
	bad "node 1: pg_dump"
fi
finish
