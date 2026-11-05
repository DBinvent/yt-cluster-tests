#!/usr/bin/env bash
# [bridge] [skv] The etcds bridge in ytserv-all, its broker login a secret of the store
# (yt-pgxt ytserv/skv-secrets.md, "The etcds bridge in ytserv-all"; ytserv
# state/bridge.rs): one node's own bridge_* settings (`<name>@<uuid>`, through the sync
# path) send an etcd queue to an MQTT broker that requires a login. The password is a
# secret, opened in ytserv's memory when the bridge is built; the config rows hold its
# name only. Runs on ytserv-all (the build with the bridge), by hand, as 36_skv_rppd.sh:
#   ../nightly/locked.sh ./run_a.sh 36b_skv_bridge.sh
#
# ## What is asserted
#
# B1 the store on, genesis, every node approved; the broker's password put as a secret
# B2 Mosquitto on the cluster network, a login required
# B3 the bridge settings of one node: its bridge runs there - yt_info('E') `bridge` names
#    the broker with the password masked - and on no other node
# B4 a message put on the queue reaches a subscriber of the broker
# B5 the password is in no config row and in no node's log, plain or URL-encoded
# B6 a secret with a wrong password: the bridge restarts with it, the broker refuses
#    the login, and a message put meanwhile is held, not lost - it arrives once the
#    right secret is named again
# B7 a prefix under /secret/ is refused: the node serves it to no remote caller
# B8 the secret's value changed (a put), no setting: the bridge is built again with it
#    and logs in with the new password
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== skv bridge: a queue to an MQTT broker, its login a secret of the store =="
# the bridge is ytserv-all's: on the regular ytserv its settings are no settings
[ "${YX_SERVER_BIN:-ytserv-all}" = ytserv-all ] || { echo "SKIP 36b_skv_bridge.sh: the bridge is ytserv-all's, the nodes run $YX_SERVER_BIN"; exit 0; }

MQ=yx-mqtt
MQ_IMAGE="${MQ_IMAGE:-eclipse-mosquitto:2.0.22}"
# an @ in it: the URL carries it encoded (%40), as etcds decodes a login
PW="mq@${RANDOM}x${RANDOM}"
BAD="wrong${RANDOM}"
Q=bjobs

# the etcd client 93_etcd.sh stages (a fresh 10_up has none) - as 93b_etcd_upsert.sh
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
put() { # put <node> <key> <value>: a put through that node's own etcd
	rh "docker exec $1 /usr/local/bin/yxetcd $1:7421 put $2 '$3'" >/dev/null 2>&1 || echo "  WARN: put $2 via $1 failed" >&2
}

L="$(leader)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
B=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	B="$n"; break
done
U="$(node_uuid "$B")"
echo "  leader=$L  the bridge's node=$B ($U)"

# bridge_set name=value...: $B's own rows, through the sync path in one cluster commit;
# an empty value deletes the row
bridge_set() {
	local sql="begin;" kv n v
	for kv in "$@"; do
		n="${kv%%=*}"; v="${kv#*=}"
		sql="$sql delete from $YX_CFG where module='C' and name='$n@$U';"
		[ -n "$v" ] && sql="$sql insert into $YX_CFG (name,module,value) values ('$n@$U','C','$v');"
	done
	q "$L" "$sql select yt_complete(true); commit;" >/dev/null 2>&1
}
SETTINGS="bridge_queue bridge_prefix bridge_to bridge_to_secret bridge_address"
bridge_off() { local a=() s; for s in $SETTINGS; do a+=("$s="); done; bridge_set "${a[@]}"; }
# logged <node> <since> <ERE>: how many of that node's log lines since <since> match
logged() { rh "docker logs --since $2 $1 2>&1 | { grep -cE -- '$3' || true; }" | tail -1; }
# wait_log <node> <since> <ERE> [secs]: until a line matches
wait_log() {
	local i
	for i in $(seq 1 "${4:-60}"); do [ "$(logged "$1" "$2" "$3")" -gt 0 ] 2>/dev/null && return 0; sleep 1; done
	return 1
}
# the bridge's state, as yt_info('E') `bridge` says it: off, running #<n>: <what>,
# waiting: <why>, refused: <why> - n counts the bridges built, so a restart shows
bstate() { info "$1" E bridge; }
built() { bstate "$1" | sed -nE 's/^running #([0-9]+):.*/\1/p'; }
# wait_built <node> <more than> [secs]: until a bridge numbered past <more than> runs
wait_built() {
	local i n
	for i in $(seq 1 "${3:-60}"); do n="$(built "$1")"; [ -n "$n" ] && [ "$n" -gt "$2" ] && return 0; sleep 1; done
	return 1
}
got() { rh "docker exec $MQ cat /tmp/sub.log 2>/dev/null"; }
wait_got() { # wait_got <text> [secs]
	local i
	for i in $(seq 1 "${2:-60}"); do got | grep -qF -- "$1" && return 0; sleep 1; done
	return 1
}
now() { rh "date +%s" | tail -1; }

