#!/usr/bin/env bash
# [sge-worker] A schema migration rolled across the running cluster by its worker
# (yt-pgxt sge_worker.md, ytserv state/sge_worker.rs): an operator's row in sge_history on any
# node, the cluster worker moving node by node, each node's local worker running sge on its
# own database. The middle of this file does to a roll what Jepsen's nemeses do to a
# transaction: nodes killed, paused and cut off while it runs, and writes going on beside it.
#
# ## What is asserted
#
# W1 module M set through the sync path: the table and its trigger on every node
# W2 a bad row of module M is refused at the statement, and is not applied
# W3 a roll from a follower: the origin first, the leader last; every node's schema the
#    same; the operator's row done; a hand-written yt:pending starts nothing
# W4 a failure halts it: the node says why, the leader is not reached, and a second
#    roll is refused; set back by the operator, it finishes
# W5 the origin dies mid-roll: the leader takes it over, and it finishes on the others;
#    back, the origin's own part is done and its row closed
# W6 a node away: the others go on after a short wait; the roll is not finished until it
#    is back and has it too
# W7 the leader as the origin: it starts on the leader
# W8 all at once: together, not in turn; a failure stops none of the others, and is said;
#    set back, it finishes
# W9 all at once by table: a roll naming its table goes together, another still in turn
# W10 the nemeses, during one roll with writes going on: a node killed, one paused, one
#     cut off the network, two down together. Every node ends on the same schema, every
#     acknowledged write is on every node, and no row is on some nodes only
# W11 a zip on the origin alone: refused from a node without it; carried to every other
#     node, each row with the archive's tag, md5 and size; the origin's wins over another
#     file at that path; the origin killed, the others still get it from a copy
# W12 a folder on the origin alone: zipped there and carried the same way
# W13 git, on a branch that is not the default: each node's own clone, all on the one commit
#     resolved before the roll, though the branch moves during it
# W14 ytserv killed under its psql, between two scripts: the script left going is ended, the
#     one recorded is not applied twice, and no false failure
# W15 abandoned by its operator: no leader finishes it, and a later version goes
# W16 a node that cannot write its row says so: the roll halts, not told forever; fixed and set
#     back by its operator, it finishes
# W17 a node never told a halted roll finished: a leader tells it again, and later rolls go
# W18 a plan every node makes, compared: the same on all, nothing applied, and the version it
#     planned still rolls
# W19 a snapshot every node makes: the same on all, without the cluster's own tables
# W20 a table on one node alone: that node named as different, and its text there to read
# W21 a node down: no answer, never the same
# W22 a check during a roll: refused
# W23 a CI's commit on the rows: a plan and a roll of that commit while the branch moves on, every
#     node on it; a plan with none keeps the commit it resolved; not a whole commit, or a commit
#     with a folder as the source: refused
# W24 a script that writes rows: each node counts its own, and they still make one plan; a node
#     whose database makes the script do something else is named
# W25 every node's whole schema by pg_dump: the same, without the cluster's own tables or what
#     each run makes its own; an index on one node and a function changed on one: that node
#     named, its group's text showing it
# W26 the CI's role: a bad name refused at the statement; its two functions and the checks on every
#     node, nothing on sge's own table; it adds a check, a plan and a roll, which run and finish,
#     and reads them; it cannot add a worker's row, nor read or write the history or the checks
#     itself; no longer named, its rights gone on every node
# W27 refused, not left waiting nor marked done: a roll of a version done on every node (at its
#     commit: done); another commit of the version rolling, on another node and on the origin; two
#     commits asked for at once; a row of another commit while a roll halts, and after the halted
#     roll is finished
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== sge worker: migrations rolled across the cluster, nodes dropping =="

DIR=/tmp/sge_w
ZDIR=/tmp/sge_wz
GDIR=/tmp/sge_wg
HIST=public.sge_history
T=sw_t
LOAD=sw_load
TMP="$(mktemp -d)"
trap 'touch "$TMP/stop"; rm -rf "$TMP"' EXIT

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done

leader() {
	local n
	for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) echo "$n"; return;; esac; done
}
qx() { # qx <node> <sql> -> psql's output WITH its errors
	printf '%s\n' "$2" | rh "docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=60s' $1 \
psql -X -tAq -v ON_ERROR_STOP=1 -d $YX_DB 2>&1" 2>&1 || true
}
# docker's too: a statement sent to a node that is down or paused is no acknowledged write
err_of() { printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|Error response from daemon|is not running|is paused' || true; }; }
cw() { err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;")"; }
cfg_put() { # cfg_put <name> <value>: through the sync path -> "" or the error
	cw "$L" "delete from $YX_CFG where module='C' and name='$1'; insert into $YX_CFG (name,module,value) values ('$1','C','$2')"
}
# sge_put "name=value; ...": module M's rows, a row each, through the sync path -> "" or the error
sge_put() {
	local values="" kv k v old="$IFS"
	IFS=';'
	for kv in $1; do
		k="${kv%%=*}"; k="${k// /}"; v="${kv#*=}"
		values="${values:+$values,}('$k','M','$v')"
	done
	IFS="$old"
	cw "$L" "delete from $YX_CFG where module='M'; insert into $YX_CFG (name,module,value) values $values"
}
script() { # script <file> <sql>: on every node, stopped ones too when they are back
	local n
	for n in "${NODES[@]}"; do
		printf '%s\n' "$2" | rh "docker exec -i $n sh -c 'mkdir -p $DIR && cat > $DIR/$1 && chmod -R a+rX $DIR'" 2>/dev/null
	done
}
told_another() { # told_another <version> <node>: a node but this one has its row: the roll is out of the origin's hands
	local i n
	for ((i = 0; i < 60; i += 1)); do
		for n in "${NODES[@]}"; do
			[ "$n" = "$2" ] && continue
			[ -n "$(msg_of "$n" "$1")" ] && return 0
		done
		sleep 1
	done
	return 1
}
roll() { q "$1" "insert into $HIST (source, source_type, version, msg) values ('${3:-roll}', 'Y', '$2', 'yt:roll')" >/dev/null; }
msg_of() { q "$1" "select msg from $HIST where target = '$(node_uuid "$1")' and version = '$2' order by id desc limit 1"; }
when_of() { q "$1" "select extract(epoch from executed_on) from $HIST where target = '$(node_uuid "$1")' and version = '$2' order by id desc limit 1"; }
op_msg() { q "$1" "select msg from $HIST where coalesce(target,'') = '' and version = '$2' and msg like 'yt:%' limit 1"; }
op_wait() { # op_wait <node> <version> <prefix>: until the operator's row says so
	local i
	for ((i = 0; i < 40; i += 2)); do case "$(op_msg "$1" "$2")" in "$3"*) return 0;; esac; sleep 2; done
	return 1
}
wait_msg() { # wait_msg <version> <message> <seconds> <node...>: until each says so; the ones that do not
	local v="$1" m="$2" t="$3" i n left; shift 3
	for ((i = 0; i < t; i += 2)); do
		left=""
		for n in "$@"; do case "$(msg_of "$n" "$v")" in "$m"*) ;; *) left="$left $n";; esac; done
		[ -z "$left" ] && return 0
		sleep 2
	done
	echo "$left"
	return 1
}
differing() { # differing <sql>: the nodes whose answer differs from the first's
	local n a first="" out=""
	for n in "${NODES[@]}"; do
		a="$(q "$n" "$1")"
		[ -n "$first" ] || first="$a"
		[ "$a" = "$first" ] || out="$out $n=$a"
	done
	echo "$out"
}
same_schema() {
	local d
	d="$(differing "select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) from information_schema.columns where table_name = '$T'")"
	[ -z "$d" ] && ok "$1: the same schema on every node" || bad "$1: the schema differs:$d"
}
# drop what an earlier run left
clean() {
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop view if exists ${HIST}_check_groups; drop table if exists sw_cnt; drop function if exists sw_fn()" >/dev/null 2>&1
		q "$n" "drop function if exists public.yt_sge_request(text, text, text, text); drop function if exists public.yt_sge_rows()" >/dev/null 2>&1
		q "$n" "drop table if exists $HIST, ${HIST}_check, $T, $LOAD, sw_block, sw_only_one; drop function if exists public.yt_sge_roll() cascade" >/dev/null 2>&1
		q "$n" "do \$\$ begin if exists (select 1 from pg_roles where rolname = 'sw_ci') then drop owned by sw_ci; drop role sw_ci; end if; end \$\$" >/dev/null 2>&1
		rh "docker exec $n rm -rf $DIR $ZDIR $GDIR" 2>/dev/null
	done
}

await_cluster
L="$(leader)"
[ -n "$L" ] || { bad "no leader"; summary; }
clean
script "placeholder.txt" "not a script"
for n in "${NODES[@]}"; do q "$n" "create table if not exists $T (id int primary key, v text)" >/dev/null; done

# a follower to start from, and followers to do things to: never the leader
FOLLOWERS=()
for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"; G="${FOLLOWERS[2]}"; H="${FOLLOWERS[3]}"
echo "  leader $L, origin $O, others $F $G $H"

