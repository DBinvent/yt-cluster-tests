#!/usr/bin/env bash
# [lite] A lite node on the upper cluster: yt-lite (yt-cluster-lite, yt-core) beside
# one PostgreSQL, a leaf of that cluster. It has no az - it is no cluster, leads nothing,
# has nothing below it - so nothing declares one for it: no `Z` row, no `--link-lower`.
# The cluster runs on the store and TLS (H2); the lite node pins the cluster's CA
# (`ytctl --skv-status`, `ca v<n>`) and signs in with a CA of its own, the operator
# approves that CA with the fingerprint yt-lite logged, and the cluster countersigns it.
# From then on its fetch and deliver calls are TLS. The node it signed in through takes
# it for a node of its own az, `top`: a routed table that az holds crosses both ways, a
# table with no az rule never does.
#
# Needs 15_store.sh (the upper on the store and TLS, TLS required); 80_skv_link_tls.sh
# before it changes nothing here - the root is the upper's newest CA, whatever version.
# The lite node is container l1, from this fixture's image: the deb ships yt-lite at
# /usr/local/bin/yt-cluster/yt-lite, and the node entrypoint runs it in place of ytserv
# (YT_SERVER_BIN=yt-lite). YT_LITE_BIN: a yt-lite binary of this host to copy in
# instead, for a run against an image built before it.
#
# ## What is asserted
#
# L1 `ytctl --skv-status` on the upper leader prints the cluster's CA, the root to pin;
#    no `Z` row names the lite node, before it starts and after it is admitted
# L2 the lite node signs in with its CA and is refused until the operator approves it;
#    the upper holds it for approval under the lite node's uuid
# L3 the operator approves it with the fingerprint the lite node shows (yt_info
#    ca_fingerprint); an approval naming another key is refused
# L4 the upper countersigns the lite node's CA: yt_info link_tls says TLS, and the
#    upper recorded the approval (K ca:<uuid>); the lite node is told the az it is
#    taken to be in - `top`, the node's it signed in through - and an upper node lists
#    it as a lite node (yt_info E `lite`), in no roster
# L5 a plaintext Link call from the lite node's host to an upper node is refused
#    (peer_tls): TLS is what lets it in
# L6 down: a row the upper commits to a routed table its az holds reaches the lite
#    node; a row of a table with no az rule does not; a row of a routed table the lite
#    node does not have is skipped there and counted, and holds nothing back
# L7 up: a row the lite node commits reaches every upper node; a row it commits to a
#    table with no az rule is not taken
# L8 a restart of yt-lite keeps its CA: rows cross again, no new approval asked
# L9 a table syncs on the lite node as on a cluster node, by its A row: a routed table it
#    has with none takes nothing from above (rows_not_synced_here); with one written, the
#    next row comes down
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../topology/skv_lib.sh"
echo "== lite: yt-lite below the upper cluster, admitted by its CA, rows both ways over TLS =="

LN=l1
# A run again on the same fixture takes another uuid: the upper holds the first one's
# approval, and a new container's CA is another key (refused there, as it should be)
LUUID="${YX_LITE_UUID:-dddddddd-dddd-4ddd-8ddd-dddddddddddd}"
TBL=public.t_lite
ALL=("${NODES[@]}")

await_clusters
in_cluster upper
UL="$L"
[ -n "$UL" ] || { bad "the upper cluster has no leader"; summary; }
case "$(required_line "$UL")" in "TLS between members required:"*) ;;
	*) bad "the upper does not require TLS - 15_store.sh sets the hierarchy up: $(required_line "$UL")"; summary ;; esac

# ── L1 the cluster's CA, and nothing declared for the lite node ────────────
# the newest CA the upper holds (yt_info X `@ca/<n>`), and `ytctl --skv-status` printing it
CAV="$(q "$UL" "select yt_info('X')" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
v = [int(r['name'][4:]) for r in rows if r.get('name', '').startswith('@ca/') and r['name'][4:].isdigit()]
print(max(v) if v else '')")"
ROOT="$(info "$UL" X "@ca/$CAV")"
o="$(yx "$UL" --skv-status)"
case "$ROOT" in SHA256:*) ;; *) bad "L1 the upper leader $UL holds no CA (yt_info X @ca/$CAV: [$ROOT])"; summary ;; esac
# a row of its status, as ytctl prints them: `<name> = <value>`
case "$o" in *"ca v$CAV = $ROOT"*) ok "L1 ytctl --skv-status on the upper leader $UL prints its CA v$CAV, the root to pin: $ROOT" ;;
	*) bad "L1 --skv-status does not print ca v$CAV $ROOT: $(echo "$o" | grep -a 'ca v' | tr '\n' ' ')" ;; esac
