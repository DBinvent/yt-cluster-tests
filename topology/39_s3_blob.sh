#!/usr/bin/env bash
# [s3] Blobs of synced tables, one way, into an S3 store (yt-pgxt s3.md, s3_dm.md), on RustFS.
#
# ## What is asserted
#
# S1 a setting that holds a key, or is wrong, is refused; no store and no secret: nothing happens
# S2 `move`: the commit means S3 has it, byte for byte, under the key built from the row; the
#    column NULL on every node; a NOT NULL column holds one zero byte; a large blob goes in parts
# S3 `move`: an UPDATE leaving the blob alone sends nothing; a NULL is a zero-size object; a
#    write that rolls back leaves no object
# S4 `move` with the store down: the statement fails, nothing saved; wrong keys: the same
# S5 `quick`: with the store down the commit still returns; the file waits, and goes when the
#    store is back; a rollback sends nothing; tickets say received, then complete
# S6 `quick`: ytserv killed with the file waiting: it is taken up again
# S7 `copy`: the column keeps the blob on every node, the object follows; an UPDATE replaces
#    it; a DELETE leaves it
# S8 `copy`: the node that wrote it down with the store down: the leader sends it
# S9 rows that were there before a mode was turned on go too
# S10 a directory this node cannot use: refused and said, and writes go on as `sync`
# S11 a 10 MB row replicates, on `sync` and on `copy`: the 4 MB message cap is gone
# S12 what must not reach the store: a key already there (a plain INSERT, ON CONFLICT DO NOTHING),
#     a savepoint rolled back; and from SQL the handover is refused
# S13 an application's role with no rights but to insert: its writes go, in `move` and `copy`
# S14 a mode turned off, and the store's setting gone: the triggers go, and writes keep the blob
# S15 a table dropped and made again gets its trigger back; a directory with a trailing /
# S16 a restore: a moved row written back, its NULL or its zero byte, leaves the object alone
# S17 a rollback, then the same key again on this node, still open past the wait: the object stays
# S18 a directory open to others where the files go is refused; a partitioned table is too
# S19 a key's text does not depend on the session: DateStyle, TimeZone
# S20 a moved NOT NULL column turned to `copy`: its marker does not replace the object
# S21 a rollback, and a member holds a row of that key: the object stays
# S22 a rollback, and another node's write under way: its object stays
# S23 a mode off and on again: the rows written between go; a row a trigger missed is found later
# S24 an old row's key has another's object: it is not replaced until that write's time is out and
#     every member's row holds this value; of the same content the row just clears
# S25 an old row's upload holds no row lock
# S26 a key column that cannot name an object: a type of a user's, generated, an empty key
# S27 an UPDATE to a key already there sends nothing
# S28 two INSERTs of one new key, the second behind the first's outcome, on a key not first in the
#     table
# S29 a `copy` row that would fail again ends as failed
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== s3: blobs, one way, into an S3 store =="

# where it stopped, when a helper stops the script
set -E
trap 'echo "  stopped at line $LINENO: $BASH_COMMAND" | cut -c1-200 >&2' ERR

S3=yx-s3
S3_IMAGE="${S3_IMAGE:-rustfs/rustfs:1.0.2}"
AK=s3testaccess
SK=s3testsecret123
BUCKET=blobs
PUB=public
TABLES="s3_m s3_n s3_q s3_c s3_old s3_oldc s3_big s3_bigc s3_dir s3_role s3_rolec s3_again s3_part s3_date s3_ts s3_onoff s3_stale s3_lock s3_enum s3_gen s3_two s3_cpk"

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done

qx() { # qx <node> <sql> -> psql's output WITH its errors
	printf '%s\n' "$2" | rh "docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=120s' $1 \
psql -X -tAq -v ON_ERROR_STOP=1 -d $YX_DB 2>&1" 2>&1 || true
}
err_of() { printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|Error response from d' || true; }; }
cw() { err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;")"; }
leader_now() {
	local n
	for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) echo "$n"; return;; esac; done
}
# the store, from a node: <what curl prints> for <key>
s3curl() { rh "docker exec $O curl -s -m 60 --aws-sigv4 'aws:amz:us-east-1:s3' --user $AK:$SK $*" 2>/dev/null || true; }
obj_code() { s3curl "-o /dev/null -w '%{http_code}' http://$S3:9000/$BUCKET/$1"; }
obj_size() { s3curl "-o /dev/null -w '%{size_download}' http://$S3:9000/$BUCKET/$1"; }
obj_sha()  { rh "docker exec $O sh -c \"curl -s -m 60 --aws-sigv4 'aws:amz:us-east-1:s3' --user $AK:$SK http://$S3:9000/$BUCKET/$1 | sha256sum | cut -d' ' -f1\"" 2>/dev/null || true; }
key_of() { printf '%s/%s/%s/%s/%s' "$YX_DB" "$PUB" "$1" "$2" "$3"; }
obj_wait() { # obj_wait <key> <code> <seconds>: until the store answers so
	local i
	for ((i = 0; i < $3; i += 2)); do [ "$(obj_code "$1")" = "$2" ] && return 0; sleep 2; done
	return 1
}
sha_of() { q "$O" "select encode(sha256($1), 'hex')"; }
s3_up() { rh "docker start $S3 >/dev/null" 2>/dev/null; local i; for ((i = 0; i < 30; i += 1)); do [ "$(s3curl "-o /dev/null -w '%{http_code}' http://$S3:9000/$BUCKET/")" != "000" ] && return 0; sleep 1; done; return 1; }
s3_down() { rh "docker stop -t 1 $S3 >/dev/null" 2>/dev/null; }
blob_cfg() { "$REPO_ROOT"/target/release/ytctl --encode-table-cfg "$1" | tail -1; }
table_new() { # table_new <table> <columns>: on every node, registered with its config
	local n
	for n in "${NODES[@]}"; do q "$n" "drop table if exists $1; create table $1 ($2)" >/dev/null; done
	register_table "$PUB.$1" "$3"
}
trigger_on() { # trigger_on <table> <name>: on every node, or the nodes it is not on
	local i n left
	for ((i = 0; i < 45; i += 3)); do
		left=""
		for n in "${NODES[@]}"; do [ "$(q "$n" "select count(*) from pg_trigger where tgrelid = '$PUB.$1'::regclass and tgname = '$2'")" = 1 ] || left="$left $n"; done
		[ -z "$left" ] && return 0
		sleep 3
	done
	echo "$left"
	return 1
}
differing() { # differing <sql>: the nodes whose answer differs from the first's
	local n first out=""
	first="$(q "${NODES[0]}" "$1")"
	for n in "${NODES[@]}"; do [ "$(q "$n" "$1")" = "$first" ] || out="$out $n"; done
	printf '%s' "$out"
}
reach() { # reach <sql> <want> <seconds>: until every node answers so
	local i
	for ((i = 0; i < $3; i += 2)); do
		[ -z "$(for n in "${NODES[@]}"; do [ "$(q "$n" "$1")" = "$2" ] || echo "$n"; done)" ] && return 0
		sleep 2
	done
	return 1
}
tickets() { # tickets <node> <table> <seconds>: the tickets on its queue, each acknowledged
	rh "docker exec -i $1 python3 -" <<PY 2>&1 || true
import etcd3, json, sys, time, uuid
c = etcd3.client(host='$1', port=$YX_PORT)
key = '/q/s3:$YX_DB.$PUB.$2/c/' + str(uuid.uuid4())
events, cancel = c.watch(key)
got = []
import threading
threading.Timer($3, cancel).start()
for e in events:
    v = e.value.decode()
    if not v.startswith('{'):
        continue
    d = json.loads(v)
    print(d['state'], d.get('result', {}).get('identical'), d.get('column'), json.dumps(d.get('pk')), d.get('destination'))
    c.delete(e.key)
PY
}
cleanup() {
	set +e
	rh "docker rm -f $S3 >/dev/null" 2>/dev/null
	for n in "${NODES[@]}"; do q "$n" "drop role if exists s3_app" >/dev/null 2>&1; done
	cw "$(leader_now)" "delete from $YX_CFG where module='B'" >/dev/null
	local n t
	for n in "${NODES[@]}"; do
		for t in $TABLES; do
			q "$n" "drop table if exists $PUB.$t" >/dev/null 2>&1
			cfg_delete "$n" "$PUB.$t" A >/dev/null 2>&1 || true
		done
		q "$n" "drop table if exists $PUB.yt_s3_blob" >/dev/null 2>&1
		cfg_delete "$n" "$PUB.yt_s3_blob" A >/dev/null 2>&1 || true
		rh "docker exec $n sh -c 'rm -rf /tmp/yt-s3'" 2>/dev/null
	done
	skv_cleanup
}

await_cluster
L="$(leader_now)"
[ -n "$L" ] || { bad "no leader"; summary; }
trap cleanup EXIT
FOLLOWERS=(); for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"
echo "  leader $L, writer $O, other $F"

echo "-- the store"
ship_image "$S3_IMAGE" || echo "  WARN  $S3_IMAGE did not reach $YX_HOST"
rh "docker rm -f $S3 >/dev/null 2>&1; docker run -d --name $S3 --network $YX_NET -e RUSTFS_ACCESS_KEY=$AK -e RUSTFS_SECRET_KEY=$SK $S3_IMAGE >/dev/null" 2>/dev/null
up=""
for ((i = 0; i < 60; i += 2)); do
	up="$(s3curl "-o /dev/null -w '%{http_code}' -X PUT http://$S3:9000/$BUCKET")"
	case "$up" in 200|409) break;; esac
	sleep 2
done
case "$up" in 200|409) ok "the store answers, its bucket made";; *) bad "the store: [$up]"; summary;; esac

