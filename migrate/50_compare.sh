#!/usr/bin/env bash
# The end: every writer has finished its loop and the traffic has stopped; then
# every node's database is compared with every other's, and each writer's rows
# with what it was told.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# the last writer started last: its loop, and as much again for a slow cluster
limit=$(( MIG_LOOP * (MIG_PAUSE + 1) + 600 ))
say "-- $(now) waiting for the writers of nodes $(members | tr '\n' ' ')(up to ${limit}s)"
all_done() { local n; for n in $(members); do writer_done "$n" || return 1; done; }
if wait_for "$limit" all_done; then
	ok "every writer finished its $MIG_LOOP rows"
else
	bad "a writer is still going after ${limit}s: $(for n in $(members); do writer_done "$n" || printf '%s ' "$n"; done)"
	for n in $(members); do xn "$n" touch /root/mig/stop; done
	sleep 5
fi
for n in $(members); do say "   ....  node $n writer: $(writer_counts "$n")"; done

# every node the same: the rows, and each row's values as its origin wrote them
digest() { qc "$1" "select count(*) || ' ' || md5(coalesce(string_agg(node || ':' || seq || ':' || extract(epoch from at), ',' order by node, seq), '')) from mig_seq"; }
same() { local n d; d=$(digest "$(members | head -1)"); for n in $(members); do [ "$(digest "$n")" = "$d" ] || return 1; done; }
if wait_for "$MIG_WAIT" same; then
	ok "every node holds the same mig_seq: $(digest "$(members | head -1)")"
else
	bad "the nodes' mig_seq differ after ${MIG_WAIT}s"
	for n in $(members); do say "   ....  node $n: $(digest "$n")"; done
fi
# the hot rows the copy's source updated (35_copy.sh): every node the same
hsame() { local n d; d=$(hot_digest "$(members | head -1)"); for n in $(members); do [ "$(hot_digest "$n")" = "$d" ] || return 1; done; }
if wait_for "$MIG_WAIT" hsame; then
	ok "every node holds the same mig_hot: $(hot_digest "$(members | head -1)")"
else
	bad "the nodes' mig_hot differ after ${MIG_WAIT}s"
	for n in $(members); do say "   ....  node $n: $(hot_digest "$n")"; done
fi
ldigest() { qc "$1" "select count(*) || ' ' || md5(string_agg(id || ':' || v, ',' order by id)) from mig_local"; }
d=$(ldigest 1)
for n in $(members); do check "node $n: mig_local as node 1's, from the dumps" "$d" "$(ldigest "$n")"; done
for n in $(members); do
	check "node $n: every node in its roster" "$(members | wc -l)" "$(qc "$n" "select count(*) from $CFG where module = 'N'" postgres)"
done
t=$(term_of "$(members | head -1)")
for n in $(members); do check "node $n at the cluster's term" "$t" "$(term_of "$n")"; done

# each writer: its OK rows everywhere, its refused ones nowhere
qc "$(members | head -1)" "select node || ' ' || seq from mig_seq" > "$RUN/rows"
args=()
for n in $(members); do
	lxc file pull "$(cname "$n")/root/mig/writer.log" "$RUN/writer.$n.log" >/dev/null && args+=("$(nuuid "$n")=$RUN/writer.$n.log")
done
out="$(python3 "$MIG_HERE/verify.py" "$RUN/rows" "${args[@]}")"
say "$out"
pass=$((pass + $(grep -c '^  OK ' <<< "$out"))); fail=$((fail + $(grep -c '^  FAIL ' <<< "$out")))
finish