echo "-- W2 a bad setting is refused"
e="$(sge_put 'db_host=elsewhere')"
case "$e" in *"not set here"*) ok "W2 db_host in module M refused";; *) bad "W2 db_host in module M: [$e]";; esac
e="$(cfg_put sge_config 'source_dir=/x')"
case "$e" in *"module M"*) ok "W2d the old C row refused, saying where it went";; *) bad "W2d [$e]";; esac
e="$(sge_put 'no_such_setting=1')"
case "$e" in *"no setting of sge"*) ok "W2b an unknown setting refused";; *) bad "W2b an unknown setting: [$e]";; esac
check "W2c nothing applied" "off" "$(info "$L" E sge)"

echo "-- W1 the table and its trigger"
e="$(sge_put "source_dir=$DIR")"
[ -z "$e" ] || bad "W1 module M: $e"
left=""
for ((i = 0; i < 90; i += 3)); do
	left=""
	for n in "${NODES[@]}"; do
		[ "$(q "$n" "select count(*) from pg_trigger where tgname = 'yt_sge_roll' and tgrelid = to_regclass('$HIST')")" = "1" ] || left="$left $n"
	done
	[ -z "$left" ] && break
	sleep 3
done
[ -z "$left" ] && ok "W1 the history table and its trigger on every node" || bad "W1 not on:$left"
check "W1b the worker says so" "idle" "$(info "$L" E sge)"

echo "-- W3 a roll from a follower"
script "V1_0__a.sql" "alter table $T add column a int;"
roll "$O" 1.0
left="$(wait_msg 1.0 yt:done 120 "${NODES[@]}")" && ok "W3 every node has it" || bad "W3 not done on:$left"
same_schema W3
check "W3b the column" "1" "$(q "$L" "select count(*) from information_schema.columns where table_name = '$T' and column_name = 'a'")"
to="$(when_of "$O" 1.0)"; tl="$(when_of "$L" 1.0)"
first=1; last=1
for n in "${NODES[@]}"; do
	tn="$(when_of "$n" 1.0)"
	[ "$n" = "$O" ] || python3 -c "import sys; sys.exit(0 if $to <= $tn else 1)" || first=0
	[ "$n" = "$L" ] || python3 -c "import sys; sys.exit(0 if $tn <= $tl else 1)" || last=0
done
check "W3c the origin first" "1" "$first"
check "W3d the leader last" "1" "$last"
for ((i = 0; i < 30; i += 2)); do [ "$(q "$O" "select msg from $HIST where msg like 'yt:%' and coalesce(target,'') = '' and version = '1.0' limit 1")" = "yt:done" ] && break; sleep 2; done
check "W3e the operator's row is done" "yt:done" "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '1.0' and msg like 'yt:%' limit 1")"
check "W3f the worker is idle again" "idle" "$(info "$O" E sge)"
q "$F" "insert into $HIST (source, target, source_type, version, msg) values ('roll', 'nobody', 'Y', '0.1', 'yt:pending')" >/dev/null
sleep 8
check "W3g a row for no node of the cluster starts nothing" "0" "$(q "$F" "select count(*) from $HIST where target = '$(node_uuid "$F")' and version = '0.1'")"
q "$F" "delete from $HIST where target = 'nobody'" >/dev/null

echo "-- W4 a failure halts the roll"
q "$G" "create table sw_block (x int)" >/dev/null    # the script creates it: fails on this node alone
script "V2_0__block.sql" "create table sw_block (x int);"
roll "$O" 2.0
left="$(wait_msg 2.0 yt:failed 120 "$G")" && ok "W4 $G says it failed: $(msg_of "$G" 2.0 | cut -c1-70)" || bad "W4 $G did not fail:$left"
sleep 6
check "W4b the leader is not reached" "" "$(msg_of "$L" 2.0)"
script "V3_0__c.sql" "alter table $T add column c int;"
roll "$F" 3.0
for ((i = 0; i < 30; i += 2)); do case "$(q "$F" "select msg from $HIST where coalesce(target,'') = '' and version = '3.0' and msg like 'yt:%' limit 1")" in yt:failed*) break;; esac; sleep 2; done
case "$(q "$F" "select msg from $HIST where coalesce(target,'') = '' and version = '3.0' and msg like 'yt:%' limit 1")" in
	yt:failed*) ok "W4c a second roll is refused while one is halted";;
	*) bad "W4c a second roll started while one is halted";;
esac
q "$F" "delete from $HIST where coalesce(target,'') = '' and version = '3.0'" >/dev/null
case "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '2.0' and msg like 'yt:%' limit 1")" in
	"yt:failed halted"*) ok "W4e the operator's row says halted";;
	*) bad "W4e the operator's row does not say halted";;
esac
rh "docker stop -t 2 $G >/dev/null" 2>/dev/null; echo "  $G stopped, its failed row with it"
sleep 45
check "W4f the failed node down: the leader still not reached" "" "$(msg_of "$L" 2.0)"
case "$(q "$L" "select msg from $HIST where coalesce(target,'') = '' and version = '2.0' and msg like 'yt:%' limit 1")" in
	"yt:failed halted"*) ok "W4g the leader knows it is halted";;
	*) bad "W4g the leader does not say halted";;
esac
rh "docker start $G >/dev/null" 2>/dev/null
node_ready "$G"
q "$G" "drop table sw_block" >/dev/null
q "$G" "update $HIST set msg = 'yt:pending', ok = false where target = '$(node_uuid "$G")' and version = '2.0'" >/dev/null
left="$(wait_msg 2.0 yt:done 150 "${NODES[@]}")" && ok "W4d set back by the operator, it finishes" || bad "W4d not done on:$left"
op_wait "$O" 2.0 yt:done && ok "W4h the roll's end said on its row" || bad "W4h the operator's row: [$(op_msg "$O" 2.0)]"
same_schema W4
for n in "${NODES[@]}"; do q "$n" "drop table if exists sw_block" >/dev/null; done
rm_scripts() { local n; for n in "${NODES[@]}"; do rh "docker exec $n rm -f $DIR/$1" 2>/dev/null; done; }
rm_scripts "V2_0__block.sql"; rm_scripts "V3_0__c.sql"

echo "-- W5 the worker's node dies mid-roll"
script "V4_0__slow.sql" "select pg_sleep(10); alter table $T add column d int;"
roll "$O" 4.0
wait_msg 4.0 yt:done 60 "$O" >/dev/null || bad "W5 the origin did not finish its part"
told_another 4.0 "$O" || bad "W5 no other node told"
rh "docker kill $O >/dev/null" 2>/dev/null
echo "  $O killed"
others=(); for n in "${NODES[@]}"; do [ "$n" = "$O" ] || others+=("$n"); done
left="$(wait_msg 4.0 yt:done 240 "${others[@]}")" && ok "W5 the leader took it over: done on the others" || bad "W5 not done on:$left"
rh "docker start $O >/dev/null" 2>/dev/null
node_ready "$O"
left="$(wait_msg 4.0 yt:done 120 "$O")" && ok "W5b back, its part stands" || bad "W5b $O:$left"
for ((i = 0; i < 90; i += 3)); do [ "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '4.0' and msg like 'yt:%' limit 1")" = "yt:done" ] && break; sleep 3; done
check "W5c its row closed" "yt:done" "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '4.0' and msg like 'yt:%' limit 1")"
same_schema W5
await_cluster; L="$(leader)"

echo "-- W6 a node away"
FOLLOWERS=(); for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"; G="${FOLLOWERS[2]}"; H="${FOLLOWERS[3]}"
script "V5_0__e.sql" "alter table $T add column e int;"
rh "docker stop -t 2 $G >/dev/null" 2>/dev/null
echo "  $G stopped"
roll "$O" 5.0
others=(); for n in "${NODES[@]}"; do [ "$n" = "$G" ] || others+=("$n"); done
left="$(wait_msg 5.0 yt:done 240 "${others[@]}")" && ok "W6 the others go on" || bad "W6 not done on:$left"
check "W6b not finished while it is away" "yt:roll" "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '5.0' and msg like 'yt:%' limit 1")"
rh "docker start $G >/dev/null" 2>/dev/null
node_ready "$G"
left="$(wait_msg 5.0 yt:done 180 "$G")" && ok "W6c back, it gets it too" || bad "W6c $G:$left"
for ((i = 0; i < 60; i += 3)); do [ "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '5.0' and msg like 'yt:%' limit 1")" = "yt:done" ] && break; sleep 3; done
check "W6d then it is finished" "yt:done" "$(q "$O" "select msg from $HIST where coalesce(target,'') = '' and version = '5.0' and msg like 'yt:%' limit 1")"
same_schema W6
await_cluster; L="$(leader)"

