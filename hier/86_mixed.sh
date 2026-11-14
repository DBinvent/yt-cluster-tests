#!/usr/bin/env bash
# [mixed] YT Cluster 1.20 beside 1.21: the pieces of the last published 1.20 package put
# into this fixture's upper cluster one at a time, with 85_lite.sh's lite node on it -
# what a rolling upgrade from 1.20 to 1.21 has for a while.
#
# The extension has the same C code and the same protocol in both (its version, 0.5 then
# 1.21, is only its name); 1.21's ytserv serves 1.20's calls still; a 1.20 node has no
# Link service, the lite node's, and so it is no node a lite node can sign in through.
#
# Needs 85_lite.sh run on this fixture before it (the lite node l1 approved, t_lite on
# every node). The 1.20 package: YT_CLUSTER_DEB_PREV, else the newest
# yt-cluster_1.20.*_amd64-pg18.deb of the nightly's runs. Everything it changes is put
# back at the end: the fixture is as it was, for the scripts after it.
#
# ## What is asserted
#
# M1 1.20's extension library under a 1.21 ytserv (a node whose package is upgraded and
#    whose PostgreSQL still runs the old library): it loads (yt_info T: 0.5), and rows
#    cross both ways - from that node to the other upper nodes and the lite node, and to
#    it from them
# M2 1.20's ytserv over 1.21's library, in a cluster of 1.21 nodes (a node not upgraded
#    yet): it joins (yt_info E version 1.20), and rows cross both ways, the lite node's
#    and the 1.20 library node's among them
# M3 yt-lite with that 1.20 node first in its `upper`: it says the node has no Link
#    service (YT-E077), signs in through the next one, and rows cross both ways
# M4 all put back: 1.21's ytserv and library again, the lite node's hosts as they were,
#    and a row crosses
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== mixed: 1.20's ytserv and extension library beside 1.21, a lite node on the cluster =="

LN=l1
TBL=public.t_lite
PREV="${YT_CLUSTER_DEB_PREV:-$(ls -t "$TESTS_ROOT"/nightly/logs/*/yt-cluster_1.20.*_amd64-pg18.deb 2>/dev/null | head -1)}"
[ -f "$PREV" ] || { bad "no 1.20 package (YT_CLUSTER_DEB_PREV, or the nightly's logs/*/yt-cluster_1.20.*_amd64-pg18.deb)"; summary; }
X="$(mktemp -d)"
# what it swapped in is put back however the script ends (restore, below)
SWAPPED=""
trap 'restore; rm -rf "$X"' EXIT
dpkg-deb -x "$PREV" "$X"
OLD_SO="$(ls "$X"/usr/local/include/yt-cluster/yt_cluster*-pg18-glibc2_39.so 2>/dev/null | head -1)"
# the versions as that package has them: its extension's (the control file) and its
# ytserv's (`ytserv --version`), not from the file's name
OLD_EXT="$(sed -n "s/^default_version *= *'\(.*\)'.*/\1/p" "$X"/usr/local/include/yt-cluster/yt_cluster.control 2>/dev/null)"
OLD_YTS="$X/usr/local/bin/yt-cluster/ytserv"
[ -f "$OLD_SO" ] && [ -x "$OLD_YTS" ] && [ -n "$OLD_EXT" ] || { bad "$PREV holds no pg18 glibc 2.39 library, no ytserv or no control file"; summary; }
PREV_V="$("$OLD_YTS" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$PREV_V" ] || PREV_V="$(basename "$PREV" | sed 's/^yt-cluster_\([0-9][0-9.]*[0-9]\).*/\1/')"
echo "  1.20 package: $(basename "$PREV") ($(basename "$OLD_SO"), ytserv)"