echo "-- S1 a setting that cannot be right"
e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('secret_key','B','abc')")"
case "$e" in *"no setting"*) ok "S1 a key in the setting refused: $(printf '%s' "$e" | cut -c1-90)";; *) bad "S1 a key in the setting: [$e]";; esac
case "$e" in *abc*) bad "S1 the refusal shows the value";; *) ok "S1b the refusal does not show the value";; esac
e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('endpoint','B','http://user:pw@$S3:9000')")"
case "$e" in *login*) ok "S1c a login in the endpoint refused";; *) bad "S1c a login in the endpoint: [$e]";; esac
check "S1d no store: nothing to say" "off" "$(info "$O" E s3)"
if skv_setup; then ok "S1e the secret store on: all hold v1"; else bad "S1e v1 not held on:$(not_holding 1)"; fi
o="$(printf '%s' "$AK:$SK" | yx "$L" --skv put s3_keys)"
case "$o" in *rror*) bad "S1f the secret: $o";; *) ok "S1f the keys are a secret";; esac
printf '%s' "wrongkey:wrongsecret" | yx "$L" --skv put s3_bad >/dev/null
sleep 3
# the store's rows of module B, given as name=value; ..., and the 2 s they may be read after
cfg_put_s3() {
	local values="" kv k v old="$IFS"
	IFS=';'
	for kv in $1; do
		k="${kv%%=*}"; k="${k// /}"; v="${kv#*=}"
		values="${values:+$values,}('$k','B','$v')"
	done
	IFS="$old"
	cw "$L" "delete from $YX_CFG where module='B'; insert into $YX_CFG (name,module,value) values $values"
	sleep 3
}
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tickets=on")"
[ -z "$e" ] && ok "S1g the store set" || bad "S1g: $e"
check "S1h the setting holds no key" "0" "$(q "$L" "select count(*) from $YX_CFG where value like '%$SK%'")"
reach "select count(*) from $YX_CFG where module='B'" 4 60 && ok "S1i one row per setting, on every node" || bad "S1i the rows are not on every node"
e="$(cw "$L" "update $YX_CFG set value='http://user:pw@$S3:9000' where module='B' and name='endpoint'")"
case "$e" in *login*) ok "S1j an UPDATE's value is checked too";; *) bad "S1j a login by UPDATE: [$e]";; esac
e="$(cw "$L" "update $YX_CFG set name='secret_key' where module='B' and name='tickets'")"
case "$e" in *"delete it and insert"*) ok "S1k an UPDATE of the name is refused";; *) bad "S1k a name by UPDATE: [$e]";; esac
e="$(cw "$O" "insert into $YX_CFG (name,module,value) values ('region','B','eu')")"
case "$e" in *leader*) ok "S1l another node's write refused: the leader's";; *) bad "S1l a follower's row: [$e]"; cw "$L" "delete from $YX_CFG where module='B' and name='region'" >/dev/null;; esac
e="$(cw "$O" "delete from $YX_CFG where module='B' and name='tickets'")"
case "$e" in *leader*) ok "S1m another node's delete refused";; *) bad "S1m a follower's delete: [$e]";; esac
e="$(cw "$L" "delete from $YX_CFG where module='B' and name='bucket'")"
[ -z "$e" ] || bad "S1n removing a row: $e"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"bucket is required"*) break;; esac; sleep 2; done
case "$said" in *"bucket is required"*) ok "S1n a store that lacks a row says which";; *) bad "S1n [$said]";; esac
e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('bucket','B','$BUCKET')")"
[ -z "$e" ] && ok "S1o a row alone puts it right" || bad "S1o: $e"
sleep 3
e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('s3_config','C','endpoint=http://$S3:9000')")"
case "$e" in *"module B"*) ok "S1p the old C row refused, saying where it went";; *) bad "S1p [$e]";; esac