echo "-- W7 the leader as the origin"
script "V6_0__f.sql" "alter table $T add column f int;"
roll "$L" 6.0
left="$(wait_msg 6.0 yt:done 180 "${NODES[@]}")" && ok "W7 every node has it" || bad "W7 not done on:$left"
tl="$(when_of "$L" 6.0)"; first=1
for n in "${NODES[@]}"; do
	[ "$n" = "$L" ] && continue
	python3 -c "import sys; sys.exit(0 if $tl <= $(when_of "$n" 6.0) else 1)" || first=0
done
check "W7b it starts on the leader" "1" "$first"

echo "-- W8 all at once"
e="$(cfg_put sge_all_at_once '*')"; [ -z "$e" ] || bad "W8 sge_all_at_once: $e"
for ((i = 0; i < 30; i += 2)); do [ "$(info "$O" E cfg.sge_all_at_once)" = "*" ] && [ "$(info "$H" E cfg.sge_all_at_once)" = "*" ] && break; sleep 2; done
script "V7_0__g.sql" "select pg_sleep(6); alter table $T add column g int;"
roll "$O" 7.0
left="$(wait_msg 7.0 yt:done 120 "${NODES[@]}")" && ok "W8 every node has it" || bad "W8 not done on:$left"
op_wait "$O" 7.0 yt:done || bad "W8 the operator's row: [$(op_msg "$O" 7.0)]"
times="$(for n in "${NODES[@]}"; do when_of "$n" 7.0; done)"
spread="$(printf '%s\n' "$times" | python3 -c "import sys; t=[float(x) for x in sys.stdin if x.strip()]; print(int(max(t)-min(t)))")" || spread=99
[ "${spread:-99}" -lt 12 ] && ok "W8b together: within ${spread}s, each sleeping 6s" || bad "W8b in turn: ${spread}s apart"
q "$G" "create table sw_block (x int)" >/dev/null
script "V8_0__block.sql" "create table sw_block (x int);"
roll "$O" 8.0
left="$(wait_msg 8.0 yt:failed 120 "$G")" && ok "W8c $G failed" || bad "W8c $G:$left"
others=(); for n in "${NODES[@]}"; do [ "$n" = "$G" ] || others+=("$n"); done
left="$(wait_msg 8.0 yt:done 120 "${others[@]}")" && ok "W8d the others finish" || bad "W8d not done on:$left"
q "$G" "drop table sw_block" >/dev/null
q "$G" "update $HIST set msg = 'yt:pending', ok = false where target = '$(node_uuid "$G")' and version = '8.0'" >/dev/null
left="$(wait_msg 8.0 yt:done 120 "$G")" && ok "W8e set back, it finishes" || bad "W8e $G:$left"
op_wait "$O" 8.0 yt:done && ok "W8f the roll's end said on its row" || bad "W8f the operator's row: [$(op_msg "$O" 8.0)]"
case "$(info "$O" E sge)" in "halted"*) bad "W8g its origin still says: $(info "$O" E sge)";; *) ok "W8g its origin no longer says halted";; esac
for n in "${NODES[@]}"; do q "$n" "drop table if exists sw_block" >/dev/null; done
rm_scripts "V8_0__block.sql"

echo "-- W9 all at once by table"
e="$(cfg_put sge_all_at_once 'public.sw_named')"; [ -z "$e" ] || bad "W9 sge_all_at_once: $e"
for ((i = 0; i < 30; i += 2)); do [ "$(info "$O" E cfg.sge_all_at_once)" = "public.sw_named" ] && [ "$(info "$H" E cfg.sge_all_at_once)" = "public.sw_named" ] && break; sleep 2; done
script "V9_0__s.sql" "select pg_sleep(4);"
roll "$O" 9.0 public.sw_named
left="$(wait_msg 9.0 yt:done 120 "${NODES[@]}")" && ok "W9 named: every node has it" || bad "W9 not done on:$left [$(op_msg "$O" 9.0)]"
op_wait "$O" 9.0 yt:done || bad "W9 the operator's row: [$(op_msg "$O" 9.0)]"
spread="$(for n in "${NODES[@]}"; do when_of "$n" 9.0; done | python3 -c "import sys; t=[float(x) for x in sys.stdin if x.strip()]; print(int(max(t)-min(t)))")" || spread=99
[ "${spread:-99}" -lt 8 ] && ok "W9b the named table together: ${spread}s" || bad "W9b ${spread}s apart"
script "V10_0__s.sql" "select pg_sleep(3);"
roll "$O" 10.0
left="$(wait_msg 10.0 yt:done 180 "${NODES[@]}")" && ok "W9c unnamed: every node has it" || bad "W9c not done on:$left"
spread="$(for n in "${NODES[@]}"; do when_of "$n" 10.0; done | python3 -c "import sys; t=[float(x) for x in sys.stdin if x.strip()]; print(int(max(t)-min(t)))")" || spread=99
[ "${spread:-0}" -ge 9 ] && ok "W9d the others in turn: ${spread}s" || bad "W9d only ${spread}s apart, in turn"
e="$(cw "$L" "delete from $YX_CFG where module='C' and name='sge_all_at_once'")"; [ -z "$e" ] || bad "W9 removing sge_all_at_once: $e"

echo "-- W10 the nemeses: nodes dropping during a roll, writes going on"
await_cluster; L="$(leader)"
FOLLOWERS=(); for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"; G="${FOLLOWERS[2]}"; H="${FOLLOWERS[3]}"
for n in "${NODES[@]}"; do q "$n" "create table if not exists $LOAD (id int primary key, v text)" >/dev/null; done
register_table "public.$LOAD"
restart_all >/dev/null 2>&1 || true
await_cluster; L="$(leader)"
FOLLOWERS=(); for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"; G="${FOLLOWERS[2]}"; H="${FOLLOWERS[3]}"
# the writer: each row acknowledged goes in the file, on a voter that happens to be up
(
	id=0
	while [ ! -e "$TMP/stop" ]; do
		id=$((id + 1))
		n="${VOTERS[$((id % ${#VOTERS[@]}))]}"
		if [ -z "$(cw "$n" "insert into $LOAD (id, v) values ($id, 'w$id')")" ]; then echo "$id" >> "$TMP/acked"; fi
		sleep 0.3
	done
) &
WRITER=$!
script "V11_0__n.sql" "select pg_sleep(8); alter table $T add column n int;"
roll "$O" 11.0
sleep 4
# killed: its ytserv and PostgreSQL gone at once
rh "docker kill $F >/dev/null" 2>/dev/null; echo "  nemesis: $F killed"
sleep 12
rh "docker start $F >/dev/null" 2>/dev/null; echo "  nemesis: $F back"
# paused: everything on it stopped, the socket still open
rh "docker pause $G >/dev/null" 2>/dev/null; echo "  nemesis: $G paused"
sleep 12
rh "docker unpause $G >/dev/null" 2>/dev/null; echo "  nemesis: $G resumed"
# cut off the network
node_down "$H"
sleep 12
node_up "$H"
# two down together
rh "docker kill $F >/dev/null" 2>/dev/null; rh "docker stop -t 1 $H >/dev/null" 2>/dev/null; echo "  nemesis: $F and $H down together"
sleep 15
rh "docker start $F >/dev/null" 2>/dev/null; rh "docker start $H >/dev/null" 2>/dev/null; echo "  nemesis: both back"
node_ready "$F"; node_ready "$H"
left="$(wait_msg 11.0 yt:done 400 "${NODES[@]}")" && ok "W10 every node has it" || bad "W10 not done on:$left"
same_schema W10
touch "$TMP/stop"; wait "$WRITER" 2>/dev/null
acked="$(wc -l < "$TMP/acked" 2>/dev/null || echo 0)"
[ "${acked:-0}" -gt 10 ] && ok "W10b writes went on during it: $acked acknowledged" || bad "W10b only ${acked:-0} writes acknowledged"
await_cluster
# recon brings a node that was away up to the others
digest="select count(*) || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '') from $LOAD"
d="x"
for ((i = 0; i < 240; i += 5)); do d="$(differing "$digest")"; [ -z "$d" ] && break; sleep 5; done
[ -z "$d" ] && ok "W10c every node holds the same rows" || bad "W10c the rows differ:$d"
have="$(q "$L" "select id from $LOAD")"
lost="$(sort -n "$TMP/acked" 2>/dev/null | while read -r a; do printf '%s\n' "$have" | grep -qx "$a" || echo "$a"; done | wc -l)"
check "W10d no acknowledged write lost" "0" "$lost"