# ── B1 the store, and the password a secret ──────────────────────────────────────
skv_cleanup
if skv_setup; then ok "B1 the store on, genesis, every node approved: all hold v1"; else bad "B1 v1 not held on:$(not_holding 1)"; fi
o="$(printf '%s' "$PW" | yx "$L" --skv put bridge_pw)"
case "$o" in *"sealed under"*) ok "B1 bridge_pw put on the leader" ;; *) bad "B1 put bridge_pw: $(echo "$o" | tail -1)" ;; esac
o="$(printf '%s' "$BAD" | yx "$L" --skv put bridge_bad)"
case "$o" in *"sealed under"*) ok "B1 bridge_bad put on the leader" ;; *) bad "B1 put bridge_bad: $(echo "$o" | tail -1)" ;; esac

# ── B2 the broker: Mosquitto, a login required ──────────────────────────────────
rh "docker rm -f $MQ >/dev/null 2>&1; true"
ship_image "$MQ_IMAGE" || echo "  WARN  $MQ_IMAGE did not reach $YX_HOST"
rh "docker run -d --name $MQ --network $YX_NET $MQ_IMAGE sleep 86400 >/dev/null" 2>/dev/null || true
rh "docker exec $MQ mosquitto_passwd -b -c /mosquitto/config/passwd app '$PW'" >/dev/null 2>&1
rh "docker exec $MQ chown mosquitto:mosquitto /mosquitto/config/passwd" >/dev/null 2>&1
rh "docker exec $MQ sh -c 'printf \"listener 1883\nallow_anonymous false\npassword_file /mosquitto/config/passwd\n\" > /mosquitto/config/b.conf'" >/dev/null 2>&1
rh "docker exec -d $MQ sh -c 'mosquitto -c /mosquitto/config/b.conf > /tmp/mq.log 2>&1'" >/dev/null 2>&1
for _ in $(seq 1 30); do rh "docker exec $MQ grep -q running /tmp/mq.log" 2>/dev/null && break; sleep 1; done
rh "docker exec -d $MQ sh -c 'mosquitto_sub -h localhost -u app -P \"$PW\" -t \"#\" -v > /tmp/sub.log 2>&1'" >/dev/null 2>&1
sleep 2
anon="$(rh "docker exec $MQ sh -c 'mosquitto_pub -h localhost -t probe -m x 2>&1; echo rc=\$?'" 2>/dev/null | tail -1)"
check "B2 Mosquitto runs with a login required (an anonymous client is refused)" "1" \
	"$( [ -n "$(rh "docker exec $MQ grep running /tmp/mq.log" 2>/dev/null)" ] && [ "$anon" != "rc=0" ] && echo 1 || echo 0)"

# ── B3 one node's bridge ─────────────────────────────────────────────────────────
t0="$(now)"
b0="$(built "$B")"; b0="${b0:-0}"
bridge_set "bridge_queue=$Q" "bridge_to=mqtt://app@$MQ:1883" "bridge_to_secret=bridge_pw" "bridge_address=$Q"
WANT="queue $Q -> mqtt://app:***@$MQ:1883 address $Q"
if wait_built "$B" "$b0" 60 && case "$(bstate "$B")" in *": $WANT") true ;; *) false ;; esac; then
	ok "B3 the bridge runs on $B, its broker's password masked: $(bstate "$B")"
else
	bad "B3 no bridge on $B: [$(bstate "$B")]"
fi
others=""
for n in "${NODES[@]}"; do [ "$n" = "$B" ] && continue; [ "$(bstate "$n")" = off ] || others="$others $n=[$(bstate "$n")]"; done
check "B3 ...and on no other node (the settings are $B's own)" "" "$others"

# ── B4 a message reaches the broker ──────────────────────────────────────────────
M1="b4-$RANDOM-$RANDOM"
put "$B" "/q/$Q/producer/m1" "$M1"
if wait_got "$M1" 60; then ok "B4 a message put on /q/$Q reached the broker's subscriber: $(got | grep -F -- "$M1" | head -1)"
else bad "B4 the message did not reach the broker: sub [$(got | tail -2 | tr '\n' ' ')], $B [$(rh "docker logs --since $t0 $B 2>&1 | grep -iE 'bridge|mqtt|sending' | tail -3" | tr '\n' ' ')]"; fi

