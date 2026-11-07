#!/usr/bin/env bash
# [etcd-upsert] etcd into Postgres without rppd: a queue's messages and the puts
# under a key prefix, upserted into tables by the regular ytserv
# (ytserv/src/state/etcd_upsert.rs) - no Python on the way.
#
#   F feed./q/up_o = public.up_o:id
#   F feed./up/u/  = public.up_u:id
#
# Driven from outside, through an ordinary etcd client (yxetcd, as 93_etcd.sh),
# on a node that is not the leader: a queue is consumed by every node (its
# dispatcher hands each message to one), a prefix's puts applied by the leader.
#
#   U1 the routes run: yt_info('E') etcd_upsert counts two
#   U2 a queue message's object lands in its table, on every node (a synced table)
#   U3 an array lands too, and an update changes only the columns it carries
#   U4 a value that cannot go in (not JSON) is rejected, and the queue goes on
#   U5 a put under the prefix is upserted; a put outside it is not
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== etcd upsert: a queue and a prefix into tables, no rppd =="

# the etcd client 93_etcd.sh stages (a fresh 10_up has none)
have=0
for n in "${NODES[@]}"; do rh "docker exec $n test -x /usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1)); done
if [ "$have" -lt "${#NODES[@]}" ]; then
	YXETCD_SRC="${YXETCD_SRC:-$REPO_ROOT/../etcd/target/release/examples/yxetcd}"
	[ -x "$YXETCD_SRC" ] || { bad "yxetcd is on $have of ${#NODES[@]} nodes and there is no binary at $YXETCD_SRC"; summary; }
	STAGE=/tmp/yxetcd-stage
	if [ "$YX_HOST" = "local" ]; then cp "$YXETCD_SRC" "$STAGE"; else scp -q "$YXETCD_SRC" "$YX_HOST:$STAGE"; fi
	have=0
	for n in "${NODES[@]}"; do rh "docker cp $STAGE $n:/usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1)); done
fi
check "the yxetcd client is on every node" "${#NODES[@]}" "$have"

# put_json <node> <key> <value>: a put through that node's own etcd; the value
# single-quoted on the docker host, so it holds no single quote
put_json() {
	rh "docker exec $1 /usr/local/bin/yxetcd $1:7421 put $2 '$3'" >/dev/null 2>&1 || echo "  WARN: put $2 via $1 failed" >&2
}
# wait_val <node> <sql> <want> [secs]: what the query gives, once it is <want> or
# the time is up
wait_val() {
	local i v=""
	for i in $(seq 1 "${4:-60}"); do
		v="$(q "$1" "$2")"
		[ "$v" = "$3" ] && break
		sleep 1
	done
	echo "$v"
}

# ── setup: two synced tables and the routes into them ─────────────────────────
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists up_o; create table up_o (id int primary key, qty int, note text default 'n');
	        drop table if exists up_u; create table up_u (id int primary key, name text);" >/dev/null
	cfg_write "$n" "feed./q/up_o" F "public.up_o:id"
	cfg_write "$n" "feed./up/u/" F "public.up_u:id"
done
register_table public.up_o ""
register_table public.up_u ""
restart_all
await_cluster
wait_writable n1 n2 up_o -1000 0 || { bad "cluster never became writable for up_o"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
B=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	B="$n"; break
done
echo "  leader=$L  producer=$B"

# ── U1 the routes run ────────────────────────────────────────────────────────
u1="$(info "$L" E etcd_upsert)"
case "$u1" in
	"2 route(s);"*) ok "U1 the leader runs both routes: $u1" ;;
	*) bad "U1 yt_info('E') etcd_upsert on $L is [${u1:-<absent>}], expected 2 route(s) - is etcd_upsert loaded?" ;;
esac

# ── U2 a queue message lands, on every node ──────────────────────────────────
put_json "$B" /q/up_o/producer/u2 '{"id":1,"qty":5}'
# applied by the node that consumed it: on every node, whichever that was
for n in "$L" "$B"; do
	check "U2 a queue message is upserted, and reaches $n" "5" "$(wait_val "$n" "select qty from up_o where id=1" 5)"
done