# the helpers for sources the nodes do not share
mkzip() { # mkzip <file> <name>=<sql> ...
	python3 -I - "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
    for a in sys.argv[2:]:
        n, s = a.split('=', 1)
        z.writestr(n, s)
PY
}
put_file() { # put_file <node> <local file> <path on the node>
	rh "docker exec -i $1 sh -c 'mkdir -p $(dirname "$3") && cat > $3 && chmod -R a+rX $(dirname "$3")'" < "$2"
}
set_source() { # set_source "name=value; ...": through the sync path, and every node has them
	local e i n left want sql="select coalesce(string_agg(name || '=' || value, ';' order by name), '') from $YX_CFG where module='M'"
	e="$(sge_put "$1")"; [ -z "$e" ] || bad "module M $1: $e"
	want="$(q "$L" "$sql")"
	for ((i = 0; i < 40; i += 2)); do
		left=""
		for n in "${NODES[@]}"; do [ "$(q "$n" "$sql")" = "$want" ] || left=1; done
		# and their rows are read at most every 2 s
		[ -z "$left" ] && { sleep 3; return 0; }
		sleep 2
	done
	bad "module M did not reach every node"
}
row_note() { q "$1" "select coalesce(script_tag,'') || ' ' || coalesce(checksum,'') || ' ' || size from $HIST where target = '$(node_uuid "$1")' and version = '$2' order by id desc limit 1"; }
each_row_says() { # each_row_says <version> <text> -> the nodes whose row says otherwise
	local n out=""
	for n in "${NODES[@]}"; do [ "$(row_note "$n" "$1")" = "$2" ] || out="$out $n=[$(row_note "$n" "$1")]"; done
	echo "$out"
}
fresh_nodes() {
	await_cluster; L="$(leader)"
	FOLLOWERS=(); for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || FOLLOWERS+=("$n"); done
	O="${FOLLOWERS[0]}"; F="${FOLLOWERS[1]}"; G="${FOLLOWERS[2]}"; H="${FOLLOWERS[3]}"
}

echo "-- W11 a zip, on the origin alone"
fresh_nodes
# git beside it is not asked: a zip is first, and this address answers nothing
set_source "source_zip=$ZDIR/rel.zip; source_git=https://example.invalid/none.git"
roll "$F" 20.0
op_wait "$F" 20.0 yt:failed && ok "W11 from a node without the archive, refused: $(op_msg "$F" 20.0 | cut -c1-70)" || bad "W11 a roll with no archive: [$(op_msg "$F" 20.0)]"
q "$F" "delete from $HIST where version = '20.0'" >/dev/null
Z="$TMP/rel.zip"
mkzip "$Z" "V20_0__z.sql=alter table $T add column z int;"
md5="$(md5sum "$Z" | cut -c1-32)"; size="$(stat -c %s "$Z")"
want="zip:rel.zip@${md5:0:12} $md5 $size"
put_file "$O" "$Z" "$ZDIR/rel.zip"
roll "$O" 20.0
left="$(wait_msg 20.0 yt:done 180 "${NODES[@]}")" && ok "W11b carried to every node" || bad "W11b not done on:$left"
same_schema W11b
check "W11c the column" "1" "$(q "$L" "select count(*) from information_schema.columns where table_name = '$T' and column_name = 'z'")"
d="$(each_row_says 20.0 "$want")"
[ -z "$d" ] && ok "W11d every node's row: $want" || bad "W11d the rows differ, not [$want]:$d"
rh "docker exec $F test -e $ZDIR/rel.zip" 2>/dev/null && bad "W11e a file at the path on $F" || ok "W11e nothing written where the operator names"

# another file at that path on one node: the origin's is what rolls
Y="$TMP/other.zip"
mkzip "$Y" "V21_0__wrong.sql=alter table $T add column wrong int;"
put_file "$G" "$Y" "$ZDIR/rel.zip"
mkzip "$Z" "V21_0__y.sql=alter table $T add column y int;"
md5="$(md5sum "$Z" | cut -c1-32)"; size="$(stat -c %s "$Z")"
want="zip:rel.zip@${md5:0:12} $md5 $size"
put_file "$O" "$Z" "$ZDIR/rel.zip"
roll "$O" 21.0
left="$(wait_msg 21.0 yt:done 180 "${NODES[@]}")" && ok "W11f another file on $G: every node has it" || bad "W11f not done on:$left"
same_schema W11f
check "W11g the origin's scripts on $G" "1:0" "$(q "$G" "select count(*) filter (where column_name = 'y') || ':' || count(*) filter (where column_name = 'wrong') from information_schema.columns where table_name = '$T'")"
d="$(each_row_says 21.0 "$want")"
[ -z "$d" ] && ok "W11h every row the same archive" || bad "W11h:$d"

# the origin gone with the first copy: the others carry on from theirs
mkzip "$Z" "V22_0__x.sql=select pg_sleep(8); alter table $T add column x int;"
md5="$(md5sum "$Z" | cut -c1-32)"; size="$(stat -c %s "$Z")"
want="zip:rel.zip@${md5:0:12} $md5 $size"
put_file "$O" "$Z" "$ZDIR/rel.zip"
roll "$O" 22.0
wait_msg 22.0 yt:done 60 "$O" >/dev/null || bad "W11i the origin did not finish its part"
told_another 22.0 "$O" || bad "W11i no other node told"
rh "docker kill $O >/dev/null" 2>/dev/null; echo "  $O killed, holding the archive"
others=(); for n in "${NODES[@]}"; do [ "$n" = "$O" ] || others+=("$n"); done
left="$(wait_msg 22.0 yt:done 240 "${others[@]}")" && ok "W11i the origin killed: the others have it from a copy" || bad "W11i not done on:$left"
rh "docker start $O >/dev/null" 2>/dev/null
node_ready "$O"
left="$(wait_msg 22.0 yt:done 120 "$O")" && ok "W11j back, its part stands" || bad "W11j $O:$left"
same_schema W11i
d="$(each_row_says 22.0 "$want")"
[ -z "$d" ] && ok "W11k every row the same archive" || bad "W11k:$d"

echo "-- W12 a folder, on the origin alone"
fresh_nodes
for n in "${NODES[@]}"; do rh "docker exec $n rm -rf $DIR" 2>/dev/null; done
set_source "source_dir=$DIR"
roll "$F" 30.0
op_wait "$F" 30.0 yt:failed && ok "W12 from a node without the folder, refused: $(op_msg "$F" 30.0 | cut -c1-70)" || bad "W12 a roll with no folder: [$(op_msg "$F" 30.0)]"
q "$F" "delete from $HIST where version = '30.0'" >/dev/null
printf '%s\n' "alter table $T add column w int;" | rh "docker exec -i $O sh -c 'mkdir -p $DIR/sub && cat > $DIR/V30_0__w.sql && chmod -R a+rX $DIR'"
roll "$O" 30.0
left="$(wait_msg 30.0 yt:done 180 "${NODES[@]}")" && ok "W12b zipped and carried to every node" || bad "W12b not done on:$left"
same_schema W12b
check "W12c the column" "1" "$(q "$L" "select count(*) from information_schema.columns where table_name = '$T' and column_name = 'w'")"
tags="$(for n in "${NODES[@]}"; do row_note "$n" 30.0; done | sort -u)"
case "$tags" in
	"zip:sge_w.zip@"*) [ "$(printf '%s\n' "$tags" | wc -l)" = 1 ] && ok "W12d one archive on every row: $tags" || bad "W12d several: $tags";;
	*) bad "W12d not an archive: $tags";;
esac

echo "-- W13 git, each node its own clone"
fresh_nodes
R="$TMP/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
printf 'not a script\n' > "$R/README"
git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" checkout -q -b rel
printf 'alter table %s add column g1 int;\n' "$T" > "$R/V40_0__g.sql"
git -C "$R" add -A; git -C "$R" commit -qm one
first="$(git -C "$R" rev-parse HEAD)"
ship_repo() { # ship_repo <node>: its own copy of the repository
	tar -C "$TMP" -cf "$TMP/repo.tar" repo
	# beside it, then moved in: a node whose turn it is must not find it half there
	rh "docker exec -i $1 sh -c 'rm -rf $GDIR.new $GDIR.old && mkdir -p $GDIR.new && tar -C $GDIR.new -xf - && chmod -R a+rX $GDIR.new && git config --system --add safe.directory \"*\" && { [ ! -e $GDIR ] || mv $GDIR $GDIR.old; } && mv $GDIR.new $GDIR'" < "$TMP/repo.tar"
}
for n in "${NODES[@]}"; do ship_repo "$n"; done
set_source "source_git=file://$GDIR/repo; source_git_ref=rel"
roll "$O" 41.0
wait_msg 41.0 yt:done 120 "$O" >/dev/null || bad "W13 the first node did not finish"
# the branch moves, with a script the target would take: no node is to run it
printf 'alter table %s add column g2 int;\n' "$T" > "$R/V40_1__g.sql"
git -C "$R" add -A; git -C "$R" commit -qm two
for n in "${NODES[@]}"; do ship_repo "$n"; done
left="$(wait_msg 41.0 yt:done 180 "${NODES[@]}")" && ok "W13 every node has it" || bad "W13 not done on:$left"
same_schema W13
check "W13b the commit resolved before the roll on every node, not the branch's next" "1:0" "$(q "$L" "select count(*) filter (where column_name = 'g1') || ':' || count(*) filter (where column_name = 'g2') from information_schema.columns where table_name = '$T'")"
tags="$(for n in "${NODES[@]}"; do q "$n" "select script_tag from $HIST where target = '$(node_uuid "$n")' and version = '41.0' order by id desc limit 1"; done | sort -u)"
check "W13c every row that commit" "$first" "$tags"