zrows() { q "$UL" "select count(*) from $YX_CFG where module='Z' and name like '$LUUID%'"; }
check "L1 no Z row names the lite node: it is no az, and nothing declares one for it" "0" "$(zrows)"

# three tables, on the upper's nodes only - east and west are not in its az (named, not
# left to in_cluster's NODES):
#   t_lite  routed, held by the upper's az `top`: crosses to its lite nodes, both ways
#   t_other  routed the same, and not on the lite node: skipped there
#   t_plain  no az rule at all: the cluster's own, never crosses
CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg "az=top" 2>/dev/null | tail -1)"
[ -n "$CFG" ] || { bad "--encode-table-cfg az=top produced nothing"; summary; }
NODES=("${CL_UPPER[@]}")
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists t_lite; create table t_lite (id bigint primary key, v text);
	        drop table if exists t_other; create table t_other (id bigint primary key, v text);
	        drop table if exists t_plain; create table t_plain (id bigint primary key, v text);
	        drop table if exists t_nosync; create table t_nosync (id bigint primary key, v text);" >/dev/null
done
register_table "$TBL" "$CFG"
register_table public.t_nosync "$CFG"
register_table public.t_other "$CFG"
register_table public.t_plain
NODES=("${ALL[@]}")
restart_all 30
await_clusters
in_cluster upper
UL="$L"

# ── the lite node ───────────────────────────────────────────────────────────
T0="$(rh "date -u +%Y-%m-%dT%H:%M:%SZ")"
rh "docker rm -f $LN >/dev/null 2>&1; true"
rh "docker run -d --name $LN --hostname $LN --network $YX_NET -e NODE_UUID=$LUUID -e DB=$YX_DB -e CFG_TABLE=$YX_CFG \
	-e YT_SERVER_BIN=yt-lite $YX_IMAGE >/dev/null"
up=0
for _ in $(seq 1 90); do [ "$(q "$LN" "select 1 from pg_tables where schemaname='public' and tablename='yt_config'")" = 1 ] && { up=1; break; }; sleep 2; done
# said, not passed over: every check after it would fail for another reason (review of 2026-11-13)
[ "$up" = 1 ] || { bad "the lite node's PostgreSQL and its config table did not come up in 180 s: $(rh "docker logs $LN 2>&1 | tail -3" | tr '\n' ' ')"; summary; }
if [ -n "${YT_LITE_BIN:-}" ]; then
	if [ "$YX_HOST" = local ]; then docker cp "$YT_LITE_BIN" "$LN:/usr/local/bin/yt-cluster/yt-lite"
	else scp -q "$YT_LITE_BIN" "$YX_HOST:/tmp/yt-lite.$LN" && rh "docker cp /tmp/yt-lite.$LN $LN:/usr/local/bin/yt-cluster/yt-lite; rm -f /tmp/yt-lite.$LN"; fi
fi
rh "docker exec $LN test -x /usr/local/bin/yt-cluster/yt-lite" \
	|| { bad "no yt-lite in $LN (/usr/local/bin/yt-cluster/yt-lite): an image from a deb before it - YT_LITE_BIN copies one in"; summary; }
hosts=""; for n in "${CL_UPPER[@]}"; do hosts="${hosts:+$hosts,}http://$n:$YX_PORT"; done
# no az among its settings: a lite node has none
cfg_write "$LN" uuid L "$LUUID"
cfg_write "$LN" upper L "$hosts"
cfg_write "$LN" upper_root L "$ROOT"
cfg_write "$LN" cfg_ready C 1
lt() { info "$LN" I "$1"; }
for _ in $(seq 1 60); do [ -n "$(lt ca_fingerprint)" ] && break; sleep 2; done
FP="$(lt ca_fingerprint)"
[ -n "$FP" ] || { bad "yt-lite on $LN did not come up: $(rh "docker logs $LN 2>&1 | tail -5" | tr '\n' ' ')"; summary; }
# its tables: t_lite and t_plain, both captured - t_other is not here
q "$LN" "create table t_lite (id bigint primary key, v text); select yt_setup('$TBL');
         create table t_plain (id bigint primary key, v text); select yt_setup('public.t_plain');
         create table t_nosync (id bigint primary key, v text);" >/dev/null