echo "-- S2 move"
table_new s3_m "id int primary key, note text, photo bytea" "$(blob_cfg 'blob=photo:move; timeout_sec=8')"
left="$(trigger_on s3_m yt_s3_blob)" && ok "S2 the trigger on every node" || bad "S2 the trigger not on:$left"
BYTES="decode(repeat('ab01', 5000), 'hex')"
e="$(cw "$O" "insert into s3_m values (1, 'one', $BYTES)")"
check "S2a the write commits" "" "$e"
K1="$(key_of s3_m photo 1)"
check "S2b the commit means S3 has it, under the key its row names" "200" "$(obj_code "$K1")"
check "S2c byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$K1")"
reach "select count(*) from s3_m where id = 1" 1 60 && ok "S2d the row on every node" || bad "S2d the row is not on every node"
check "S2e the column holds nothing on any node" "" "$(differing "select photo is null from s3_m where id = 1")"
check "S2f ...NULL" "t" "$(q "$F" "select photo is null from s3_m where id = 1")"
table_new s3_n "id int primary key, photo bytea not null" "$(blob_cfg 'blob=move')"
left="$(trigger_on s3_n yt_s3_blob)" && ok "S2g the only bytea column, unnamed: the trigger" || bad "S2g not on:$left"
e="$(cw "$O" "insert into s3_n values (1, $BYTES)")"
check "S2h a NOT NULL column commits" "" "$e"
reach "select encode(photo, 'hex') from s3_n where id = 1" 00 60 && ok "S2i it holds one zero byte on every node" || bad "S2i [$(q "$F" "select encode(photo, 'hex') from s3_n where id = 1")]"
check "S2j and S3 the blob" "$(sha_of "$BYTES")" "$(obj_sha "$(key_of s3_n photo 1)")"
e="$(cw "$O" "insert into s3_n values (2, null)")"
case "$e" in *"null value"*) ok "S2k a NULL written to NOT NULL is still refused";; *) bad "S2k: [$e]";; esac
LARGE="decode(repeat('cd', 20 * 1024 * 1024), 'hex')"
e="$(cw "$O" "insert into s3_m values (2, 'large', $LARGE)")"
check "S2l a 20 MB blob commits" "" "$e"
check "S2m in parts, byte for byte" "$(sha_of "$LARGE")" "$(obj_sha "$(key_of s3_m photo 2)")"
check "S2n its size" "$((20 * 1024 * 1024))" "$(obj_size "$(key_of s3_m photo 2)")"

echo "-- S3 what is not sent, and what a NULL is"
before="$(info "$O" E s3)"
e="$(cw "$O" "update s3_m set note = 'changed' where id = 1")"
check "S3 an UPDATE leaving the blob alone commits" "" "$e"
check "S3b it sends nothing" "$(printf '%s' "$before" | sed -E 's/.*; ([0-9]+) uploaded.*/\1/')" "$(info "$O" E s3 | sed -E 's/.*; ([0-9]+) uploaded.*/\1/')"
check "S3c and the object stays" "$(sha_of "$BYTES")" "$(obj_sha "$K1")"
e="$(cw "$O" "insert into s3_m values (3, 'none', null)")"
check "S3d a NULL commits" "" "$e"
check "S3e a zero-size object" "200:0" "$(obj_code "$(key_of s3_m photo 3)"):$(obj_size "$(key_of s3_m photo 3)")"
K4="$(key_of s3_m photo 4)"
e="$(err_of "$(qx "$O" "begin; insert into s3_m values (4, 'back', $BYTES); rollback;")")"
check "S3f a write rolled back" "" "$e"
obj_wait "$K4" 404 30 && ok "S3g its object is deleted" || bad "S3g the object of a rollback stays: $(obj_code "$K4")"

echo "-- S4 the store away, and wrong keys"
s3_down
t0=$(date +%s)
e="$(cw "$O" "insert into s3_m values (5, 'away', $BYTES)")"
t1=$(( $(date +%s) - t0 ))
[ -n "$e" ] && ok "S4 the statement fails: $(printf '%s' "$e" | cut -c1-100)" || bad "S4 the write committed with the store down"
[ "$t1" -le 30 ] && ok "S4b at the table's timeout (${t1}s)" || bad "S4b it took ${t1}s"
check "S4c nothing saved" "0" "$(q "$O" "select count(*) from s3_m where id = 5")"
s3_up || bad "S4d the store did not come back"
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_bad; tickets=on")"
sleep 3
e="$(cw "$O" "insert into s3_m values (6, 'badkeys', $BYTES)")"
[ -n "$e" ] && ok "S4e wrong keys: the statement fails" || bad "S4e wrong keys: the write committed"
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tickets=on")"
sleep 3
e="$(cw "$O" "insert into s3_m values (7, 'good again', $BYTES)")"
check "S4f the right keys again: it commits" "" "$e"

echo "-- S5 quick"
table_new s3_q "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:quick')"
left="$(trigger_on s3_q yt_s3_blob)" && ok "S5 the trigger on every node" || bad "S5 not on:$left"
s3_down
e="$(cw "$O" "insert into s3_q values (1, $BYTES)")"
check "S5a with the store down the commit returns" "" "$e"
reach "select photo is null from s3_q where id = 1" t 60 && ok "S5b the column holds nothing on any node" || bad "S5b [$(differing "select photo is null from s3_q where id = 1")]"
check "S5c the file waits" "1" "$(rh "docker exec $O sh -c 'ls /tmp/yt-s3/*.blob 2>/dev/null | wc -l'" 2>/dev/null)"
KQ="$(key_of s3_q photo 1)"
s3_up || bad "S5d the store did not come back"
obj_wait "$KQ" 200 120 && ok "S5d the store back: it goes" || bad "S5d not sent: $(info "$O" E s3)"
check "S5e byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$KQ")"
for ((i = 0; i < 20; i += 2)); do [ "$(rh "docker exec $O sh -c 'ls /tmp/yt-s3 2>/dev/null | wc -l'" 2>/dev/null)" = 0 ] && break; sleep 2; done
check "S5f its file is gone" "0" "$(rh "docker exec $O sh -c 'ls /tmp/yt-s3 2>/dev/null | wc -l'" 2>/dev/null)"
e="$(err_of "$(qx "$O" "begin; insert into s3_q values (2, $BYTES); rollback;")")"
sleep 4
check "S5g a rollback sends nothing" "404" "$(obj_code "$(key_of s3_q photo 2)")"
check "S5h and keeps no file" "0" "$(rh "docker exec $O sh -c 'ls /tmp/yt-s3 2>/dev/null | wc -l'" 2>/dev/null)"
T="$(tickets "$O" s3_q 8)"
case "$T" in *"received None photo"*) ok "S5i a ticket says received";; *) bad "S5i tickets: [$(printf '%s' "$T" | tail -3 | cut -c1-200)]";; esac
case "$T" in *"complete True photo"*) ok "S5j then complete, identical";; *) bad "S5j tickets: [$(printf '%s' "$T" | tail -3 | cut -c1-200)]";; esac
case "$T" in *'"id": "2"'*) bad "S5k a rolled back write has a ticket";; *) ok "S5k a rollback has none";; esac