echo "-- W14 ytserv killed under its psql, between two scripts"
fresh_nodes
for n in "${NODES[@]}"; do
	q "$n" "create table if not exists sw_once (id int primary key); create table if not exists sw_once_mark (x int)" >/dev/null
	rh "docker exec $n rm -rf $DIR" 2>/dev/null
done
set_source "source_dir=$DIR"
printf '%s\n' "insert into sw_once values (1);" | rh "docker exec -i $O sh -c 'mkdir -p $DIR && cat > $DIR/V50_0__one.sql'"
# the first run outlasts the restart, and is ended by it; none after sleeps: a script's row comes
# after it, so one that ended in that moment is run again, as sge_worker.md says
printf '%s\n' "select pg_sleep(120) where not exists (select 1 from sw_once_mark); insert into sw_once values (2);" | rh "docker exec -i $O sh -c 'cat > $DIR/V50_1__two.sql && chmod -R a+rX $DIR'"
roll "$O" 51.0
going=0
for ((i = 0; i < 60; i += 1)); do
	[ "$(q "$O" "select count(*) from pg_stat_activity where application_name = 'sge-roll' and query like '%pg_sleep%'")" = "1" ] && { going=1; break; }
	sleep 1
done
[ "$going" = 1 ] && ok "W14 the second script is going" || bad "W14 the second script never showed"
check "W14a the first script ran" "1" "$(q "$O" "select count(*) from sw_once")"
# its command kept, for after: the entrypoint holds the container open, and starts no other. The
# su around it, as the entrypoint gave it: root's to run, and it reads the app key itself
rh "docker exec $O sh -c 'cat /proc/\$(pgrep -f \"^su postgres\" | head -1)/cmdline > /tmp/yt.cmd'"
rh "docker exec $O pkill -9 -f yt-cluster/ytserv >/dev/null 2>&1; true"
echo "  $O ytserv killed, its psql left going"
check "W14b the script's row is there already" "1" "$(q "$O" "select count(*) from $HIST where source = 'V50_0__one.sql' and ok")"
for n in "${NODES[@]}"; do q "$n" "insert into sw_once_mark values (1)" >/dev/null; done
rh "docker exec -d $O sh -c 'exec xargs -0 -a /tmp/yt.cmd env >> /tmp/yt.w14.log 2>&1'"
left="$(wait_msg 51.0 yt:done 240 "${NODES[@]}")" && ok "W14c it finishes, on every node" || bad "W14c not done on:$left"
d="$(differing "select string_agg(id::text, ',' order by id) from sw_once")"
[ -z "$d" ] && ok "W14d each script once, on every node" || bad "W14d:$d"
check "W14e and no more than each" "1,2" "$(q "$O" "select string_agg(id::text, ',' order by id) from sw_once")"
check "W14f the script left going is ended" "0" "$(q "$O" "select count(*) from pg_stat_activity where application_name = 'sge-roll'")"
for n in "${NODES[@]}"; do q "$n" "drop table if exists sw_once; drop table if exists sw_once_mark" >/dev/null; done

echo "-- W15 abandoned by its operator"
fresh_nodes
for n in "${NODES[@]}"; do rh "docker exec $n rm -rf $DIR" 2>/dev/null; done
q "$G" "create table sw_block (x int)" >/dev/null
printf '%s\n' "create table sw_block (x int);" | rh "docker exec -i $O sh -c 'mkdir -p $DIR && cat > $DIR/V60_0__block.sql && chmod -R a+rX $DIR'"
roll "$O" 60.0
left="$(wait_msg 60.0 yt:failed 180 "$G")" && ok "W15 $G failed" || bad "W15 $G:$left"
sleep 4
for n in "${NODES[@]}"; do q "$n" "update $HIST set msg = 'yt:abandoned', ok = false where msg like 'yt:%' and version = '60.0'" >/dev/null; done
q "$G" "drop table sw_block" >/dev/null
sleep 35   # two of a leader's looks
check "W15b no leader finished it" "" "$(q "$L" "select msg from $HIST where target = '$(node_uuid "$L")' and version = '60.0' and msg <> 'yt:abandoned'")"
rh "docker exec $O rm -f $DIR/V60_0__block.sql" 2>/dev/null
printf '%s\n' "alter table $T add column ab int;" | rh "docker exec -i $O sh -c 'cat > $DIR/V61_0__ab.sql && chmod -R a+rX $DIR'"
roll "$O" 61.0
left="$(wait_msg 61.0 yt:done 180 "${NODES[@]}")" && ok "W15c a later version goes" || bad "W15c not done on:$left"
same_schema W15c
for n in "${NODES[@]}"; do q "$n" "drop table if exists sw_block" >/dev/null; done

echo "-- W16 a node that cannot write its row"
fresh_nodes
printf '%s\n' "alter table $T add column cw int;" | rh "docker exec -i $O sh -c 'mkdir -p $DIR && cat > $DIR/V80_0__cw.sql && chmod -R a+rX $DIR'"
roll "$O" 80.0
q "$G" "alter table $HIST rename to sw_hist_away" >/dev/null
for ((i = 0; i < 120; i += 2)); do case "$(op_msg "$O" 80.0)" in "yt:failed halted"*) break;; esac; sleep 2; done
case "$(op_msg "$O" 80.0)" in
	"yt:failed halted"*) ok "W16 the roll halts: $(op_msg "$O" 80.0 | cut -c1-70)";;
	*) bad "W16 not halted: [$(op_msg "$O" 80.0)]";;
esac
case "$(op_msg "$O" 80.0)" in *"does not exist"*) ok "W16a in the database's words";; *) bad "W16a [$(op_msg "$O" 80.0)]";; esac
check "W16b the leader not reached" "" "$(msg_of "$L" 80.0)"
q "$G" "alter table public.sw_hist_away rename to sge_history" >/dev/null
sleep 62   # what it said has gone by
q "$O" "update $HIST set msg = 'yt:roll', ok = false where coalesce(target,'') = '' and version = '80.0' and msg like 'yt:%'" >/dev/null
left="$(wait_msg 80.0 yt:done 180 "${NODES[@]}")" && ok "W16c set back by its operator, it finishes" || bad "W16c not done on:$left"
same_schema W16c

echo "-- W17 a node never told a halted roll finished"
# as if its message was lost: a row still says halted, and every node's own says done
q "$G" "insert into $HIST (source, source_type, version, msg) values ('roll', 'Y', '80.0', 'yt:failed halted as if never told')" >/dev/null
told=""
for ((i = 0; i < 60; i += 2)); do
	told="$(q "$G" "select count(*) from $HIST where version = '80.0' and msg like 'yt:failed halted%'")"
	[ "$told" = 0 ] && break
	sleep 2
done
check "W17 a leader tells it again" "0" "$told"
printf '%s\n' "alter table $T add column cx int;" | rh "docker exec -i $O sh -c 'cat > $DIR/V81_0__cx.sql && chmod -R a+rX $DIR'"
roll "$O" 81.0
left="$(wait_msg 81.0 yt:done 180 "${NODES[@]}")" && ok "W17b a later version goes" || bad "W17b not done on:$left"
same_schema W17b

check_row() { # check_row <node> <version> <yt:plan|yt:snapshot>: the operator's row -> its id
	q "$1" "insert into $HIST (source, source_type, version, msg) values ('check', 'Y', '$2', '$3') returning id"
}
check_wait() { # check_wait <node> <id> <seconds>: until the row is answered -> what it says
	local i m
	for ((i = 0; i < $3; i += 2)); do
		m="$(q "$1" "select msg from $HIST where id = $2")"
		case "$m" in yt:plan|yt:snapshot|yt:dump|"") ;; *) printf '%s' "$m"; return 0;; esac
		sleep 2
	done
	printf '%s' "$m"
	return 1
}
check_states() { # what each node's answer was, for a failure's message
	q "$1" "select node || ' ' || state from ${HIST}_check where history_id = $2 order by node" | tr '\n' ';'
}