check "yt_setup on the lite node put its trigger on $TBL" "1" \
	"$(q "$LN" "select count(*) from pg_trigger where tgrelid='$TBL'::regclass and tgname like 'zytsync%' and tgname not like 'zytsynct%'")"

# ── L2 refused until approved, held for approval ────────────────────────────
pend() { q "$UL" "select count(*) from $YX_CFG where module='J' and name='$LUUID' and value like 'pending:%'"; }
for _ in $(seq 1 45); do [ "$(pend)" -ge 1 ] 2>/dev/null && break; sleep 2; done
check "L2 the upper leader holds the lite node's CA for approval" "1" "$(pend)"
said="$(rh "docker logs --since $T0 $LN 2>&1 | grep -a 'awaits approval' | tail -1" || true)"
case "$said" in *"--skv-approve $LUUID --fingerprint $FP"*) ok "L2 the lite node is refused until approved, and says the line to run" ;;
	*) bad "L2 the lite node logged no refusal naming --skv-approve $LUUID --fingerprint $FP: [$said]" ;; esac

# ── L3 the approval ──────────────────────────────────────────────────────────
# another key: the upper's own CA's fingerprint (a real one, never the lite node's)
other="$(info "$UL" X @ca/1 2>/dev/null)"
[ -n "$other" ] && [ "$other" != "$FP" ] || other="SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
o="$(yx "$UL" --skv-approve "$LUUID" --fingerprint "$other" --yes)"
# ytctl's skv-other-key, word for word: the pending row names the lite node's key, not the one given
case "$o" in *"The pending J row of $LUUID names the key $FP, not $other - not approved"*)
		ok "L3 an approval naming another key is refused: the pending row names the lite node's key" ;;
	*) bad "L3 an approval naming another key: $(echo "$o" | tail -2 | tr '\n' ' ')" ;; esac
check "L3 ...and nothing was approved by it (no K ca:$LUUID)" "0" \
	"$(q "$UL" "select count(*) from $YX_CFG where module='K' and name='ca:$LUUID'")"
check "L3 ...and the lite node's CA still waits" "1" "$(pend)"
o="$(yx "$UL" --skv-approve "$LUUID" --fingerprint "$FP" --yes)"
# ytctl's skv-armed line, as it starts
case "$o" in *"Approved - "*) ok "L3 the operator approved the lite node's CA ($FP) on the upper leader" ;;
	*) bad "L3 the approval failed: $(echo "$o" | tail -2 | tr '\n' ' ')" ;; esac

# ── L4 countersigned: TLS ─────────────────────────────────────────────────────
for _ in $(seq 1 60); do case "$(lt link_tls)" in *"calls are TLS"*) break ;; esac; sleep 2; done
case "$(lt link_tls)" in *"calls are TLS"*) ok "L4 the lite node's CA is countersigned by the upper: $(lt link_tls)" ;;
	*) bad "L4 not countersigned: $(lt link_tls) - $(rh "docker logs $LN 2>&1 | grep -a 'link TLS\|sign-in' | tail -2" | tr '\n' ' ')" ;; esac
check "L4 the upper recorded the approval (K ca:$LUUID)" "$FP" \
	"$(q "$UL" "select value from $YX_CFG where module='K' and name='ca:$LUUID'")"
# no az of its own: told the one it is taken to be in, the node's it signed in through
for _ in $(seq 1 30); do case "$(lt az)" in top*) break ;; esac; sleep 2; done
case "$(lt az)" in "top - "*) ok "L4 the lite node is told the az it shares: $(lt az)" ;;
	*) bad "L4 the lite node's yt_info az: [$(lt az)]" ;; esac
listed=""; for n in "${CL_UPPER[@]}"; do case "$(info "$n" E lite)" in *"$LUUID"*) listed="$listed $n" ;; esac; done
[ -n "$listed" ] && ok "L4 the upper lists it as a lite node of az top (yt_info E lite) on:$listed" \
	|| bad "L4 no upper node lists the lite node (yt_info E lite)"
roster=0; for n in "${CL_UPPER[@]}"; do
	r="$(q "$n" "select count(*) from $YX_CFG where module='N' and name='$LUUID'")"; roster=$((roster + ${r:-0})); done
