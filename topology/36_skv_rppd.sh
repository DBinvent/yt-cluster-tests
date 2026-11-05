#!/usr/bin/env bash
# [skv] The secret store's first consumer, phase P6 (yt-pgxt ytserv/skv-secrets.md,
# "Who may read"): a python server function reads a value as SECRET.get(name),
# for the names its rppd_function.secret_names lists and no other. The value is
# opened in ytserv's memory with the cluster master key (rppd gets ytserv's opener
# as a handle) and reaches the interpreter only.
#
# ## What is asserted
#
# R1 the store on, genesis, every node approved, the secret put on the leader
# R2 a commit on a table with on_commit_python runs the function on the rppd
#    master: it read the listed secret - the sink holds the value's SHA-256
# R3 a name it does not list is refused (PermissionError)
# R4 the plaintext is in no table: not the sink, not rppd_function_log, not the
#    config table
# R5-R10 [rotate-key] ytctl --rotate_key with an rppd function the consumer, checking a
#    presented value with SECRET.check (its code holds the old and the new value, a
#    test's shortcut for a client presenting them): a rotation starts, a second one is
#    refused, --force_new replaces the new value before any use; the function finds
#    the old and the new value both accepted, the one replaced and a wrong one not - its
#    match of the new one is the use; --force_new is refused from then on; before
#    --discard_sec the old value is still accepted, after it refused, the new one still
#    accepted. (rppd runs functions on the leader, so the use is the leader's own: the
#    ping path a member's use takes is unit-tested, ytserv skv/state.rs)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== skv rppd: a server function reads a secret, and only the ones it lists =="

# As 92_rppd.sh, with the [skv] column rppd.yaml declares (rppd 0.2.13+).
RPPD_DDL="
create table if not exists rppd_config (
    id serial primary key,
    host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10,
    master bool unique);
drop table if exists rppd_function_log;
drop table if exists rppd_function;
create table rppd_function (
    id serial primary key,
    code text not null,
    checksum varchar(64) not null,
    schema_table varchar(64) not null,
    topic varchar(64) not null default '',
    priority int not null default 1,
    queue bool not null default true,
    cleanup_logs_min int not null default 0,
    fn_logging bool not null default false,
    verbose_debug bool not null default false,
    env json, sign json,
    secret_names text);
create table rppd_function_log (
    id bigserial primary key,
    node_id int not null,
    fn_id int not null,
    trig_value json,
    trig_type int not null default 0,
    started_at timestamptz not null default current_timestamp,
    took_ms bigint,
    output text,
    error_msg text);
"
V="rppd-secret-$RANDOM-$RANDOM"
V2="rppd-new-$RANDOM-$RANDOM"   # [rotate-key] the new value
V3="rppd-decoy-$RANDOM-$RANDOM" # replaced by --force_new before any use
V4="rppd-late-$RANDOM-$RANDOM"  # --force_new once V2 is in use: refused
WANT="sha:$(printf '%s' "$V" | sha256sum | cut -d' ' -f1)"
FN='import hashlib
cur = DB.cursor()
v = SECRET.get("fn_secret")
cur.execute("insert into skv_sink (data) values (%s)", ("sha:" + hashlib.sha256(v.encode()).hexdigest(),))
try:
    SECRET.get("not_listed")
    cur.execute("insert into skv_sink (data) values (%s)", ("LEAK",))
except PermissionError:
    cur.execute("insert into skv_sink (data) values (%s)", ("refused",))
DB.commit()'
# [rotate-key] what a function checking a presented key does
FN2="cur = DB.cursor()
r = [SECRET.check('fn_secret', x) for x in ('$V', '$V2', '$V3', 'nope')]
cur.execute('insert into skv_sink (data) values (%s)', ('check:' + ','.join('1' if b else '0' for b in r),))
DB.commit()"

for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL
	        drop table if exists skv_t; create table skv_t (id bigint primary key, v text);
	        drop table if exists skv_sink; create table skv_sink (id serial primary key, data text);
	        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug, secret_names)
	        values (\$fn\$$FN\$fn\$, 'na', 'public.skv_t', '', true, true, 'fn_secret');
	        drop table if exists skv_c; create table skv_c (id bigint primary key, v text);
	        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug, secret_names)
	        values (\$fn\$$FN2\$fn\$, 'na', 'public.skv_c', '', true, true, 'fn_secret');" >/dev/null
	cfg_write "$n" serve_rppd C true
done
CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$CFG" ] || { bad "--encode-table-cfg 'on_commit_python' produced nothing"; summary; }
register_table public.skv_t "$CFG"
register_table public.skv_c "$CFG"
# ytserv reads the A row and rppd_function at startup
restart_all
await_cluster
L="$(leader)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true) on conflict do nothing" >/dev/null
sleep 8

# ── R1 ───────────────────────────────────────────────────────────────────────
skv_cleanup
if skv_setup; then ok "R1 the store on, genesis, every node approved: all hold v1"; else bad "R1 v1 not held on:$(not_holding 1)"; fi
o="$(printf '%s' "$V" | yx "$L" --skv put fn_secret)"
case "$o" in *"sealed under"*) ok "R1 fn_secret put on the leader" ;; *) bad "R1 put: $(echo "$o" | tail -1)" ;; esac
sleep 4 # every node's store refreshed from the new row