# put_file <local file> <node> <path in the container>
put_file() {
	if [ "$YX_HOST" = local ]; then docker cp "$1" "$2:$3"
	else scp -q "$1" "$YX_HOST:/tmp/yx-mixed.$2" && rh "docker cp /tmp/yx-mixed.$2 $2:$3; rm -f /tmp/yx-mixed.$2"; fi
}
lt() { info "$LN" I "$1"; }
wrote() { # wrote <node> <what> <sql>: the write's errors said, as a failed check
	local o; o="$(qe "$1" "$3")"
	case "$o" in *ERROR*|*FATAL*) bad "$2: $(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')" ;; esac
}
row_on() { q "$1" "select v from t_lite where id=$2"; }
# arrived <id> <value> <node...>: how many of the nodes hold the row, after waiting for all
arrived() {
	local id="$1" v="$2" c n; shift 2
	for _ in $(seq 1 45); do
		c=0; for n in "$@"; do [ "$(row_on "$n" "$id")" = "$v" ] && c=$((c + 1)); done
		[ "$c" = "$#" ] && break; sleep 2
	done
	echo "$c"
}
ready() { # ready <node>: its PostgreSQL answers, and the cluster settled again
	for _ in $(seq 1 90); do [ "$(q "$1" "select 1")" = 1 ] && break; sleep 2; done
	await_clusters
}
# writable <node>: a write there commits - a node restarted refuses one until it joined
# again ("not joined cluster yet"); a probe row each try, all of them taken out after
writable() {
	local i o
	for i in $(seq 1 60); do
		o="$(qe "$1" "begin; insert into t_lite values ($((-1000 - i)), 'probe'); select yt_complete(true); commit;")"
		case "$o" in
			*ERROR*|*FATAL*) sleep 2 ;;
			*) qe "$1" "begin; delete from t_lite where id < 0; select yt_complete(true); commit;" >/dev/null; return 0 ;;
		esac
	done
	echo "     $1 takes no write in 120 s: $(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')"
	return 1
}
# restore: 1.21's library on A and ytserv on B again, from the copies kept in each
# container, the lite node's hosts as they were, the three restarted. Once; nothing to do
# before anything was swapped.
restore() {
	[ -n "$SWAPPED" ] || return 0
	SWAPPED=""
	# a copy beside it, then renamed over it: a cp onto the running ytserv fails (text file
	# busy), and one onto the library PostgreSQL has mapped would change it under it
	rh "docker exec $A sh -c 'test -f /tmp/yt_cluster.so.now && cp /tmp/yt_cluster.so.now $PKGLIB/yt_cluster.so.new \
			&& mv -f $PKGLIB/yt_cluster.so.new $PKGLIB/yt_cluster.so'; \
		docker exec $B sh -c 'test -f /tmp/ytserv.now && cp /tmp/ytserv.now /usr/local/bin/yt-cluster/ytserv.new \
			&& mv -f /usr/local/bin/yt-cluster/ytserv.new /usr/local/bin/yt-cluster/ytserv'; true"
	cfg_write "$LN" upper L "$HOSTS0" || true
	rh "docker restart $A $B $LN >/dev/null; true"
}

# ── what 85_lite.sh left: the lite node approved, t_lite everywhere ──────────
await_clusters
in_cluster upper
UL="$L"
[ -n "$UL" ] || { bad "the upper cluster has no leader"; summary; }
case "$(lt link_tls)" in *"calls are TLS"*) ;; *) bad "the lite node $LN is not linked (run 85_lite.sh first): $(lt link_tls)"; summary ;; esac
# (not OTHERS: env.sh has that name, an az's neighbours)
FOLLOWERS=(); for n in "${CL_UPPER[@]}"; do [ "$n" = "$UL" ] || FOLLOWERS+=("$n"); done
A="${FOLLOWERS[0]}"; B="${FOLLOWERS[1]}"
HOSTS0="$(q "$LN" "select value from $YX_CFG where module='L' and name='upper'")"
echo "  leader $UL; 1.20 library on $A (M1), 1.20 ytserv on $B (M2); the lite node's hosts: $HOSTS0"
PKGLIB="$(rh "docker exec $A pg_config --pkglibdir")"