echo "-- S6 ytserv killed, a quick blob waiting"
s3_down
e="$(cw "$O" "insert into s3_q values (3, $BYTES)")"
check "S6 it commits" "" "$e"
rh "docker exec $O sh -c 'cat /proc/\$(pgrep -f \"^su postgres\" | head -1)/cmdline > /tmp/yt.cmd'"
rh "docker exec $O pkill -9 -f yt-cluster/ytserv >/dev/null 2>&1; true"
echo "  $O ytserv killed"
sleep 2
s3_up || bad "S6a the store did not come back"
rh "docker exec -d $O sh -c 'exec xargs -0 -a /tmp/yt.cmd env >> /tmp/yt.s6.log 2>&1'"
obj_wait "$(key_of s3_q photo 3)" 200 120 && ok "S6b it is taken up again" || bad "S6b not sent: $(info "$O" E s3)"
check "S6c byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$(key_of s3_q photo 3)")"
node_ready "$O"
await_cluster

echo "-- S7 copy"
L="$(leader_now)"
table_new s3_c "id int primary key, note text, photo bytea" "$(blob_cfg 'blob=photo:copy')"
left="$(trigger_on s3_c yt_s3_copy_photo)" && ok "S7 the trigger on every node" || bad "S7 not on:$left"
e="$(cw "$O" "insert into s3_c values (1, 'one', $BYTES)")"
check "S7a the write commits" "" "$e"
KC="$(key_of s3_c photo 1)"
obj_wait "$KC" 200 60 && ok "S7b the object follows" || bad "S7b not sent: $(info "$O" E s3)"
check "S7c byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$KC")"
reach "select encode(sha256(photo), 'hex') from s3_c where id = 1" "$(sha_of "$BYTES")" 60 && ok "S7d the column keeps it on every node" || bad "S7d the column differs"
reach "select state from yt_s3_blob where tbl = '$PUB.s3_c' and col = 'photo'" done 60 && ok "S7e every node's record says done" || bad "S7e [$(q "$F" "select state from yt_s3_blob where tbl = '$PUB.s3_c'")]"
NEW="decode(repeat('ef02', 300), 'hex')"
e="$(cw "$F" "update s3_c set photo = $NEW where id = 1")"
check "S7f an UPDATE commits" "" "$e"
want="$(sha_of "$NEW")"
for ((i = 0; i < 40; i += 2)); do [ "$(obj_sha "$KC")" = "$want" ] && break; sleep 2; done
check "S7g the object is replaced" "$want" "$(obj_sha "$KC")"
e="$(cw "$O" "update s3_c set note = 'x' where id = 1")"
check "S7h a note: no new version" "1" "$(q "$O" "select count(*) from yt_s3_blob where tbl = '$PUB.s3_c' and state = 'done'")"
e="$(cw "$O" "delete from s3_c where id = 1")"
sleep 3
check "S7i a DELETE leaves the object" "200" "$(obj_code "$KC")"

echo "-- S8 the node that wrote it away"
L="$(leader_now)"
s3_down
G="$O"; for n in "${FOLLOWERS[@]}"; do [ "$n" != "$O" ] && [ "$n" != "$F" ] && { G="$n"; break; }; done
e="$(cw "$G" "insert into s3_c values (2, 'left', $BYTES)")"
check "S8 a write on $G with the store down" "" "$e"
reach "select count(*) from yt_s3_blob where tbl = '$PUB.s3_c' and pk = '{\"id\": \"2\"}'" 1 60 || bad "S8a the record is not on every node"
# paused, not stopped: the store's restart below could take a stopped node's address
rh "docker pause $G >/dev/null" 2>/dev/null; echo "  $G away"
s3_up || bad "S8b the store did not come back"
obj_wait "$(key_of s3_c photo 2)" 200 150 && ok "S8b the leader sends it" || bad "S8b not sent: $(info "$L" E s3)"
check "S8c byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$(key_of s3_c photo 2)")"
rh "docker unpause $G >/dev/null" 2>/dev/null
node_ready "$G"
await_cluster

echo "-- S9 rows there before"
L="$(leader_now)"
table_new s3_old "id int primary key, photo bytea" ""
table_new s3_oldc "id int primary key, photo bytea" ""
e="$(cw "$O" "insert into s3_old values (1, $BYTES), (2, $BYTES), (3, null)")"; check "S9 rows on sync" "" "$e"
e="$(cw "$O" "insert into s3_oldc values (1, $BYTES)")"; check "S9a a row on sync" "" "$e"
reach "select photo is not null from s3_old where id = 2" t 60 && ok "S9b the blob on every node, as sync" || bad "S9b not everywhere"
register_table "$PUB.s3_old" "$(blob_cfg 'blob=photo:move')"
register_table "$PUB.s3_oldc" "$(blob_cfg 'blob=photo:copy')"
obj_wait "$(key_of s3_old photo 2)" 200 120 && ok "S9c turned to move: it goes" || bad "S9c not sent: $(info "$L" E s3)"
reach "select count(*) from s3_old where photo is not null" 0 120 && ok "S9d and the column is cleared on every node" || bad "S9d [$(q "$F" "select count(*) from s3_old where photo is not null")]"
check "S9e byte for byte" "$(sha_of "$BYTES")" "$(obj_sha "$(key_of s3_old photo 1)")"
obj_wait "$(key_of s3_oldc photo 1)" 200 120 && ok "S9f turned to copy: it goes" || bad "S9f not sent: $(info "$L" E s3)"
check "S9g the column keeps it" "t" "$(q "$F" "select photo is not null from s3_oldc where id = 1")"

echo "-- S10 a directory this node cannot use"
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tickets=on; tmp_dir=/proc/nope")"
[ -z "$e" ] || bad "S10 the setting: $e"
table_new s3_dir "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:quick')"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"/proc/nope"*) break;; esac; sleep 2; done
case "$said" in *"/proc/nope"*) ok "S10a it says so: $(printf '%s' "$said" | cut -c1-90)";; *) bad "S10a [$said]";; esac
check "S10b no trigger on the table" "0" "$(q "$O" "select count(*) from pg_trigger where tgrelid = '$PUB.s3_dir'::regclass and tgname = 'yt_s3_blob'")"
e="$(cw "$O" "insert into s3_dir values (1, $BYTES)")"
check "S10c writes go on" "" "$e"
reach "select photo is not null from s3_dir where id = 1" t 60 && ok "S10d as sync" || bad "S10d the blob is not on every node"
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tickets=on")"