check "L4 ...and it is in no roster (no N row on any upper node)" "0" "$roster"
check "L4 ...and still no Z row names it" "0" "$(zrows)"

# ── L5 plaintext refused ─────────────────────────────────────────────────────
UR=""; for n in "${CL_UPPER[@]}"; do [ "$n" = "$UL" ] || { UR="$n"; break; }; done
o="$(rh "docker exec -i $LN python3 -" <<EOF 2>&1 || true
import grpc
ch = grpc.insecure_channel('$UR:$YX_PORT')
f = ch.unary_unary('/link.Link/fetch', request_serializer=lambda x: x, response_deserializer=lambda x: x)
try:
    f(b'', timeout=10)
    print('OK')
except grpc.RpcError as e:
    print(e.code().name, (e.details() or '')[:200])
EOF
)"
case "$o" in "PERMISSION_DENIED"*"peer_tls"*) ok "L5 a plaintext Link fetch from $LN to $UR is refused - TLS lets the lite node in" ;;
	*) bad "L5 plaintext fetch from $LN to $UR: $o" ;; esac

# ── L6 down ──────────────────────────────────────────────────────────────────
lite_row() { q "$LN" "select v from t_lite where id=$1"; }
# first a row of the table with no az rule, and one of the routed table the lite node
# does not have - then the one it takes: when that is there, the two before it were passed
# each write is seen committed where it was made: a row that did not cross because it was
# never written would prove nothing (review of 2026-11-13)
wrote() { # wrote <node> <what> <sql>: the write's errors said, as a failed check
	local o; o="$(qe "$1" "$3")"
	case "$o" in *ERROR*|*FATAL*) bad "$2: $(printf '%s\n' "$o" | grep -m1 -E 'ERROR|FATAL')" ;; esac
}
wrote "$UL" "L6 the upper's write to t_plain" "begin; insert into t_plain values (1,'top-only'); select yt_complete(true); commit;"
wrote "$UL" "L6 the upper's write to t_other" "begin; insert into t_other values (1,'not-there'); select yt_complete(true); commit;"
wrote "$UL" "L6 the upper's write to t_lite" "begin; insert into t_lite values (1,'from-top'); select yt_complete(true); commit;"
check "L6 the upper holds its own rows of the three tables" "top-only not-there from-top" \
	"$(q "$UL" "select (select v from t_plain where id=1) || ' ' || (select v from t_other where id=1) || ' ' || (select v from t_lite where id=1)")"
for _ in $(seq 1 45); do [ "$(lite_row 1)" = from-top ] && break; sleep 2; done
check "L6 a row the upper committed reached the lite node" "from-top" "$(lite_row 1)"
check "L6 a row of a table with no az rule did not cross (t_plain on the lite node)" "0" \
	"$(q "$LN" "select count(*) from t_plain")"
# counted as not held, or - with no A row for it there, as now - as not synced (yt-core sync.rs)
nh="$(lt rows_not_held_here)"; ns="$(lt rows_not_synced_here)"
check "L6 a row of a routed table the lite node does not have was skipped there, and counted" "1" \
	"$(( ${nh:-0} + ${ns:-0} ))"
check "L6 ...and is no error: nothing held back" "" "$(lt apply_error)"

# ── L7 up ────────────────────────────────────────────────────────────────────
o="$(qe "$LN" "begin; insert into t_lite values (2,'from-lite'); select yt_complete(true); commit;")"
case "$o" in *ERROR*) bad "L7 the lite node's write: $(printf '%s\n' "$o" | grep -m1 ERROR)" ;; esac
up_on() { local c=0 n; for n in "${CL_UPPER[@]}"; do [ "$(q "$n" "select v from t_lite where id=$1")" = "$2" ] && c=$((c + 1)); done; echo "$c"; }
for _ in $(seq 1 45); do [ "$(up_on 2 from-lite)" = "${#CL_UPPER[@]}" ] && break; sleep 2; done
check "L7 a row the lite node committed reached every upper node" "${#CL_UPPER[@]}" "$(up_on 2 from-lite)"
for _ in $(seq 1 15); do [ "$(lt outbox)" = 0 ] && break; sleep 2; done
check "L7 ...and left the lite node's outbox" "0" "$(lt outbox)"
# a table with no az rule is the cluster's own: the lite node's row of it goes up and is not taken
wrote "$LN" "L7 the lite node's write to t_plain" "begin; insert into t_plain values (9,'lite-only'); select yt_complete(true); commit;"
wrote "$LN" "L7 the lite node's next write to t_lite" "begin; insert into t_lite values (5,'after-plain'); select yt_complete(true); commit;"
check "L7 the lite node holds the row it wrote to t_plain" "lite-only" "$(q "$LN" "select v from t_plain where id=9")"
for _ in $(seq 1 45); do [ "$(up_on 5 after-plain)" = "${#CL_UPPER[@]}" ] && break; sleep 2; done
check "L7 the lite node's next row arrived (the one before it was passed)" "${#CL_UPPER[@]}" "$(up_on 5 after-plain)"
plain=0; for n in "${CL_UPPER[@]}"; do r="$(q "$n" "select count(*) from t_plain where id=9")"; plain=$((plain + ${r:-0})); done
check "L7 a row the lite node wrote to a table with no az rule was not taken on any upper node" "0" "$plain"