# ── a rerun on this fixture: the rows of a run before taken out first ─────────
# Their ids are fixed (one per check), so a second run's inserts met them (duplicate key).
# A delete on a node that holds one goes to every other node: the lite node first (its own
# rows are read-only copies on the upper nodes), then each node that still holds one, its
# delete given time to arrive before the next is looked at.
MINE="101,102,103,201,209,211,212,213,301,302,401"
left_on() { local n c=""; for n in "$LN" "${CL_UPPER[@]}"; do [ "$(q "$n" "select count(*) from t_lite where id in ($MINE)")" = 0 ] || c="$c $n"; done; echo "${c# }"; }
held="$(left_on)"
if [ -n "$held" ]; then
	echo "  a run before left its rows on: $held"
	for _ in 1 2 3 4 5 6; do
		n="${held%% *}"
		# a run before restarted nodes at its end (restore): a node takes the delete once it
		# joined again ("not joined cluster yet"), and a node's write can fail for a moment
		# ("yt_complete: not connected", seen on 2026-11-14): tried again, as writable does
		writable "$n" || true
		# its rows may be gone meanwhile, with the delete of a node before it: a transaction
		# that changes nothing is refused by yt_complete on a cluster node ("not connected")
		if [ "$(q "$n" "select count(*) from t_lite where id in ($MINE)")" != 0 ]; then
			for i in $(seq 1 30); do
				o="$(qe "$n" "begin; delete from t_lite where id in ($MINE); select yt_complete(true); commit;")"
				case "$o" in *ERROR*|*FATAL*) sleep 2 ;; *) break ;; esac
			done
			case "$o" in *ERROR*|*FATAL*) bad "the rows of a run before taken out on $n: $(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')" ;; esac
		fi
		was="$held"
		for _ in $(seq 1 30); do held="$(left_on)"; [ "$held" != "$was" ] && [ "${held%% *}" != "$n" ] && break; sleep 2; done
		[ -z "$held" ] && break
	done
	[ -z "$held" ] && ok "the rows of a run before are gone from every node" \
		|| { bad "the rows of a run before are still on: $held"; summary; }
fi

# ── M1 1.20's library under 1.21's ytserv ────────────────────────────────────
[ -n "$PKGLIB" ] || { bad "pg_config on $A names no library directory"; summary; }
rh "docker exec $A cp $PKGLIB/yt_cluster.so /tmp/yt_cluster.so.now"
SWAPPED=1
put_file "$OLD_SO" "$A" "$PKGLIB/yt_cluster.so"
rh "docker restart $A >/dev/null"
ready "$A"
check "M1 $A's PostgreSQL loaded 1.20's library (yt_info T version)" "$OLD_EXT" "$(info "$A" T version)"
check "M1 ...under 1.21's ytserv (yt_info E version)" "$(tr -d ' \n' < "$LITE_ROOT/VERSION")" "$(info "$A" E version)"
writable "$A" && ok "M1 $A joined the cluster again: it takes writes" || bad "M1 $A takes no write after its restart"
wrote "$A" "M1 the write on $A" "begin; insert into t_lite values (101,'old-lib'); select yt_complete(true); commit;"
check "M1 a row written on $A (1.20 library) reached the other upper nodes and the lite node" "3" \
	"$(arrived 101 old-lib "$UL" "$B" "$LN")"
wrote "$UL" "M1 the write on $UL" "begin; insert into t_lite values (102,'to-old-lib'); select yt_complete(true); commit;"
wrote "$LN" "M1 the lite node's write" "begin; insert into t_lite values (103,'lite-to-old-lib'); select yt_complete(true); commit;"
check "M1 rows of the leader and of the lite node reached $A" "1" "$(arrived 102 to-old-lib "$A")"
check "M1 ...the lite node's too" "1" "$(arrived 103 lite-to-old-lib "$A")"

# ── M2 1.20's ytserv over 1.21's library, beside 1.21 nodes ───────────────────
rh "docker exec $B cp /usr/local/bin/yt-cluster/ytserv /tmp/ytserv.now"
put_file "$OLD_YTS" "$B" /usr/local/bin/yt-cluster/ytserv
rh "docker restart $B >/dev/null"
ready "$B"
check "M2 $B runs 1.20's ytserv (yt_info E version)" "$PREV_V" "$(info "$B" E version)"
check "M2 ...over 1.21's library (yt_info T version)" "$(tr -d ' \n' < "$LITE_ROOT/VERSION" | cut -d. -f1,2)" "$(info "$B" T version)"
in_cluster upper
check "M2 the upper cluster has one leader again, $UL or another" "1" "$( [ -n "$L" ] && echo 1 || echo 0)"
UL="${L:-$UL}"
writable "$B" && ok "M2 $B joined the cluster again: it takes writes" || bad "M2 $B takes no write after its restart"
wrote "$B" "M2 the write on $B" "begin; insert into t_lite values (201,'old-ytserv'); select yt_complete(true); commit;"
check "M2 a row written on $B (1.20 ytserv) reached the other upper nodes and the lite node" "3" \
	"$(arrived 201 old-ytserv "$UL" "$A" "$LN")"