echo "-- S11 a large row between nodes"
TEN="decode(repeat('5a', 10 * 1024 * 1024), 'hex')"
table_new s3_big "id int primary key, photo bytea" ""
e="$(cw "$O" "insert into s3_big values (1, $TEN)")"
check "S11 a 10 MB row on sync commits" "" "$e"
reach "select octet_length(photo) from s3_big where id = 1" "$((10 * 1024 * 1024))" 120 && ok "S11a on every node" || bad "S11a not on every node: [$(differing "select octet_length(photo) from s3_big where id = 1")]"
check "S11b byte for byte" "" "$(differing "select md5(photo) from s3_big where id = 1")"
table_new s3_bigc "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:copy')"
left="$(trigger_on s3_bigc yt_s3_copy_photo)" && ok "S11c copy: the trigger" || bad "S11c not on:$left"
e="$(cw "$O" "insert into s3_bigc values (1, $TEN)")"
check "S11d a 10 MB row on copy commits" "" "$e"
obj_wait "$(key_of s3_bigc photo 1)" 200 120 && ok "S11e the object follows" || bad "S11e not sent: $(info "$O" E s3)"
check "S11f byte for byte" "$(sha_of "$TEN")" "$(obj_sha "$(key_of s3_bigc photo 1)")"
reach "select octet_length(photo) from s3_bigc where id = 1" "$((10 * 1024 * 1024))" 120 && ok "S11g on every node" || bad "S11g not on every node"
check "S11h no node logged a divergence" "0" "$(for n in "${NODES[@]}"; do rh "docker logs $n 2>&1 | grep -c 'CLUSTER DIVERGENCE'" 2>/dev/null || true; done | awk '{s+=$1} END {print s+0}')"

echo "-- S12 what must not reach the store"
OTHER="decode(repeat('77aa', 700), 'hex')"
ORIG="$(sha_of "$BYTES")"
e="$(cw "$O" "insert into s3_m values (1, 'again', $OTHER)")"
case "$e" in *"duplicate key"*|*"unique"*) ok "S12 a key already there: the write fails";; *) bad "S12 [$e]";; esac
sleep 3
check "S12a and the committed row's object is as it was" "200:$ORIG" "$(obj_code "$K1"):$(obj_sha "$K1")"
# it writes nothing, so there is no cluster transaction to complete
e="$(err_of "$(qx "$O" "insert into s3_m values (1, 'again', $OTHER) on conflict do nothing;")")"
check "S12b ON CONFLICT DO NOTHING commits" "" "$e"
sleep 2
check "S12c and the object is as it was" "$ORIG" "$(obj_sha "$K1")"
e="$(cw "$O" "insert into s3_m values (7, 'upsert', $OTHER) on conflict (id) do update set photo = excluded.photo")"
check "S12d ON CONFLICT DO UPDATE setting the blob commits" "" "$e"
check "S12e and sends it" "$(sha_of "$OTHER")" "$(obj_sha "$(key_of s3_m photo 7)")"
K8="$(key_of s3_m photo 8)"
e="$(err_of "$(qx "$O" "begin; savepoint a; insert into s3_m values (8, 'sp', $OTHER); rollback to a; commit;")")"
case "$e" in *"savepoint was rolled back"*) ok "S12f move: a savepoint rolled back over the write: refused at COMMIT";; *) bad "S12f [$e]";; esac
obj_wait "$K8" 404 30 && ok "S12g the object goes" || bad "S12g it stays: $(obj_code "$K8")"
e="$(err_of "$(qx "$O" "begin; savepoint a; update s3_q set photo = $OTHER where id = 1; rollback to a; commit;")")"
case "$e" in *"savepoint was rolled back"*) ok "S12h quick: an UPDATE under a savepoint rolled back: refused";; *) bad "S12h [$e]";; esac
sleep 4
check "S12i the object is as it was" "$ORIG" "$(obj_sha "$KQ")"
e="$(err_of "$(qx "$O" "begin; savepoint a; insert into s3_q values (8, $OTHER); rollback to a; insert into s3_q values (9, $OTHER); commit;")")"
case "$e" in *"savepoint was rolled back"*) ok "S12j quick: one rolled back, the next written: refused";; *) bad "S12j [$e]";; esac
sleep 4
check "S12k neither goes" "404 404" "$(obj_code "$(key_of s3_q photo 8)") $(obj_code "$(key_of s3_q photo 9)")"
e="$(err_of "$(qx "$O" "begin; insert into s3_q values (9, $OTHER); savepoint a; select 1; rollback to a; commit;")")"
check "S12l quick: a savepoint rolled back over no write commits" "" "$e"
obj_wait "$(key_of s3_q photo 9)" 200 60 && ok "S12l1 and it goes" || bad "S12l1 not sent"
e="$(err_of "$(qx "$O" "select yt_info('s3+:{\"db\":\"$YX_DB\",\"schema\":\"$PUB\",\"table\":\"s3_m\",\"column\":\"photo\",\"pk\":[\"1\"],\"pk_names\":[\"id\"],\"mode\":\"move\",\"xid\":1}')")")"
case "$e" in *"not for SQL"*) ok "S12m the handover refused from SQL";; *) bad "S12m [$e]";; esac
check "S12n and the object is as it was" "$ORIG" "$(obj_sha "$K1")"

echo "-- S13 an application's role"
for n in "${NODES[@]}"; do q "$n" "drop role if exists s3_app; create role s3_app" >/dev/null; done
table_new s3_role "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:move')"
table_new s3_rolec "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:copy')"
left="$(trigger_on s3_role yt_s3_blob)" && ok "S13 the triggers: move" || bad "S13 not on:$left"
left="$(trigger_on s3_rolec yt_s3_copy_photo)" && ok "S13a the triggers: copy" || bad "S13a not on:$left"
for n in "${NODES[@]}"; do q "$n" "grant insert on s3_role, s3_rolec to s3_app" >/dev/null; done
e="$(err_of "$(qx "$O" "begin; set local role s3_app; insert into s3_role values (1, $BYTES); commit;")")"
check "S13b move, inserting with no right to read" "" "$e"
check "S13c it is in the store" "$ORIG" "$(obj_sha "$(key_of s3_role photo 1)")"
check "S13f its role cannot use the trigger functions itself" "f f f" "$(q "$O" "select has_function_privilege('s3_app', 'yt_s3_blob()', 'execute') || ' ' || has_function_privilege('s3_app', 'yt_s3_probe(text)', 'execute') || ' ' || has_function_privilege('s3_app', 'yt_s3_copy()', 'execute')" | sed 's/true/t/g; s/false/f/g')"
e="$(err_of "$(qx "$O" "begin; set local role s3_app; insert into s3_rolec values (1, $BYTES); commit;")")"
check "S13d copy, with no right on the record's table" "" "$e"
obj_wait "$(key_of s3_rolec photo 1)" 200 60 && ok "S13e it follows" || bad "S13e not sent: $(info "$O" E s3)"