# ── R2, R3 ───────────────────────────────────────────────────────────────────
L="$(leader)"
q "$L" "begin; insert into skv_t values ($RANDOM,'go'); select yt_complete(true); commit;" >/dev/null
for _ in $(seq 1 20); do [ "$(q "$L" "select count(*) from skv_sink")" -ge 2 ] 2>/dev/null && break; sleep 2; done
check "R2 the function read the listed secret: the sink holds its SHA-256" "t" \
	"$(q "$L" "select count(*) > 0 from skv_sink where data='$WANT'")"
check "R3 a name it does not list is refused" "t" "$(q "$L" "select count(*) > 0 from skv_sink where data='refused'")"
check "R3 ...and nothing was opened for it" "0" "$(q "$L" "select count(*) from skv_sink where data='LEAK'")"
err="$(q "$L" "select coalesce(error_msg,'') from rppd_function_log order by id desc limit 1")"
[ -z "$err" ] && ok "R2 the run logged no error" || bad "R2 the run failed: $err"

# ── R4 ───────────────────────────────────────────────────────────────────────
leak=""
for n in "${NODES[@]}"; do
	c="$(q "$n" "select (select count(*) from skv_sink where data like '%$V%')
	           + (select count(*) from rppd_function_log where coalesce(output,'') like '%$V%' or coalesce(error_msg,'') like '%$V%')
	           + (select count(*) from $YX_CFG where value like '%$V%')")"
	[ "${c:-1}" = 0 ] || leak="$leak $n"
done
[ -z "$leak" ] && ok "R4 the plaintext is in no table, on any node" || bad "R4 the plaintext found on:$leak"

# ── R5-R10 [rotate-key] ──────────────────────────────────────────────────────
L="$(leader)"
checks() { q "$L" "select string_agg(data, ' ' order by id) from skv_sink where data like 'check:%'"; }
check_run() { # commit on skv_c; wait for the function's row number $1
	q "$L" "begin; insert into skv_c values ($RANDOM$RANDOM,'go'); select yt_complete(true); commit;" >/dev/null
	for _ in $(seq 1 20); do [ "$(q "$L" "select count(*) from skv_sink where data like 'check:%'")" -ge "$1" ] 2>/dev/null && return 0; sleep 2; done
	return 1
}
o="$(yx "$L" --rotate_key=fn_secret --value=$V3 --discard_sec=30 --adopt_sec=600)"
case "$o" in *"fn_secret rotating"*) ok "R5 --rotate_key fn_secret: rotating" ;; *) bad "R5 rotate: $(echo "$o" | tail -1)" ;; esac
o="$(yx "$L" --rotate_key=fn_secret --value=$V2)"
case "$o" in *"rotating already"*) ok "R6 a second rotation is refused while it runs" ;; *) bad "R6: $(echo "$o" | tail -1)" ;; esac
o="$(yx "$L" --rotate_key=fn_secret --value=$V2 --force_new --discard_sec=30 --adopt_sec=600)"
case "$o" in *"new value replaced, the old one kept"*) ok "R7 --force_new before any use: the new value replaced" ;;
	*) bad "R7 --force_new: $(echo "$o" | tail -1)" ;; esac
sleep 4 # the rppd master's store has the row
check_run 1 || bad "R8 the checking function did not run: $(q "$L" "select coalesce(error_msg,'') from rppd_function_log order by id desc limit 1")"
check "R8 SECRET.check: the old value and the new one accepted, the replaced one and a wrong one not" "check:1,1,0,0" "$(checks)"
in_use() { case "$(info "$L" X fn_secret)" in *"in use since"*) return 0 ;; *) return 1 ;; esac; }
skv_wait 20 "the use reaches the leader" in_use && ok "R9 its match of the new value is the use: $(info "$L" X fn_secret | grep -o 'in use since [^;]*')" \
	|| bad "R9 no use noted: $(info "$L" X fn_secret)"
o="$(yx "$L" --rotate_key=fn_secret --value=$V4 --force_new)"
case "$o" in *"in use since"*) ok "R9 --force_new once the new value is in use: refused" ;; *) bad "R9 --force_new after use: $(echo "$o" | tail -1)" ;; esac
check_run 2 || bad "R9 the checking function did not run again"
check "R9 before --discard_sec (30 s) the old value is still accepted" "check:1,1,0,0 check:1,1,0,0" "$(checks)"
done_rot() { case "$(info "$L" X fn_secret)" in "v"*" B") return 0 ;; *) return 1 ;; esac; }
skv_wait 90 "the old value discarded" done_rot && ok "R10 --discard_sec after the use: the old value went, the row a bare value" \
	|| bad "R10 still rotating: $(info "$L" X fn_secret)"
sleep 4
check_run 3 || bad "R10 the checking function did not run again"
check "R10 now the old value is refused, the new one accepted" "check:1,1,0,0 check:1,1,0,0 check:0,1,0,0" "$(checks)"
check "R10 the secret's value is the new one" "$V2" "$(yx "$L" --skv get fn_secret --print | tail -1)"

skv_cleanup
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists skv_t; drop table if exists skv_sink; delete from rppd_function where schema_table='public.skv_t'" >/dev/null
	cfg_delete "$n" public.skv_t A
	q "$n" "drop table if exists skv_c; delete from rppd_function where schema_table='public.skv_c'" >/dev/null
	cfg_delete "$n" public.skv_c A
done
summary