# ids 211, 212, 213: one for each upper node by its number
for n in "${CL_UPPER[@]}"; do [ "$n" = "$B" ] || { wrote "$n" "M2 the write on $n" \
	"begin; insert into t_lite values ($((210 + ${n#u})),'to-old-ytserv-$n'); select yt_complete(true); commit;"; }; done
for n in "${CL_UPPER[@]}"; do [ "$n" = "$B" ] || check "M2 a row written on $n reached $B" "1" \
	"$(arrived "$((210 + ${n#u}))" "to-old-ytserv-$n" "$B")"; done
wrote "$LN" "M2 the lite node's write" "begin; insert into t_lite values (209,'lite-to-old-ytserv'); select yt_complete(true); commit;"
check "M2 the lite node's row reached $B" "1" "$(arrived 209 lite-to-old-ytserv "$B")"

# ── M3 yt-lite with the 1.20 node first in its hosts ────────────────────────
first="http://$B:$YX_PORT"
rest=""; for h in ${HOSTS0//,/ }; do [ "$h" = "$first" ] || rest="${rest:+$rest,}$h"; done
T3="$(rh "date -u +%Y-%m-%dT%H:%M:%SZ")"
cfg_write "$LN" upper L "$first,$rest"
rh "docker restart $LN >/dev/null"
for _ in $(seq 1 60); do case "$(lt link_tls)" in *"calls are TLS"*) [ "$(lt hosts_above)" != "" ] && break ;; esac; sleep 2; done
said="$(rh "docker logs --since $T3 $LN 2>&1 | grep -a 'YT-E077' | head -1" || true)"
case "$said" in *"$B"*"Link"*) ok "M3 yt-lite says $B has no Link service: $(printf '%s' "$said" | grep -o 'YT-E077.*' | cut -c1-150)" ;;
	*) bad "M3 yt-lite logged no YT-E077 for $B since its restart: [$said]" ;; esac
wrote "$UL" "M3 the write on $UL" "begin; insert into t_lite values (301,'past-old-node'); select yt_complete(true); commit;"
check "M3 ...it signed in through the next node: a row comes down" "1" "$(arrived 301 past-old-node "$LN")"
wrote "$LN" "M3 the lite node's write" "begin; insert into t_lite values (302,'up-past-old-node'); select yt_complete(true); commit;"
check "M3 ...and its row reached every upper node, the 1.20 one among them" "3" "$(arrived 302 up-past-old-node "${CL_UPPER[@]}")"

# ── M4 all put back ───────────────────────────────────────────────────────────
restore
ready "$A"; ready "$B"
# ytserv answers a moment after its PostgreSQL does: its version asked until it says one
for _ in $(seq 1 30); do [ -n "$(info "$B" E version)" ] && break; sleep 2; done
check "M4 $A has 1.21's library again" "$(tr -d ' \n' < "$LITE_ROOT/VERSION" | cut -d. -f1,2)" "$(info "$A" T version)"
check "M4 $B runs 1.21's ytserv again" "$(tr -d ' \n' < "$LITE_ROOT/VERSION")" "$(info "$B" E version)"
check "M4 the lite node's hosts are as they were" "$HOSTS0" "$(q "$LN" "select value from $YX_CFG where module='L' and name='upper'")"
for _ in $(seq 1 60); do case "$(lt link_tls)" in *"calls are TLS"*) break ;; esac; sleep 2; done
in_cluster upper
UL="${L:-$UL}"
wrote "$UL" "M4 the write on $UL" "begin; insert into t_lite values (401,'all-back'); select yt_complete(true); commit;"
check "M4 a row crosses to every node and the lite node again" "3" "$(arrived 401 all-back "${FOLLOWERS[@]}" "$LN")"

summary