echo "-- S14 a mode turned off, and the store's setting gone"
register_table "$PUB.s3_rolec" ""
reach "select count(*) from pg_trigger where tgrelid = '$PUB.s3_rolec'::regclass and tgname like 'yt_s3_copy%'" 0 60 && ok "S14 the mode gone: its trigger too, on every node" || bad "S14 [$(differing "select count(*) from pg_trigger where tgrelid = '$PUB.s3_rolec'::regclass and tgname like 'yt_s3_copy%'")]"
register_table "$PUB.s3_role" "$(blob_cfg 'blob=photo:sync')"
reach "select count(*) from pg_trigger where tgrelid = '$PUB.s3_role'::regclass and tgname = 'yt_s3_blob'" 0 60 && ok "S14a set to sync: the same" || bad "S14a a trigger stays"
e="$(cw "$O" "insert into s3_role values (2, $BYTES)")"
check "S14b a write keeps its blob" "" "$e"
reach "select photo is not null from s3_role where id = 2" t 60 && ok "S14c on every node" || bad "S14c not on every node"
check "S14d nothing went" "404" "$(obj_code "$(key_of s3_role photo 2)")"
e="$(cw "$L" "delete from $YX_CFG where module='B'")"
[ -z "$e" ] || bad "S14e removing it: $e"
reach "select count(*) from pg_trigger where tgrelid = '$PUB.s3_q'::regclass and tgname = 'yt_s3_blob'" 0 60 && ok "S14e the store's setting gone: the triggers too" || bad "S14e a trigger stays"
e="$(cw "$O" "insert into s3_q values (20, $BYTES)")"
check "S14f a write does not fail for it" "" "$e"
reach "select photo is not null from s3_q where id = 20" t 60 && ok "S14g and keeps its blob" || bad "S14g [$(q "$O" "select photo is null from s3_q where id = 20")]"

echo "-- S15 a table made again, and a directory with a trailing /"
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tickets=on; tmp_dir=/tmp/")"
[ -z "$e" ] && ok "S15 the store set again, tmp_dir=/tmp/" || bad "S15: $e"
table_new s3_again "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:quick')"
left="$(trigger_on s3_again yt_s3_blob)" && ok "S15a the trigger" || bad "S15a not on:$left"
e="$(cw "$O" "insert into s3_again values (1, $BYTES)")"
check "S15b a write through that directory" "" "$e"
obj_wait "$(key_of s3_again photo 1)" 200 60 && ok "S15c it goes" || bad "S15c not sent: $(info "$O" E s3)"
for n in "${NODES[@]}"; do q "$n" "drop table s3_again; create table s3_again (id int primary key, photo bytea)" >/dev/null; done
register_table "$PUB.s3_again" "$(blob_cfg 'blob=photo:quick')"
left="$(trigger_on s3_again yt_s3_blob)" && ok "S15d dropped and made again: its trigger is back" || bad "S15d not on:$left"
e="$(cw "$O" "insert into s3_again values (2, $BYTES)")"
check "S15e and a write moves" "t" "$(q "$O" "select photo is null from s3_again where id = 2")"

echo "-- S16 a restore"
e="$(cw "$O" "delete from s3_m where id = 1")"
check "S16 a moved row deleted" "" "$e"
e="$(cw "$O" "insert into s3_m values (1, 'restored', null)")"
check "S16a written back, its column NULL" "" "$e"
sleep 2
check "S16b the object is as it was" "$ORIG" "$(obj_sha "$K1")"
Kn="$(key_of s3_n photo 1)"
e="$(cw "$O" "delete from s3_n where id = 1")"
e="$(cw "$O" "insert into s3_n values (1, '\\x00'::bytea)")"
check "S16c NOT NULL: written back, its zero byte" "" "$e"
sleep 2
check "S16d the object is as it was" "$ORIG" "$(obj_sha "$Kn")"
e="$(cw "$O" "insert into s3_m values (30, 'new', null)")"
check "S16e a NULL with no object: still a zero-size one" "200:0" "$(obj_code "$(key_of s3_m photo 30)"):$(obj_size "$(key_of s3_m photo 30)")"

echo "-- S17 a rollback, then the same key again"
K17="$(key_of s3_m photo 17)"
e="$(err_of "$(qx "$O" "begin; insert into s3_m values (17, 'one', $OTHER); rollback;")")"
check "S17 a write rolled back" "" "$e"
e="$(err_of "$(qx "$O" "begin; insert into s3_m values (17, 'two', $BYTES); select pg_sleep(14); commit;")")"
check "S17a the same key again, slowly, commits" "" "$e"
check "S17b the object is the one committed" "200:$ORIG" "$(obj_code "$K17"):$(obj_sha "$K17")"

echo "-- S18 what is refused"
for n in "${NODES[@]}"; do rh "docker exec $n sh -c 'rm -rf /tmp/s3shared; mkdir -p /tmp/s3shared/yt-s3; chmod 777 /tmp/s3shared/yt-s3; chown -R postgres /tmp/s3shared'" 2>/dev/null; done
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys; tmp_dir=/tmp/s3shared")"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"own directory"*) break;; esac; sleep 2; done
case "$said" in *"own directory"*) ok "S18 a directory open to others: refused, and said";; *) bad "S18 [$said]";; esac
e="$(err_of "$(qx "$O" "select yt_s3_probe('/tmp/s3shared')")")"
case "$e" in *"own directory"*) ok "S18a the backend refuses it too";; *) bad "S18a [$e]";; esac
e="$(cfg_put_s3 "endpoint=http://$S3:9000; bucket=$BUCKET; secret=s3_keys")"
for n in "${NODES[@]}"; do q "$n" "drop table if exists s3_part; create table s3_part (id int, photo bytea, primary key (id)) partition by range (id); create table s3_part_1 partition of s3_part for values from (0) to (100)" >/dev/null; done
register_table "$PUB.s3_part" "$(blob_cfg 'blob=photo:move')"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"partitioned"*) break;; esac; sleep 2; done
case "$said" in *"partitioned"*) ok "S18b a partitioned table: refused, and said";; *) bad "S18b [$said]";; esac
check "S18c no trigger on it" "0" "$(q "$O" "select count(*) from pg_trigger where tgrelid = '$PUB.s3_part'::regclass and tgname = 'yt_s3_blob'")"
register_table "$PUB.s3_part" ""

