#!/usr/bin/env bash
# [test] A server function's own test(level), run on a check only (rppd README "Test a
# function"): an event runs the function's body, never test(); a check runs the code's
# definitions only - imports, defs, literal constants - never the body, then
# test(level), on the rppd master. 0 returned is passed, anything else failed. Each run
# is a rppd_function_log row with test_level set.
#
# In YT Cluster rppd has no rppd_event trigger, as 92_rppd.sh says: it reads rppd_function at
# its start and every minute, so a deploy here is a restart, or that minute: a function whose
# test_level is set and test_timestamp NULL is tested once, and stamped.
#
# ## What is asserted
#
# T1 after the restart the master ran the test of the function at its level: a log row
#    with test_level 2, finished (took_ms -1 while it runs), no error, test's own output
# T2 the check ran neither the body (no "body ran" in the sink) nor kept what test wrote
#    (its insert rolled back)
# T3 rppd stamped the function's test_timestamp
# T4 a test that returns 5 failed: its row says RPPD-E149 and 5
# T5 a commit to its table runs the body, as a call: "body ran" in the sink, its log
#    row with test_level NULL
# T6 a cron row with test_level 0 runs the test on its schedule (a row with test_level 0,
#    naming the cron row; the cron row finished, no error);
#    a restart does not test the stamped function on deploy again - on the node that
#    stamped it (each node's rppd_function is its own here)
# T7 rppd's start adds rppd_function.required_version, one character, NULL unless set
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== server functions: a function's test(level) runs on a check only =="
[ "${YX_SERVER_BIN:-ytserv-all}" = ytserv-all ] || { echo "SKIP 92e_rppd_test.sh: Python functions are ytserv-all's, the nodes run $YX_SERVER_BIN"; exit 0; }

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists tf_t; create table tf_t (id bigint primary key, v text);
	        drop table if exists tf_sink; create table tf_sink (id serial primary key, data text);" >/dev/null
	cfg_write "$n" serve_rppd C true
done
CFG="$("$REPO_ROOT"/target/release/ytctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$CFG" ] || { bad "--encode-table-cfg 'on_commit_python' produced nothing"; summary; }
register_table public.tf_t "$CFG"
restart_all
await_cluster
wait_writable n1 n2 tf_t || { bad "cluster never became writable"; summary; }
leader_now() { local n; for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) echo "$n"; return;; esac; done; }
L="$(leader_now)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true) on conflict do nothing" >/dev/null
sleep 8

# The function: its test checks the sink exists, prints, writes a row it must not keep;
# its body writes "body ran". A second function's test returns 5.
FN='import os
MARK = "tested"


def test(level: int = 0) -> int:
    cur = DB.cursor()
    cur.execute("select to_regclass(%s)", ("public.tf_sink",))
    if cur.fetchone()[0] is None:
        return 2
    print("test level", level, MARK, os.sep)
    if level >= 2:
        cur.execute("insert into tf_sink (data) values (%s)", ("test wrote",))
    return 0


cur = DB.cursor()
cur.execute("insert into tf_sink (data) values (%s)", ("body ran",))
DB.commit()'
BAD='def test(level):
    return 5


raise SystemExit("the body of the failing one ran")'
# on every node: rppd_function is a local table, read by the master the restart elects
for n in "${NODES[@]}"; do
	q "$n" "delete from rppd_cron where fn_id in (select id from rppd_function where schema_table in ('public.tf_t', 'public.tf_none'));
	        delete from rppd_function where schema_table in ('public.tf_t', 'public.tf_none');
	        insert into rppd_function (id, code, checksum, schema_table, topic, fn_logging, verbose_debug, test_level, test_timestamp)
	        values (9201, \$fn\$$FN\$fn\$, 'na', 'public.tf_t', '', true, true, 2, null),
	               (9202, \$fn\$$BAD\$fn\$, 'na', 'public.tf_none', '', true, true, 1, null)
	        on conflict (id) do update set code = excluded.code, test_level = excluded.test_level, test_timestamp = null" >/dev/null
done
check "the two functions are registered, test_level set, never tested" "2" \
	"$(q "$L" "select count(*) from rppd_function where id in (9201, 9202) and test_level is not null and test_timestamp is null")"

restart_all
await_cluster
L="$(leader_now)"
[ -n "$L" ] || { bad "no leader after the restart"; summary; }
echo "  the rppd master is the leader now: $L"

# wait_q <node> <sql> <want> [secs]: the query's value, once it is <want> or the time is up
wait_q() {
	local i v
	for i in $(seq 1 "${4:-60}"); do v="$(q "$1" "$2")"; [ "$v" = "$3" ] && break; sleep 1; done
	printf '%s' "$v"
}
row() { q "$L" "select $2 from rppd_function_log where fn_id = $1 and test_level is not null order by id desc limit 1"; }