echo "-- W18 a plan every node makes, compared"
fresh_nodes
set_source "source_dir=$DIR"
printf '%s\n' "alter table $T add column pc int;" | rh "docker exec -i $O sh -c 'cat > $DIR/V90_0__pc.sql && chmod -R a+rX $DIR'"
id="$(check_row "$O" 90.0 yt:plan)"
m="$(check_wait "$O" "$id" 180)"
check "W18 every node makes the same plan [$(check_states "$O" "$id" | cut -c1-200)]" "yt:same" "$m"
check "W18b each node's text is there" "${#NODES[@]}" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and kind = 'plan' and state = 'same' and body like '%V90_0__pc.sql%add pc%'")"
check "W18c the text does not name a node's own" "0" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and body like '%sge-tmp%'")"
d=""; for n in "${NODES[@]}"; do [ "$(q "$n" "select count(*) from information_schema.columns where table_name = '$T' and column_name = 'pc'")" = 0 ] || d="$d $n"; [ -z "$(msg_of "$n" 90.0)" ] || d="$d $n:row"; done
[ -z "$d" ] && ok "W18d nothing applied, and no node has a row of its own" || bad "W18d:$d"
check "W18e the row does not say applied" "f" "$(q "$O" "select ok from $HIST where id = $id")"
roll "$O" 90.0
left="$(wait_msg 90.0 yt:done 180 "${NODES[@]}")" && ok "W18f the version it planned still rolls" || bad "W18f not done on:$left"
same_schema W18f
id="$(check_row "$O" 90.0 yt:plan)"
m="$(check_wait "$O" "$id" 180)"
check "W18g after the roll: the same" "yt:same" "$m"
check "W18h and nothing left to do" "0" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and body like '%V90_0__pc.sql%'")"
id="$(check_row "$F" 90.0 yt:plan)"
m="$(check_wait "$F" "$id" 60)"
case "$m" in "yt:failed"*"sge_w"*) ok "W18i from a node without the folder: refused, and it says why";; *) bad "W18i [$m]";; esac

echo "-- W19 a snapshot every node makes"
fresh_nodes
id="$(check_row "$O" 0 yt:snapshot)"
m="$(check_wait "$O" "$id" 120)"
check "W19 every node's schema the same [$(check_states "$O" "$id" | cut -c1-200)]" "yt:same" "$m"
check "W19b one text, from every node" "${#NODES[@]}:1" "$(q "$O" "select count(*) || ':' || count(distinct md5) from ${HIST}_check where history_id = $id")"
check "W19c it holds the application's table" "${#NODES[@]}" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and body like '%tableName: $T%'")"
check "W19d not the cluster's own" "0" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and (body like '%tableName: sge_history%' or body like '%tableName: yt_config%')")"
check "W19e the worker is idle again" "idle" "$(info "$O" E sge)"
# the last checks are kept, each with its row: older ones must not push a roll's rows out of
# what a node looks at
for i in $(seq 1 25); do
	old="$(q "$O" "insert into $HIST (source, source_type, version, msg) values ('check', 'Y', '0', 'yt:same') returning id")"
	q "$O" "insert into ${HIST}_check (history_id, kind, node, state) values ($old, 'snapshot', 'n', 'same')" >/dev/null
done
id="$(check_row "$O" 0 yt:snapshot)"
check_wait "$O" "$id" 120 >/dev/null || true
check "W19f the last 20 checks kept" "20" "$(q "$O" "select count(distinct history_id) from ${HIST}_check")"
check "W19g an older one's history row gone with it" "$(q "$O" "select count(distinct history_id) from ${HIST}_check")" "$(q "$O" "select count(*) from $HIST where source = 'check' and msg like 'yt:same%'")"

echo "-- W20 a table on one node alone"
fresh_nodes
q "$G" "create table sw_only_one (x int)" >/dev/null
id="$(check_row "$O" 0 yt:snapshot)"
m="$(check_wait "$O" "$id" 120)"
check "W20 that node is named" "yt:differs $(node_uuid "$G")" "$m"
check "W20b its text shows the table" "1" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and state = 'differs' and node = '$(node_uuid "$G")' and body like '%tableName: sw_only_one%'")"
check "W20c the others do not" "$(( ${#NODES[@]} - 1 ))" "$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and state = 'same' and body not like '%sw_only_one%'")"
q "$G" "drop table sw_only_one" >/dev/null
id="$(check_row "$O" 0 yt:snapshot)"
check "W20d dropped, the same again" "yt:same" "$(check_wait "$O" "$id" 120)"

echo "-- W21 a node down"
fresh_nodes
rh "docker stop -t 2 $G >/dev/null" 2>/dev/null; echo "  $G stopped"
id="$(check_row "$O" 0 yt:snapshot)"
m="$(check_wait "$O" "$id" 180)"
check "W21 no answer, never the same" "yt:differs no answer: $(node_uuid "$G")" "$m"
check "W21b the table says so" "no answer" "$(q "$O" "select state from ${HIST}_check where history_id = $id and node = '$(node_uuid "$G")'")"
rh "docker start $G >/dev/null" 2>/dev/null
node_ready "$G"
await_cluster
id="$(check_row "$O" 0 yt:snapshot)"
check "W21c back, the same again" "yt:same" "$(check_wait "$O" "$id" 120)"

echo "-- W22 a check during a roll"
fresh_nodes
printf '%s\n' "select pg_sleep(25); alter table $T add column cr int;" | rh "docker exec -i $O sh -c 'cat > $DIR/V91_0__slow.sql && chmod -R a+rX $DIR'"
roll "$O" 91.0
for ((i = 0; i < 60; i += 1)); do [ "$(msg_of "$O" 91.0)" = "yt:pending" ] && break; sleep 1; done
id="$(check_row "$F" 91.0 yt:plan)"
m="$(check_wait "$F" "$id" 60)"
case "$m" in "yt:failed"*"in progress"*) ok "W22 refused: $(printf '%s' "$m" | cut -c1-70)";; *) bad "W22 not refused: [$m]";; esac
check "W22a it is on record as refused" "refused" "$(q "$F" "select state from ${HIST}_check where history_id = $id")"
left="$(wait_msg 91.0 yt:done 240 "${NODES[@]}")" && ok "W22b the roll is not disturbed" || bad "W22b not done on:$left"
same_schema W22b

echo "-- W23 a CI's commit on the rows, while the branch moves on"
fresh_nodes
printf 'alter table %s add column ci1 int;\n' "$T" > "$R/V95_0__ci.sql"
git -C "$R" add -A; git -C "$R" commit -qm ci1
c1="$(git -C "$R" rev-parse HEAD)"
printf 'alter table %s add column ci2 int;\n' "$T" > "$R/V95_1__ci.sql"
git -C "$R" add -A; git -C "$R" commit -qm ci2
c2="$(git -C "$R" rev-parse HEAD)"
for n in "${NODES[@]}"; do ship_repo "$n"; done
set_source "source_git=file://$GDIR/repo; source_git_ref=rel"
ci_row() { # ci_row <node> <version> <msg> <script_tag>: a CI's row -> its id
	q "$1" "insert into $HIST (source, source_type, version, msg, script_tag) values ('ci', 'Y', '$2', '$3', '$4') returning id"
}
id="$(ci_row "$O" 95.1 yt:plan "$c1")"
m="$(check_wait "$O" "$id" 180)"
check "W23 the plan of the commit named, the same on every node [$(check_states "$O" "$id" | cut -c1-200)]" "yt:same" "$m"
check "W23b its row keeps that commit" "$c1" "$(q "$O" "select script_tag from $HIST where id = $id")"
check "W23c that commit's script in every node's plan, not the branch's next" "${#NODES[@]}:0" \
	"$(q "$O" "select count(*) filter (where body like '%V95_0__ci.sql%') || ':' || count(*) filter (where body like '%V95_1__ci.sql%') from ${HIST}_check where history_id = $id")"
rid="$(ci_row "$O" 95.1 yt:roll "$c1")"
left="$(wait_msg 95.1 yt:done 240 "${NODES[@]}")" && ok "W23d the roll of that commit, done on every node" || bad "W23d not done on:$left"
# its row says so once its worker lets go, and a plan is refused before that
for ((i = 0; i < 60; i += 2)); do [ "$(q "$O" "select msg from $HIST where id = $rid")" = yt:done ] && break; sleep 2; done
cols="select count(*) filter (where column_name = 'ci1') || ':' || count(*) filter (where column_name = 'ci2') from information_schema.columns where table_name = '$T'"
check "W23e that commit's script alone" "1:0" "$(q "$L" "$cols")"
d="$(differing "$cols")"; [ -z "$d" ] && ok "W23f the same on every node" || bad "W23f differs:$d"
tags="$(for n in "${NODES[@]}"; do q "$n" "select script_tag from $HIST where target = '$(node_uuid "$n")' and version = '95.1' order by id desc limit 1"; done | sort -u)"
check "W23g every node's row that commit" "$c1" "$tags"
id="$(check_row "$O" 95.1 yt:plan)"
check_wait "$O" "$id" 180 >/dev/null || true
check "W23h a plan with no commit named keeps the one it resolved: the branch's" "$c2" "$(q "$O" "select script_tag from $HIST where id = $id")"
id="$(ci_row "$O" 95.1 yt:plan main)"
m="$(check_wait "$O" "$id" 120)"
case "$m" in "yt:failed"*"not a whole commit"*) ok "W23i a branch's name: refused";; *) bad "W23i [$m]";; esac
set_source "source_dir=$DIR"
id="$(ci_row "$O" 96.0 yt:roll "$c2")"
for ((i = 0; i < 40; i += 2)); do m="$(q "$O" "select msg from $HIST where id = $id")"; [ "$m" = yt:roll ] || break; sleep 2; done
case "$m" in "yt:failed"*"not git"*) ok "W23j a commit with a folder as the source: refused";; *) bad "W23j [$m]";; esac