# ── L8 a restart keeps the CA ────────────────────────────────────────────────
T8="$(rh "date -u +%Y-%m-%dT%H:%M:%SZ")"
rh "docker restart $LN >/dev/null"
for _ in $(seq 1 60); do [ -n "$(lt ca_fingerprint)" ] && break; sleep 2; done
check "L8 yt-lite restarted with the same CA" "$FP" "$(lt ca_fingerprint)"
q "$UL" "begin; insert into t_lite values (3,'after-restart'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
q "$LN" "begin; insert into t_lite values (4,'up-after-restart'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
for _ in $(seq 1 45); do [ "$(lite_row 3)" = after-restart ] && [ "$(up_on 4 up-after-restart)" = "${#CL_UPPER[@]}" ] && break; sleep 2; done
check "L8 after the restart a row comes down" "after-restart" "$(lite_row 3)"
check "L8 ...and one goes up" "${#CL_UPPER[@]}" "$(up_on 4 up-after-restart)"
check "L8 ...with no approval asked again" "0" "$(pend)"
# nothing pending could also mean nothing was ever asked: the approval of the first start is the one in force
check "L8 ...the approval of its first start still the one recorded (K ca:$LUUID)" "$FP" \
	"$(q "$UL" "select value from $YX_CFG where module='K' and name='ca:$LUUID'")"
# `; true`: grep -c counting none exits 1, and an `|| echo 0` after it said 0 twice
n8="$(rh "docker logs --since $T8 $LN 2>&1 | grep -ac 'awaits approval'; true")"
check "L8 ...and no refusal since the restart" "0" "${n8:-0}"

# ── L9 a table syncs by its A row ────────────────────────────────────────────
check "L9 t_nosync is on the lite node, with no A row" "0" \
	"$(q "$LN" "select count(*) from $YX_CFG where module = 'A' and name = 'public.t_nosync'")"
ns0="$(lt rows_not_synced_here)"
wrote "$UL" "L9 the upper's write to t_nosync" "begin; insert into t_nosync values (1,'no A row there'); select yt_complete(true); commit;"
# a row of t_lite after it: when that is here, the one before it was passed
wrote "$UL" "L9 the upper's next write to t_lite" "begin; insert into t_lite values (91,'after nosync'); select yt_complete(true); commit;"
for _ in $(seq 1 45); do [ "$(lite_row 91)" = "after nosync" ] && break; sleep 2; done
check "L9 the row after it came down (t_lite)" "after nosync" "$(lite_row 91)"
check "L9 ...and t_nosync took nothing" "0" "$(q "$LN" "select count(*) from t_nosync")"
[ "$(lt rows_not_synced_here)" -gt "${ns0:-0}" ] 2>/dev/null && ok "L9 ...counted: rows_not_synced_here $(lt rows_not_synced_here)" \
	|| bad "L9 rows_not_synced_here did not grow: [${ns0}] -> [$(lt rows_not_synced_here)]"
cfg_write "$LN" public.t_nosync A ""
sleep 3   # yt-lite reads the A rows again after 2 s
wrote "$UL" "L9 the upper's write to t_nosync, its A row there" "begin; insert into t_nosync values (2,'A row there'); select yt_complete(true); commit;"
for _ in $(seq 1 45); do [ "$(q "$LN" "select v from t_nosync where id=2")" = "A row there" ] && break; sleep 2; done
check "L9 with its A row, the next row of t_nosync came down" "A row there" "$(q "$LN" "select v from t_nosync where id=2")"

summary