# ── T1 the test ran on deploy ────────────────────────────────────────────────────
check "T1 a test row of 9201 at level 2, finished" "2" \
	"$(wait_q "$L" "select coalesce(max(test_level), -1) from rppd_function_log where fn_id = 9201 and took_ms >= 0" 2 90)"
check "T1 ...no error" "<none>" "$(row 9201 "coalesce(error_msg, '<none>')")"
case "$(row 9201 "coalesce(output, '')")" in
	*"test level 2 tested /"*) ok "T1 ...its output is test's own: $(row 9201 output | tr '\n' ' ')" ;;
	*) bad "T1 the output is [$(row 9201 "coalesce(output, '')")]" ;;
esac

# ── T2 nothing of the body, nothing kept of the test ─────────────────────────────
check "T2 the check did not run the body" "0" "$(q "$L" "select count(*) from tf_sink where data = 'body ran'")"
check "T2 ...and what test wrote was rolled back" "0" "$(q "$L" "select count(*) from tf_sink where data = 'test wrote'")"

# ── T3 stamped ───────────────────────────────────────────────────────────────────
check "T3 rppd stamped test_timestamp" "t" \
	"$(wait_q "$L" "select test_timestamp is not null from rppd_function where id = 9201" t 30)"

# ── T4 a failing test ────────────────────────────────────────────────────────────
e="$(wait_q "$L" "select count(*) from rppd_function_log where fn_id = 9202 and test_level = 1 and error_msg like 'RPPD-E149%5%'" 1 60)"
check "T4 a test returning 5 failed: $(row 9202 "coalesce(error_msg, '<none>')" | head -1)" "1" "$e"

# ── T5 an event runs the body, as a call ─────────────────────────────────────────
q "$L" "begin; insert into tf_t values (1, 'go'); select yt_complete(true); commit;" >/dev/null
check "T5 a commit ran the body" "1" "$(wait_q "$L" "select count(*) from tf_sink where data = 'body ran'" 1 60)"
check "T5 ...as a call: its log row has no test_level" "1" \
	"$(q "$L" "select count(*) from rppd_function_log where fn_id = 9201 and test_level is null and took_ms is not null")"

# ── T7 the flag column ───────────────────────────────────────────────────────────
check "T7 rppd's start added required_version, one character" "character 1" \
	"$(q "$L" "select data_type || ' ' || character_maximum_length from information_schema.columns where table_schema = 'public' and table_name = 'rppd_function' and column_name = 'required_version'")"
check "T7 ...NULL unless set" "1" "$(q "$L" "select count(*) from rppd_function where id = 9201 and required_version is null")"

# ── T6 a cron test; a restart does not test the stamped function again ──────────
L1="$L"
deploys="$(q "$L" "select count(*) from rppd_function_log where fn_id = 9201 and test_level = 2")"
for n in "${NODES[@]}"; do
	q "$n" "insert into rppd_cron (fn_id, cron, column_name, test_level) values (9201, '* * * * *', 'id', 0)" >/dev/null
done
restart_all
await_cluster
L="$(leader_now)"
[ -n "$L" ] || { bad "no leader after the second restart"; summary; }
check "T6 the cron ran the test at level 0 on its schedule" "1" \
	"$(wait_q "$L" "select least(count(*), 1) from rppd_function_log where fn_id = 9201 and test_level = 0 and took_ms >= 0 and error_msg is null" 1 150)"
CRON="$(q "$L" "select id from rppd_cron where fn_id = 9201 and test_level = 0 limit 1")"
check "T6 ...its log row names the cron row" "$CRON" \
	"$(q "$L" "select trig_value->>'cron' from rppd_function_log where fn_id = 9201 and test_level = 0 order by id desc limit 1")"
check "T6 ...and the cron row says it finished, no error" "t" \
	"$(wait_q "$L" "select finished_at is not null and error_msg is null from rppd_cron where id = ${CRON:-0}" t 30)"
# rppd_function and its log are each node's own here: the stamp is the node's that tested
if [ "$L" = "$L1" ]; then
	check "T6 ...and the stamped function was not tested on deploy again" "$deploys" \
		"$(q "$L" "select count(*) from rppd_function_log where fn_id = 9201 and test_level = 2")"
else
	check "T6 ...the leader moved ($L1 -> $L): its own row was never stamped, so it tested once on deploy" "1" \
		"$(wait_q "$L" "select count(*) from rppd_function_log where fn_id = 9201 and test_level = 2 and took_ms >= 0" 1 60)"
fi

# ── cleanup ──────────────────────────────────────────────────────────────────────
for n in "${NODES[@]}"; do
	q "$n" "delete from rppd_cron where fn_id in (9201, 9202); delete from rppd_function where id in (9201, 9202);
	        delete from rppd_function_log where fn_id in (9201, 9202);
	        drop table if exists tf_sink; drop table if exists tf_t;" >/dev/null
done
summary