# ── B6 a wrong password: refused, the message held, delivered once it is right ───
t1="$(now)"
b1="$(built "$B")"; b1="${b1:-0}"
bridge_set "bridge_to_secret=bridge_bad"
wait_built "$B" "$b1" 60 && ok "B6 the bridge built again with bridge_bad: $(bstate "$B")" || bad "B6 no restart on $B after bridge_to_secret changed: [$(bstate "$B")]"
M2="b6-$RANDOM-$RANDOM"
put "$B" "/q/$Q/producer/m2" "$M2"
if wait_log "$B" "$t1" "mqtt://app:\\*\\*\\*@$MQ:1883: " 60; then ok "B6 the broker refused the login: $(rh "docker logs --since $t1 $B 2>&1 | grep -F "mqtt://app:***@$MQ:1883: " | tail -1" | cut -c1-200)"
else bad "B6 no refusal logged on $B: $(rh "docker logs --since $t1 $B 2>&1 | grep -iE 'bridge|mqtt' | tail -3" | tr '\n' ' ')"; fi
sleep 5
got | grep -qF -- "$M2" && bad "B6 the message went through with a wrong password" || ok "B6 the message did not go through meanwhile"
bridge_set "bridge_to_secret=bridge_pw"
wait_got "$M2" 90 && ok "B6 the right secret named again: the held message arrived, not lost" || bad "B6 the held message never arrived: sub [$(got | tail -2 | tr '\n' ' ')]"

# ── B8 a new value of the secret, no setting changed: the bridge follows it ──────
PW2="mq2@${RANDOM}x${RANDOM}"
rh "docker exec $MQ mosquitto_passwd -b /mosquitto/config/passwd app '$PW2'" >/dev/null 2>&1
rh "docker exec $MQ sh -c 'kill -HUP \$(pidof mosquitto)'" >/dev/null 2>&1
# the reload drops the clients whose password is gone, the subscriber too: a new one
rh "docker exec $MQ sh -c 'pkill mosquitto_sub; true'" >/dev/null 2>&1
rh "docker exec -d $MQ sh -c 'mosquitto_sub -h localhost -u app -P \"$PW2\" -t \"#\" -v >> /tmp/sub.log 2>&1'" >/dev/null 2>&1
sleep 2
t4="$(now)"
b4="$(built "$B")"; b4="${b4:-0}"
o="$(printf '%s' "$PW2" | yx "$L" --skv put bridge_pw)"
case "$o" in *"sealed under"*) ok "B8 bridge_pw put again, a new value" ;; *) bad "B8 put bridge_pw: $(echo "$o" | tail -1)" ;; esac
if wait_built "$B" "$b4" 60; then ok "B8 the bridge saw its secret change and was built again: $(bstate "$B")"
else bad "B8 no rebuild on $B: [$(bstate "$B")]"; fi
M3="b8-$RANDOM-$RANDOM"
put "$B" "/q/$Q/producer/m3" "$M3"
wait_got "$M3" 60 && ok "B8 a message went through with the new password" || bad "B8 no message with the new password: sub [$(got | tail -2 | tr '\n' ' ')]"

# ── B5 the password nowhere: config rows, logs ───────────────────────────────────
ENC="${PW//@/%40}"; ENC2="${PW2:-none}"; ENC2="${ENC2//@/%40}"
in_rows=0; in_logs=0
for n in "${NODES[@]}"; do
	in_rows=$((in_rows + $(q "$n" "select count(*) from $YX_CFG where value like '%$PW%' or value like '%$ENC%' or value like '%$BAD%' or value like '%${PW2:-none}%' or value like '%$ENC2%'")))
	in_logs=$((in_logs + $(rh "docker logs $n 2>&1 | { grep -cF -e '$PW' -e '$ENC' -e '$BAD' -e '${PW2:-none}' -e '$ENC2' || true; }" | tail -1)))
done
check "B5 the passwords are in no config row on any node" "0" "$in_rows"
check "B5 ...and in no node's log, plain or URL-encoded" "0" "$in_logs"

# ── B7 a prefix under /secret/ is refused ────────────────────────────────────────
t2="$(now)"
bridge_set "bridge_queue=" "bridge_prefix=/secret/" "bridge_address="
if wait_log "$B" "$t2" '\[bridge\].*serves to no remote caller' 60; then ok "B7 a prefix under /secret/ refused: $(rh "docker logs --since $t2 $B 2>&1 | grep -F '[bridge]' | tail -1" | cut -c1-200)"
else bad "B7 /secret/ not refused on $B: $(rh "docker logs --since $t2 $B 2>&1 | grep -iE 'bridge' | tail -3" | tr '\n' ' ')"; fi
case "$(bstate "$B")" in "refused: "*"serves to no remote caller"*) ok "B7 ...and no bridge of it runs: $(bstate "$B" | cut -c1-120)" ;; *) bad "B7 the bridge's state: [$(bstate "$B")]" ;; esac

# ── cleanup ──────────────────────────────────────────────────────────────────────
t3="$(now)"
bridge_off
for _ in $(seq 1 30); do [ "$(bstate "$B")" = off ] && break; sleep 1; done
check "the bridge is off once its settings are gone" "off" "$(bstate "$B")"
rh "docker rm -f $MQ >/dev/null 2>&1; true"
skv_cleanup
summary