echo "-- W24 a script that writes rows: each node counts its own"
fresh_nodes
# a table of each node's own, as many rows as its place in the list: no two counts the same
i=0
for n in "${NODES[@]}"; do
	i=$((i + 1))
	q "$n" "drop table if exists sw_cnt; create table sw_cnt (id int primary key, v int); insert into sw_cnt select g, 0 from generate_series(1, $i) g" >/dev/null
done
printf '%s\n' "update sw_cnt set v = v + 1;" | rh "docker exec -i $O sh -c 'cat > $DIR/V97_0__cnt.sql && chmod -R a+rX $DIR'"
id="$(check_row "$O" 97.0 yt:plan)"
m="$(check_wait "$O" "$id" 180)"
check "W24 one plan, though no two nodes count the same [$(check_states "$O" "$id" | cut -c1-200)]" "yt:same" "$m"
check "W24b every node's text, each with its own count" "${#NODES[@]}:${#NODES[@]}" \
	"$(q "$O" "select count(*) || ':' || count(distinct body) from ${HIST}_check where history_id = $id and body like '%sw_cnt%' and body like '%V97_0__cnt.sql%'")"
check "W24c one group, of every node" "1:${#NODES[@]}:1" "$(q "$O" "select count(*) || ':' || max(count) || ':' || bool_and(reference)::int from ${HIST}_check_groups where history_id = $id")"
# a node that already has what a script adds: its plan says it adds nothing
printf '%s\n' "alter table $T add column if not exists cn int;" | rh "docker exec -i $O sh -c 'cat > $DIR/V97_1__cn.sql && chmod -R a+rX $DIR'"
q "$G" "alter table $T add column cn int" >/dev/null
id="$(check_row "$O" 97.1 yt:plan)"
m="$(check_wait "$O" "$id" 180)"
check "W24d a node whose database makes the script do otherwise: named" "yt:differs $(node_uuid "$G")" "$m"
q "$G" "alter table $T drop column cn" >/dev/null
rh "docker exec $O rm -f $DIR/V97_0__cnt.sql $DIR/V97_1__cn.sql" 2>/dev/null

group_diff() { # group_diff <node> <id>: each group's text against the reference's, as a CI shows it
	local ref
	ref="$(q "$1" "select body from ${HIST}_check_groups where history_id = $2 and reference limit 1")"
	q "$1" "select md5 from ${HIST}_check_groups where history_id = $2 and not reference" | while read -r md; do
		diff -u <(printf '%s\n' "$ref") <(q "$1" "select body from ${HIST}_check_groups where history_id = $2 and md5 = '$md'") | sed -n '3,40p'
	done
}
dump_md5() { q "$O" "select md5 from ${HIST}_check where history_id = $1 and node = '$(node_uuid "$2")'"; }
echo "-- W25 every node's whole schema, by pg_dump"
fresh_nodes
id="$(check_row "$O" 0 yt:dump)"
m="$(check_wait "$O" "$id" 180)"
check "W25 every node's whole schema the same [$(check_states "$O" "$id" | cut -c1-200)] $(group_diff "$O" "$id" | tr '\n' ' ' | cut -c1-600)" "yt:same" "$m"
check "W25b one text, from every node" "${#NODES[@]}:1" "$(q "$O" "select count(*) || ':' || count(distinct md5) from ${HIST}_check where history_id = $id")"
check "W25c the application's table in it, not the cluster's own tables, sequences or views" "${#NODES[@]}:0" \
	"$(q "$O" "select count(*) filter (where body like '%CREATE TABLE public.$T (%') || ':' || count(*) filter (where body ~ 'CREATE (TABLE|SEQUENCE|VIEW) public\\.sge_history') from ${HIST}_check where history_id = $id")"
check "W25d nothing a run makes its own: no restrict key, no session settings" "0" \
	"$(q "$O" "select count(*) from ${HIST}_check where history_id = $id and (strpos(body, chr(92) || 'restrict') > 0 or strpos(body, 'SET statement_timeout') > 0)")"
before_g="$(dump_md5 "$id" "$G")"; before_o="$(dump_md5 "$id" "$O")"
q "$G" "create index sw_one_ix on $T (v)" >/dev/null
id="$(check_row "$O" 0 yt:dump)"
m="$(check_wait "$O" "$id" 180)"
check "W25e an index on one node: that node named" "yt:differs $(node_uuid "$G")" "$m"
check "W25f its own text changed, the others' not" "changed:same" \
	"$([ "$(dump_md5 "$id" "$G")" != "$before_g" ] && echo changed || echo same):$([ "$(dump_md5 "$id" "$O")" = "$before_o" ] && echo same || echo changed)"
check "W25g two groups: that node's shows the index" "2:1" \
	"$(q "$O" "select count(*) || ':' || count(*) filter (where not reference and nodes = array['$(node_uuid "$G")'] and body like '%CREATE INDEX sw_one_ix%') from ${HIST}_check_groups where history_id = $id")"
case "$(group_diff "$O" "$id")" in *"+CREATE INDEX sw_one_ix"*) ok "W25h a diff between the groups shows it";; *) bad "W25h no diff: [$(group_diff "$O" "$id" | head -5)]";; esac
q "$G" "drop index sw_one_ix" >/dev/null
for n in "${NODES[@]}"; do q "$n" "create or replace function sw_fn() returns int language sql as 'select 1'" >/dev/null; done
q "$G" "create or replace function sw_fn() returns int language sql as 'select 2'" >/dev/null
id="$(check_row "$O" 0 yt:dump)"
check "W25i a function changed on one node: that node named" "yt:differs $(node_uuid "$G")" "$(check_wait "$O" "$id" 180)"
q "$G" "create or replace function sw_fn() returns int language sql as 'select 1'" >/dev/null
id="$(check_row "$O" 0 yt:dump)"
check "W25j put back, the same again" "yt:same" "$(check_wait "$O" "$id" 180)"
for n in "${NODES[@]}"; do q "$n" "drop function sw_fn()" >/dev/null; done
id="$(check_row "$O" 0 yt:dump)"
check_wait "$O" "$id" 180 >/dev/null || true
check "W25k dropped everywhere, as it was before" "$before_g" "$(dump_md5 "$id" "$G")"

echo "-- W26 the CI's role"
fresh_nodes
set_source "source_git=file://$GDIR/repo; source_git_ref=rel"
for n in "${NODES[@]}"; do
	q "$n" "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'sw_ci') then create role sw_ci; end if; end \$\$" >/dev/null
done
e="$(cfg_put sge_role 'sw ci')"
[ -n "$e" ] && ok "W26 no role's name: refused at the statement" || bad "W26 'sw ci' taken"
e="$(cfg_put sge_role sw_ci)"; [ -z "$e" ] || bad "W26a sge_role: $e"
REQ="public.yt_sge_request(text, text, text, text)"
rights_on() { # rights_on <1|0>: the nodes where the role's use of the two functions and the checks is not that
	local n out=""
	for n in "${NODES[@]}"; do
		[ "$(q "$n" "select concat(has_function_privilege('sw_ci', '$REQ', 'EXECUTE')::int, has_function_privilege('sw_ci', 'public.yt_sge_rows()', 'EXECUTE')::int, has_table_privilege('sw_ci', '${HIST}_check', 'SELECT')::int)")" = "$1$1$1" ] || out="$out $n"
	done
	echo "$out"
}
for ((i = 0; i < 60; i += 2)); do left="$(rights_on 1)"; [ -z "$left" ] && break; sleep 2; done
[ -z "$left" ] && ok "W26a its functions and the checks on every node" || bad "W26a not on:$left"
d=""; for n in "${NODES[@]}"; do [ "$(q "$n" "select has_table_privilege('sw_ci', '$HIST', 'SELECT,INSERT,UPDATE,DELETE')::int")" = 0 ] || d="$d $n"; done
[ -z "$d" ] && ok "W26b nothing on sge's own table" || bad "W26b a right on the history on:$d"
ci() { qx "$1" "set role sw_ci; $2"; }
ci_wait() { # ci_wait <node> <id> <seconds>: as the role, until the row is answered -> what it says
	local i m
	for ((i = 0; i < $3; i += 2)); do
		m="$(ci "$1" "select msg from public.yt_sge_rows() where id = $2" | tail -1)"
		case "$m" in yt:plan|yt:snapshot|yt:dump|yt:roll|"") ;; *) printf '%s' "$m"; return 0;; esac
		sleep 2
	done
	printf '%s' "$m"
	return 1
}
id="$(ci "$O" "select public.yt_sge_request('yt:snapshot', '0')" | tail -1)"
case "$id" in
	''|*[!0-9]*) bad "W26c the role adds a check: [$id]";;
	*) check "W26c the role adds a check, and it runs" "yt:same" "$(ci_wait "$O" "$id" 120)"
	   check "W26d and reads its groups" "1" "$(ci "$O" "select count(*) from ${HIST}_check_groups where history_id = $id" | tail -1)";;