echo "-- S19 a key's text"
table_new s3_date "d date primary key, photo bytea" "$(blob_cfg 'blob=photo:move')"
left="$(trigger_on s3_date yt_s3_blob)" && ok "S19 the trigger" || bad "S19 not on:$left"
e="$(err_of "$(qx "$O" "begin; set local datestyle = 'SQL, DMY'; insert into s3_date values ('2026-11-05', $BYTES); commit;")")"
check "S19a a date key, written under another DateStyle" "" "$e"
check "S19b its key is the ISO text" "$ORIG" "$(obj_sha "$(key_of s3_date photo 2026-11-05)")"
table_new s3_ts "t timestamptz primary key, photo bytea" "$(blob_cfg 'blob=photo:move')"
left="$(trigger_on s3_ts yt_s3_blob)" && ok "S19c the trigger" || bad "S19c not on:$left"
e="$(err_of "$(qx "$O" "begin; set local timezone = 'Asia/Tokyo'; insert into s3_ts values ('2026-11-05 21:00:00+09', $BYTES); commit;")")"
check "S19d a time key, written under another TimeZone" "" "$e"
check "S19e its key is the UTC text" "$ORIG" "$(obj_sha "$(key_of s3_ts photo '2026-11-05%252012%253A00%253A00%252B00')")"

echo "-- S20 a moved NOT NULL column turned to copy"
register_table "$PUB.s3_n" "$(blob_cfg 'blob=copy')"
Kn="$(key_of s3_n photo 1)"
reach "select state from yt_s3_blob where tbl = '$PUB.s3_n' and pk = '{\"id\": \"1\"}'" done 120 && ok "S20 its record says done" || bad "S20 [$(q "$O" "select state, error from yt_s3_blob where tbl = '$PUB.s3_n'")] $(info "$L" E s3)"
check "S20a and the object is the blob, not the marker" "$ORIG" "$(obj_sha "$Kn")"
e="$(cw "$O" "insert into s3_n values (40, '\\x00'::bytea)")"
K40="$(key_of s3_n photo 40)"
obj_wait "$K40" 200 60 && ok "S20b one zero byte with no object: sent as a value" || bad "S20b not sent: $(info "$O" E s3)"
check "S20c its size" "1" "$(obj_size "$K40")"
register_table "$PUB.s3_n" "$(blob_cfg 'blob=move')"

echo "-- S21 a rollback, and a member holds the row"
K21="$(key_of s3_m photo 21)"
for n in "${NODES[@]}"; do [ "$n" = "$O" ] || q "$n" "begin; set local yt.node = 'local'; insert into s3_m values (21, 'elsewhere', null); commit" >/dev/null; done
# the members refuse it, or take it: a rollback either way
qx "$O" "begin; insert into s3_m values (21, 'mine', $BYTES); rollback;" >/dev/null 2>&1
sleep 14
check "S21a the object stays: a member's row may need it" "200:$ORIG" "$(obj_code "$K21"):$(obj_sha "$K21")"
for n in "${NODES[@]}"; do [ "$n" = "$O" ] || q "$n" "begin; set local yt.node = 'local'; delete from s3_m where id = 21; commit" >/dev/null; done

echo "-- S22 a rollback, and another node's write under way"
K22="$(key_of s3_m photo 22)"
e="$(err_of "$(qx "$O" "begin; insert into s3_m values (22, 'one', $OTHER); rollback;")")"
check "S22 a write rolled back" "" "$e"
e="$(err_of "$(qx "$F" "begin; insert into s3_m values (22, 'two', $BYTES); select pg_sleep(14); commit;")")"
check "S22a another node's commits, slowly" "" "$e"
check "S22b its object is there" "200:$ORIG" "$(obj_code "$K22"):$(obj_sha "$K22")"

echo "-- S23 a mode off and on"
table_new s3_onoff "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:move')"
left="$(trigger_on s3_onoff yt_s3_blob)" && ok "S23 the trigger" || bad "S23 not on:$left"
register_table "$PUB.s3_onoff" ""
reach "select count(*) from pg_trigger where tgrelid = '$PUB.s3_onoff'::regclass and tgname = 'yt_s3_blob'" 0 60 || bad "S23a its trigger stays"
e="$(cw "$O" "insert into s3_onoff values (1, $BYTES)")"
check "S23b a write with the mode off" "" "$e"
register_table "$PUB.s3_onoff" "$(blob_cfg 'blob=photo:move')"
reach "select count(*) from s3_onoff where photo is not null" 0 120 && ok "S23c on again: the row goes" || bad "S23c [$(q "$O" "select count(*) from s3_onoff where photo is not null")]"
check "S23d byte for byte" "$ORIG" "$(obj_sha "$(key_of s3_onoff photo 1)")"
e="$(err_of "$(qx "$O" "begin; set local yt.s3_skip = 'on'; insert into s3_onoff values (2, $BYTES); commit;")")"
check "S23e a row the trigger missed" "" "$e"
reach "select count(*) from s3_onoff where photo is not null" 0 180 && ok "S23f a later look finds it" || bad "S23f it stays: $(info "$L" E s3)"
check "S23g byte for byte" "$ORIG" "$(obj_sha "$(key_of s3_onoff photo 2)")"