# ── U3 an array, then an update of one column ────────────────────────────────
put_json "$B" /q/up_o/producer/u3a '[{"id":2,"qty":7,"note":"b"},{"id":3,"qty":1}]'
check "U3 an array's objects land" "2" "$(wait_val "$L" "select count(*) from up_o where id in (2, 3)" 2)"
check "U3 a column the object does not carry takes its default" "n" "$(q "$L" "select note from up_o where id=3")"
put_json "$B" /q/up_o/producer/u3b '{"id":2,"qty":8}'
check "U3 an update changes the column it carries" "8" "$(wait_val "$L" "select qty from up_o where id=2" 8)"
check "U3 ...and leaves the one it does not as it was" "b" "$(q "$L" "select note from up_o where id=2")"

# ── U4 a value that cannot go in is rejected, and the queue goes on ──────────
put_json "$B" /q/up_o/producer/u4a 'not-json'
put_json "$B" /q/up_o/producer/u4b '{"id":4,"qty":4}'
check "U4 the message after a rejected one lands" "4" "$(wait_val "$L" "select qty from up_o where id=4" 4)"
# counted where it was consumed: any node
u4=""
for n in "${NODES[@]}"; do
	v="$(info "$n" E etcd_upsert)"
	case "$v" in *"; 0 rejected;"*|"") ;; *" rejected;"*) u4="$n: $v"; break ;; esac
done
[ -n "$u4" ] && ok "U4 the value that is not JSON is counted rejected - $u4" \
	|| bad "U4 no node counted the value that is not JSON rejected"

# ── U5 a prefix's put is upserted; one outside it is not ─────────────────────
put_json "$B" /up/u/k10 '{"id":10,"name":"x"}'
put_json "$B" /up/other/k11 '{"id":11,"name":"y"}'
check "U5 a put under the prefix is upserted" "x" "$(wait_val "$L" "select name from up_u where id=10" x)"
check "U5 ...and reaches $B: a synced table" "x" "$(wait_val "$B" "select name from up_u where id=10" x 30)"
check "U5 ...and a put outside it is not" "0" "$(q "$L" "select count(*) from up_u where id=11")"

# ── U8 a route added with no restart ────────────────────────────────────
for n in "${NODES[@]}"; do cfg_write "$n" "feed./q/up_o2" F "public.up_o:id"; done
for n in "${NODES[@]}"; do
	for ((i = 0; i < 30; i += 2)); do v="$(info "$n" E etcd_upsert)"; case "$v" in "3 route"*) break;; esac; sleep 2; done
	case "$v" in "3 route"*) ok "U8 $n: a route added is running";; *) bad "U8 $n: [$v]";; esac
done
put_json "$B" /q/up_o2/producer/u8 '{"id":80,"qty":8}'
check "U8 its message lands" "8" "$(wait_val "$L" "select qty from up_o where id=80" 8)"
# [etcd-spare] a forever spare consumes no queue: a message it took would never land
for n in "${NODES[@]}"; do
	is_spare_node "$n" || continue
	check "U8 forever spare $n took no message it could not write" "0" \
		"$(rh "docker logs --since 15m $n 2>&1 | { grep -c 'etcd-upsert.*forever-Spare' || true; }")"
done
for n in "${NODES[@]}"; do cfg_delete "$n" "feed./q/up_o2" F; done
e="$(qe "$L" "begin; insert into $YX_CFG (name,module,value) values ('feed./up/','F','public.up_u:id'); select yt_complete(true); commit;" 2>&1 || true)"
case "$e" in *"configured already"*) ok "U9 a route overlapping another is refused";; *) bad "U9 [$e]";; esac

# ── cleanup: the routes off (pre_case restores the rest) ─────────────────────
for n in "${NODES[@]}"; do cfg_delete "$n" "feed./q/up_o" F; cfg_delete "$n" "feed./up/u/" F; done
# a delete carries no setting to apply: the rows are read, and the routes go with them
for n in "${NODES[@]}"; do
	for ((i = 0; i < 30; i += 2)); do v="$(info "$n" E etcd_upsert)"; case "$v" in "0 route"*) break;; esac; sleep 2; done
	case "$v" in "0 route"*) ok "U6 $n: the routes went with their rows";; *) bad "U6 $n: [$v]";; esac
done
e="$(qe "$L" "begin; insert into $YX_CFG (name,module,value) values ('etcd_upsert','C','/q/x=t:id'); select yt_complete(true); commit;" 2>&1 || true)"
case "$e" in *"module F"*) ok "U7 the old C row refused, saying where it went";; *) bad "U7 [$e]";; esac

summary