esac
# with the role set, sge still deploys its own table before each run: a plan and a roll
printf 'alter table %s add column ci3 int;\n' "$T" > "$R/V99_0__ci.sql"
git -C "$R" add -A; git -C "$R" commit -qm ci3
c3="$(git -C "$R" rev-parse HEAD)"
for n in "${NODES[@]}"; do ship_repo "$n"; done
id="$(ci "$O" "select public.yt_sge_request('yt:plan', '99.0', '$c3')" | tail -1)"
check "W26e its plan runs on every node [$(check_states "$O" "$id" | cut -c1-200)]" "yt:same" "$(ci_wait "$O" "$id" 180)"
id="$(ci "$O" "select public.yt_sge_request('yt:roll', '99.0', '$c3')" | tail -1)"
check "W26f its roll finishes" "yt:done" "$(ci_wait "$O" "$id" 300)"
left="$(wait_msg 99.0 yt:done 60 "${NODES[@]}")" && ok "W26g done on every node" || bad "W26g not done on:$left"
same_schema W26g
e="$(err_of "$(ci "$O" "select public.yt_sge_request('yt:done', '1')")")"
case "$e" in *"not a row a CI may add"*) ok "W26h a worker's row: refused";; *) bad "W26h [$e]";; esac
e="$(err_of "$(ci "$O" "select public.yt_sge_request('yt:roll', '')")")"
case "$e" in *"no version"*) ok "W26i no version: refused";; *) bad "W26i [$e]";; esac
for sql in "insert into $HIST (source, source_type, version, msg) values ('x', 'Y', '1', 'yt:roll')" \
	"update $HIST set msg = 'yt:done' where msg like 'yt:%'" "select count(*) from $HIST" "delete from ${HIST}_check"; do
	e="$(err_of "$(ci "$O" "$sql")")"
	case "$e" in *"permission denied"*) ok "W26j refused: $(printf '%s' "$sql" | cut -c1-50)";; *) bad "W26j taken: $sql [$e]";; esac
done
check "W26k nothing it was refused is there" "0" "$(q "$O" "select count(*) from $HIST where source = 'x'")"
e="$(cfg_put sge_role '')"; [ -z "$e" ] || bad "W26l sge_role emptied: $e"
for ((i = 0; i < 60; i += 2)); do left="$(rights_on 0)"; [ -z "$left" ] && break; sleep 2; done
[ -z "$left" ] && ok "W26l no longer named: its rights gone on every node" || bad "W26l still on:$left"
e="$(cw "$L" "delete from $YX_CFG where module='C' and name = 'sge_role'")"; [ -z "$e" ] || bad "removing sge_role: $e"

echo "-- W27 refused, not left waiting nor marked done"
fresh_nodes
row_msg() { q "$1" "select msg from $HIST where id = $2"; }
row_wait() { # row_wait <node> <id> <seconds>: until the row is no longer yt:roll -> what it says
	local i m
	for ((i = 0; i < $3; i += 2)); do m="$(row_msg "$1" "$2")"; [ "$m" = yt:roll ] || break; sleep 2; done
	printf '%s' "$m"
}
row_until() { # row_until <node> <id> <prefix> <seconds>: until the row says so -> what it says
	local i m
	for ((i = 0; i < $4; i += 2)); do m="$(row_msg "$1" "$2")"; case "$m" in "$3"*) break;; esac; sleep 2; done
	printf '%s' "$m"
}
id="$(ci_row "$O" 99.0 yt:roll "$c3")"
check "W27 a version done on every node, asked again at its commit: done, nothing run" "yt:done" "$(row_until "$O" "$id" yt:done 40)"
id="$(ci_row "$O" 99.0 yt:roll "$c2")"
# by its own rows, or, a node answering late, by what the version is rolled at: refused either way
case "$(row_wait "$O" "$id" 40)" in "yt:failed"*"done on every node at $c3"*|"yt:failed"*"is rolled at $c3"*) ok "W27a at another commit: refused";; *) bad "W27a [$(row_msg "$O" "$id")]";; esac
# a slow script, and another commit of its version asked for while it rolls
printf 'select pg_sleep(20); alter table %s add column ci4 int;\n' "$T" > "$R/V100_0__slow.sql"
git -C "$R" add -A; git -C "$R" commit -qm slow
c4="$(git -C "$R" rev-parse HEAD)"
for n in "${NODES[@]}"; do ship_repo "$n"; done
first="$(ci_row "$O" 100.0 yt:roll "$c4")"
for ((i = 0; i < 60; i += 1)); do [ "$(msg_of "$O" 100.0)" = "yt:pending" ] && break; sleep 1; done
id="$(ci_row "$F" 100.0 yt:roll "$c3")"
case "$(row_wait "$F" "$id" 40)" in "yt:failed"*"in progress"*) ok "W27b another commit of the version rolling, on another node: refused";; *) bad "W27b [$(row_msg "$F" "$id")]";; esac
# on the origin, whose worker holds the roll: answered when it ends, never marked done with it
other="$(ci_row "$O" 100.0 yt:roll "$c3")"
left="$(wait_msg 100.0 yt:done 300 "${NODES[@]}")" && ok "W27c the roll it asked about goes on" || bad "W27c not done on:$left"
check "W27c the row of that roll done" "yt:done" "$(row_wait "$O" "$first" 40)"
case "$(row_wait "$O" "$other" 40)" in "yt:failed"*"is done at $c4"*) ok "W27d on the origin: refused when the roll ended, not marked done";; *) bad "W27d [$(row_msg "$O" "$other")]";; esac
# two commits of one version asked for in one statement, before the origin's own row
printf 'alter table %s add column ci5 int;\n' "$T" > "$R/V102_0__two.sql"
git -C "$R" add -A; git -C "$R" commit -qm two
c6="$(git -C "$R" rev-parse HEAD)"
for n in "${NODES[@]}"; do ship_repo "$n"; done
ids="$(q "$O" "insert into $HIST (source, source_type, version, msg, script_tag) values ('ci', 'Y', '102.0', 'yt:roll', '$c6'), ('ci', 'Y', '102.0', 'yt:roll', '$c3') returning id" | tr '\n' ' ')"
read -r x y <<< "$ids"
left="$(wait_msg 102.0 yt:done 240 "${NODES[@]}")" && ok "W27e the first rolls" || bad "W27e not done on:$left"
check "W27e its row done" "yt:done" "$(row_wait "$O" "$x" 40)"
case "$(row_wait "$O" "$y" 40)" in "yt:failed"*"is done at $c6"*) ok "W27f the second: refused, not marked done";; *) bad "W27f [$(row_msg "$O" "$y")]";; esac
# a roll halted on one node, a row of another commit written while it ran: neither halted with it
# nor done when its operator has it finished
printf 'select pg_sleep(8); create table sw_block (x int);\n' > "$R/V101_0__block.sql"
git -C "$R" add -A; git -C "$R" commit -qm block
c5="$(git -C "$R" rev-parse HEAD)"
for n in "${NODES[@]}"; do ship_repo "$n"; done
q "$G" "create table sw_block (x int)" >/dev/null
x="$(ci_row "$O" 103.0 yt:roll "$c5")"
for ((i = 0; i < 60; i += 1)); do [ "$(msg_of "$O" 103.0)" = "yt:pending" ] && break; sleep 1; done
y="$(ci_row "$O" 103.0 yt:roll "$c3")"
for ((i = 0; i < 120; i += 2)); do case "$(row_msg "$O" "$x")" in "yt:failed halted"*) break;; esac; sleep 2; done
case "$(row_msg "$O" "$x")" in "yt:failed halted"*) ok "W27g halted on the one node";; *) bad "W27g not halted: [$(row_msg "$O" "$x")]";; esac
case "$(row_wait "$O" "$y" 40)" in "yt:failed"*"is halted"*) ok "W27h the other commit's row: refused, not halted with it";; *) bad "W27h [$(row_msg "$O" "$y")]";; esac
q "$G" "drop table sw_block" >/dev/null
q "$G" "update $HIST set msg = 'yt:pending', ok = false where target = '$(node_uuid "$G")' and version = '103.0' and msg like 'yt:failed%'" >/dev/null
left="$(wait_msg 103.0 yt:done 300 "${NODES[@]}")" && ok "W27i set back by its operator, it finishes" || bad "W27i not done on:$left"
check "W27j the halted roll's row done" "yt:done" "$(row_until "$O" "$x" yt:done 60)"
case "$(row_msg "$O" "$y")" in "yt:failed"*"is halted"*) ok "W27k the other commit's row not done with it";; *) bad "W27k [$(row_msg "$O" "$y")]";; esac
for n in "${NODES[@]}"; do q "$n" "drop table if exists sw_block" >/dev/null; done
set_source "source_dir=$DIR"


e="$(cw "$L" "delete from $YX_CFG where module='M' or (module='C' and name = 'sge_all_at_once')")"
[ -z "$e" ] || bad "removing module M: $e"
clean
summary
