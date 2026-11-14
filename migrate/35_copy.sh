#!/usr/bin/env bash
# A node added by `ytctl --copy` while every node writes (yt-cluster ytserv/membership.md,
# "Expansion"; problems.md P12): the tool itself, on a box with nothing but PostgreSQL and the
# package. It writes the node's roster row on the leader it copies, makes the copy request
# there, stops the box's PostgreSQL through systemd, moves its data directory aside, takes the
# backup with pg_basebackup, undoes the request, writes the node's settings, starts PostgreSQL
# on the copy, clears the identity rows the copy carried over and writes the backup's end
# beside the copy row - then the rest of the install, ytserv started.
#
# Meanwhile the source's hot rows are updated as fast as the cluster commits (hot.sh): each
# transaction the shared row 0 and a row of its own. The copy pulls everything after the
# position its source wrote before the backup began, and the writes made while the backup ran
# are in its rows already: row 0 a later version than such a write expects, and its own row
# written by no later transaction that could carry it. Those misses are the backup's -
# yt_info('E') `copy_end` "<end> held <n>" - never a CLUSTER DIVERGENCE, and every node ends
# with the same hot rows.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

k="$MIG_COPY"
[ -n "$k" ] || { say "MIG_COPY is empty: no copy"; finish; }
l=$(leader)
[ -n "$l" ] || { bad "node $k: no leader to copy"; finish; }
say "-- $(now) node $k: a copy of node $l, the leader, by ytctl --copy; members $(members | tr '\n' ' ')"
refused0=$(refused_all)

# 1. the source: a superuser over the network for the copy's psql and pg_basebackup -
# replication is let in by 00_create.sh's pg_hba line; the password goes in the variable
# ytctl is told of (--copy_pgp_env)
qc "$l" "alter role postgres password '$MIG_PASS'" postgres >/dev/null \
	&& ok "node $l: postgres connects over the network, for the copy" || bad "node $l: the postgres password"

# 2. the hot rows, on the source, from before the copy request to after the copy follows
hot_start "$l" || bad "node $l: the hot rows' updater did not start"
busy() { [ "$(hot_count "$l")" -ge 50 ] 2>/dev/null; }
wait_for 60 busy && ok "node $l: the hot rows are updated, one cluster transaction each ($(hot_count "$l") so far)" \
	|| bad "node $l: the hot rows are not updated: $(hot_count "$l") committed, [$(xn "$l" tail -2 /root/mig/hot.log 2>/dev/null | tr '\n' ' ')]"

# 3. the package on the copy's box
lxc file push "$MIG_DEB" "$(cname "$k")/tmp/yt-cluster.deb" >/dev/null
xn "$k" env DEBIAN_FRONTEND=noninteractive apt-get install -qy /tmp/yt-cluster.deb >/dev/null 2>&1 \
	&& ok "node $k: apt installs $(basename "$MIG_DEB")" || { bad "node $k: apt install"; hot_stop "$l"; finish; }
dd0="$(qc "$k" "show data_directory" postgres)"

# 4. the copy: ytctl as the operator runs it, its node id the one its address gives, its
# roster row written on the source - the leader - by ytctl itself
h0=$(hot_count "$l")
t0=$(date +%s)
xn "$k" env MIG_COPY_PW="$MIG_PASS" ytctl -v --batch -t "$CFG" --uuid "$(nuuid "$k")" --bind "$(ipn "$k"):$PORT" \
	--copy "postgresql://postgres@$(ipn "$l"):5432/postgres" --copy_pgp_env MIG_COPY_PW \
	--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql" > "$RUN/ytctl.$k.log" 2>&1
rc=$?
check "node $k: ytctl --copy exits 0" 0 "$rc"
[ "$rc" -eq 0 ] || say "$(tail -15 "$RUN/ytctl.$k.log" | sed 's/^/   ....  /')"
say "   ....  the copy took $(( $(date +%s) - t0 ))s, $(( $(hot_count "$l") - h0 )) hot updates committed meanwhile"
case "$(grep -c 'pg_basebackup' "$RUN/ytctl.$k.log")" in 0) bad "node $k: no pg_basebackup in ytctl's output" ;; *) ok "node $k: the backup by pg_basebackup" ;; esac
check "node $k: its data directory is where it was, the copy in it" "$dd0" "$(qc "$k" "show data_directory" postgres)"
aside="$(xn "$k" sh -c "ls -d ${dd0}_* 2>/dev/null | head -1")"
[ -n "$aside" ] && ok "node $k: the box's own data directory moved aside ($aside)" || bad "node $k: no data directory moved aside"
check "node $k: its databases are the source's" "$(qc "$l" "select string_agg(datname, ',' order by datname) from pg_database" postgres)" \
	"$(qc "$k" "select string_agg(datname, ',' order by datname) from pg_database" postgres)"