echo "-- S24 an old row, and an object there"
table_new s3_stale "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:move')"
left="$(trigger_on s3_stale yt_s3_blob)" && ok "S24 the trigger" || bad "S24 not on:$left"
e="$(cw "$O" "insert into s3_stale values (1, $OTHER), (2, $BYTES), (3, $OTHER)")"
check "S24a objects there" "" "$e"
register_table "$PUB.s3_stale" ""
reach "select count(*) from pg_trigger where tgrelid = '$PUB.s3_stale'::regclass and tgname = 'yt_s3_blob'" 0 60 || bad "S24b its trigger stays"
e="$(cw "$O" "update s3_stale set photo = $BYTES")"
check "S24c the rows hold a blob again" "" "$e"
# one member's row 3 holds another value, as one with a newer write would
L="$(leader_now)"; M=""; for n in "${NODES[@]}"; do [ "$n" = "$L" ] || { M="$n"; break; }; done
q "$M" "begin; set local yt.node = 'local'; update s3_stale set photo = $OTHER where id = 3; commit" >/dev/null
register_table "$PUB.s3_stale" "$(blob_cfg 'blob=photo:move')"
reach "select photo is null from s3_stale where id = 2" t 90 && ok "S24d of the same content: the row clears" || bad "S24d [$(q "$O" "select photo is null from s3_stale where id = 2")]"
check "S24e of other content: the row keeps its blob" "f" "$(q "$O" "select photo is null from s3_stale where id = 1")"
check "S24f and the object is not replaced" "$(sha_of "$OTHER")" "$(obj_sha "$(key_of s3_stale photo 1)")"
reach "select photo is null from s3_stale where id = 1" t 240 && ok "S24g that write's time out: the object is replaced" || bad "S24g [$(q "$O" "select photo is null from s3_stale where id = 1")]"
check "S24h byte for byte" "$ORIG" "$(obj_sha "$(key_of s3_stale photo 1)")"
check "S24i a member's row differs: that object is not replaced" "$(sha_of "$OTHER")" "$(obj_sha "$(key_of s3_stale photo 3)")"
q "$M" "begin; set local yt.node = 'local'; update s3_stale set photo = $BYTES where id = 3; commit" >/dev/null
reach "select photo is null from s3_stale where id = 3" t 120 && ok "S24j it holds this value again: it goes" || bad "S24j [$(q "$L" "select photo is null from s3_stale where id = 3")] $(info "$L" E s3)"
check "S24k byte for byte" "$ORIG" "$(obj_sha "$(key_of s3_stale photo 3)")"

echo "-- S25 an old row's upload holds no lock"
table_new s3_lock "id int primary key, note text, photo bytea" ""
e="$(cw "$O" "insert into s3_lock values (1, 'a', $BYTES)")"
check "S25 a row" "" "$e"
reach "select count(*) from s3_lock where id = 1" 1 60 || bad "S25a not on every node"
rh "docker pause $S3 >/dev/null" 2>/dev/null
register_table "$PUB.s3_lock" "$(blob_cfg 'blob=photo:move')"
sleep 15
L="$(leader_now)"
e="$(err_of "$(qx "$L" "begin; set local lock_timeout = '3s'; select 1 from s3_lock where id = 1 for update; rollback;")")"
check "S25b with the store silent, the leader's row can be locked" "" "$e"
rh "docker unpause $S3 >/dev/null" 2>/dev/null
reach "select photo is null from s3_lock where id = 1" t 400 && ok "S25c and it goes when the store is back" || bad "S25c [$(q "$L" "select photo is null from s3_lock where id = 1")] $(info "$L" E s3)"

echo "-- S26 a key column that cannot name an object"
for n in "${NODES[@]}"; do q "$n" "drop table if exists s3_enum; drop type if exists s3_e; create type s3_e as enum ('a', 'b'); create table s3_enum (e s3_e primary key, photo bytea); drop table if exists s3_gen; create table s3_gen (a int, g int generated always as (a + 1) stored primary key, photo bytea)" >/dev/null; done
register_table "$PUB.s3_enum" "$(blob_cfg 'blob=photo:move')"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"pg_catalog"*) break;; esac; sleep 2; done
case "$said" in *"pg_catalog"*) ok "S26 a type of a user's: refused, and said";; *) bad "S26 [$said]";; esac
check "S26a no trigger on it" "0" "$(q "$O" "select count(*) from pg_trigger where tgrelid = '$PUB.s3_enum'::regclass and tgname = 'yt_s3_blob'")"
register_table "$PUB.s3_enum" ""
register_table "$PUB.s3_gen" "$(blob_cfg 'blob=photo:move')"
said=""
for ((i = 0; i < 30; i += 2)); do said="$(info "$O" E s3)"; case "$said" in *"generated"*) break;; esac; sleep 2; done
case "$said" in *"generated"*) ok "S26b a generated one: refused, and said";; *) bad "S26b [$said]";; esac
register_table "$PUB.s3_gen" ""
e="$(err_of "$(qx "$O" "begin; create trigger yt_s3_blob before insert on s3_gen for each row execute function yt_s3_blob('/tmp', 'photo', 'move'); insert into s3_gen (a, photo) values (1, $BYTES); rollback;")")"
case "$e" in *"no value yet"*) ok "S26c the trigger itself: no object under an empty key";; *) bad "S26c [$e]";; esac
check "S26d and no such object" "404" "$(obj_code "$(key_of s3_gen photo '')")"

echo "-- S27 an UPDATE to a key already there"
e="$(cw "$O" "insert into s3_m values (31, 'from', $BYTES), (32, 'to', $BYTES)")"
check "S27 two rows" "" "$e"
e="$(cw "$O" "update s3_m set id = 32, photo = $OTHER where id = 31")"
case "$e" in *"duplicate key"*) ok "S27a refused by the unique check";; *) bad "S27a [$e]";; esac
check "S27b and the object of the row there is as it was" "$ORIG" "$(obj_sha "$(key_of s3_m photo 32)")"

echo "-- S28 two INSERTs of one new key"
table_new s3_two "a int, b int, photo bytea, primary key (b, a)" "$(blob_cfg 'blob=photo:move')"
left="$(trigger_on s3_two yt_s3_blob)" && ok "S28 the trigger" || bad "S28 not on:$left"
K28="$(key_of s3_two photo 1/2)"
qx "$O" "begin; insert into s3_two values (1, 2, $OTHER); select pg_sleep(4); rollback;" >/dev/null 2>&1 &
first=$!
sleep 1.5
e="$(cw "$O" "insert into s3_two values (1, 2, $BYTES)")"
wait "$first" || true
check "S28a the second waits for the first's outcome, and commits" "" "$e"
sleep 14
check "S28b its object is the one that stays" "200:$ORIG" "$(obj_code "$K28"):$(obj_sha "$K28")"

echo "-- S29 a copy row that would fail again"
table_new s3_cpk "id int primary key, photo bytea" "$(blob_cfg 'blob=photo:copy')"
left="$(trigger_on s3_cpk yt_s3_copy_photo)" && ok "S29 the trigger" || bad "S29 not on:$left"
s3_down
e="$(cw "$O" "insert into s3_cpk values (1, $BYTES)")"
check "S29a a write with the store down" "" "$e"
reach "select count(*) from yt_s3_blob where tbl = '$PUB.s3_cpk'" 1 60 || bad "S29b the record is not on every node"
for n in "${NODES[@]}"; do q "$n" "alter table s3_cpk drop constraint s3_cpk_pkey" >/dev/null; done
s3_up || bad "S29c the store did not come back"
reach "select state from yt_s3_blob where tbl = '$PUB.s3_cpk'" failed 120 && ok "S29d it ends as failed, said on its row" || bad "S29d [$(q "$O" "select state, error from yt_s3_blob where tbl = '$PUB.s3_cpk'")]"
register_table "$PUB.s3_cpk" ""

summary