check "node $k: max_prepared_transactions from yt.conf" 100 "$(qc "$k" "show max_prepared_transactions" postgres)"
check "node $k: yt.node is the uuid its address gives" "$(nuuid "$k")" "$(qc "$k" "show yt.node" postgres)"
check "node $l: the copy request undone, its row gone from the source" 0 \
	"$(qc "$l" "select count(*) from $CFG where module = 'C' and name like 'copy.$(nuuid "$k")%'" postgres)"
check "node $k: the identity rows the copy carried over are cleared" 0 \
	"$(qc "$k" "select count(*) from $CFG where module = 'C' and name in ('leader_uuid', 'term', 'data_version_dump')" postgres)"
end="$(grep -o "the backup's end [0-9:;,*]* written" "$RUN/ytctl.$k.log" | head -1)"
[ -n "$end" ] && ok "node $k: $end beside the copy row" || bad "node $k: ytctl wrote no backup's end"
# a copy that did not go through follows nothing: said, not waited for
[ "$rc" -eq 0 ] || { hot_stop "$l"; "$MIG_HERE/inspect.sh" "$k" "$l"; finish; }

# 5. it follows: in every roster, and Good under the leader
waiting() { qc "$k" "select value from json_to_recordset(yt_info('E')) as x(name text, value text, module text) where name = 'fill'" postgres 2>/dev/null; }
if wait_for "$MIG_WAIT" follows "$k"; then
	ok "node $k follows after $(( $(date +%s) - t0 ))s"
else
	bad "node $k does not follow within ${MIG_WAIT}s: [$(state_of "$k")], fill [$(waiting)]"
	"$MIG_HERE/inspect.sh" "$k" "$l"
fi
roster() { qc "$1" "select count(*) from $CFG where module = 'N' and name = '$(nuuid "$k")'" postgres; }
for m in $(members) "$k"; do
	has() { [ "$(roster "$m")" = 1 ]; }
	wait_for 60 has && ok "node $m's roster holds node $k" || bad "node $m's roster lacks node $k"
done

# 6. the window: the misses the backup held, none a divergence; its rows go once it holds
# records of its own
# (following, it may still be pulling the window: the count grows until it is through)
held_some() { ce="$(einfo "$k" copy_end)"; held="${ce##* held }"; [ "${held:-0}" -ge 1 ] 2>/dev/null; }
case "$(einfo "$k" copy_end)" in
	*" held "*) if wait_for 120 held_some; then ok "node $k: the backup held $held of the writes it pulled (copy_end $ce)"
		else bad "node $k: no write of the backup's time missed on the copy (copy_end $ce): the window was not tried"; fi ;;
	*) bad "node $k: no copy_end in yt_info('E'): [$(einfo "$k" copy_end)]" ;;
esac
check "node $k: no divergence on the copy" 0 "$(einfo "$k" divergent)"
gone() { [ "$(qc "$k" "select count(*) from $CFG where module = 'C' and name like 'copy.%'" postgres)" = 0 ]; }
wait_for 60 gone && ok "node $k: its copy row and the backup's end row are gone: it holds records of its own" \
	|| bad "node $k: its copy rows are still there: $(qc "$k" "select string_agg(name, ' ') from $CFG where module = 'C' and name like 'copy.%'" postgres)"

# 7. the hot rows stop, and every node holds the same, the copy too
hot_stop "$l" || bad "node $l: the hot rows' updater did not stop"
say "   ....  node $l hot updates: $(hot_count "$l") committed"
hsame() { local n d; d=$(hot_digest "$l"); for n in $(members) "$k"; do [ "$(hot_digest "$n")" = "$d" ] || return 1; done; }
if wait_for "$MIG_WAIT" hsame; then
	ok "every node and the copy hold the same mig_hot: $(hot_digest "$l")"
else
	bad "mig_hot differs after ${MIG_WAIT}s"
	for n in $(members) "$k"; do say "   ....  node $n: $(hot_digest "$n")"; done
fi
check "node $k: still no divergence" 0 "$(einfo "$k" divergent)"

# 8. it writes too, now that it is in
add_member "$k"
writer_start "$k" || bad "node $k: the writer did not start"
first() { [ "$(qc "$k" "select count(*) from mig_seq where node = '$(nuuid "$k")'")" -ge 5 ] 2>/dev/null; }
wait_for 60 first && ok "node $k: its writer's rows commit ($(writer_counts "$k"))" \
	|| bad "node $k: its writer's rows do not commit: $(writer_counts "$k"), last [$(xn "$k" tail -1 /root/mig/writer.log 2>/dev/null)]"
check "the copy refused no application write on any node" "$refused0" "$(refused_all)"
[ "$(refused_all)" = "$refused0" ] || for m in $(members); do
	xn "$m" sh -c "grep ' ERR ' /root/mig/writer.log" 2>/dev/null | cut -c1-200 | sed "s/^/   ....  node $m refused: /"
done
for m in $(members); do say "   ....  node $m writer: $(writer_counts "$m")"; done
finish
