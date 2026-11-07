#!/usr/bin/env bash
# [modules] yt_config modules whose settings are rows (ytserv/README.md "Settings that are rows"):
#   R1 yt_help_with_defaults lists them, by module, with help and defaults
#   R2 a bad row of module U or F is refused at its statement, an old C row too
#   R3 recon_run takes the table alone, and runs as the rows recon.* say
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== module rows: help and defaults, refused rows, recon_run =="

L=""
for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) L="$n";; esac; done
[ -n "$L" ] || { bad "no leader"; summary; }
cw() { qe "$1" "begin; $2; select yt_complete(true); commit;" 2>&1 || true; }

echo "-- R1 the view"
view() { q "$L" "select value || '|' || (description <> '') from yt_help_with_defaults where module = '$1' and name = '$2'"; }
check "R1 B endpoint: no default, its help" "|true" "$(view B endpoint)"
check "R1 B region: its default, its help" "us-east-1|true" "$(view B region)"
check "R1 U *: on" "on|true" "$(view U '*')"
check "R1 U <database>: list" "list|true" "$(view U '<database>')"
check "R1 F recon.chunk: 1000" "1000|true" "$(view F recon.chunk)"
check "R1 F feed.<event>: no default" "|true" "$(view F 'feed.<event>')"
check "R1 F otel.<header>: no default" "|true" "$(view F 'otel.<header>')"
check "R1 M source_git: a setting of sge" "1" "$(q "$L" "select count(*) from yt_help_with_defaults where module = 'M' and name = 'source_git'")"
check "R1 M db_host: not one it may hold" "0" "$(q "$L" "select count(*) from yt_help_with_defaults where module = 'M' and name = 'db_host'")"
check "R1 a C setting is still there" "1" "$(q "$L" "select count(*) from yt_help_with_defaults where module = 'S' and name = 'min_cluster_size'")"
check "R1 the old settings are not" "0" "$(q "$L" "select count(*) from yt_help_with_defaults where name in ('s3_config', 'sge_config', 'etcd_upsert', 'otel_headers', 'databases')")"
check "R1 a name in two modules is joined by module" "0" "$(q "$L" "select count(*) from (select module, name from yt_help_with_defaults group by 1, 2 having count(*) > 1) x")"

echo "-- R2 refused at the statement"
refused() { # refused <tag> <what> <pattern> <name> <module> <value>
	local e; e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('$4','$5','$6')")"
	case "$e" in *"$3"*) ok "$1 $2 refused";; *) bad "$1 $2: [$e]";; esac
}
refused R2a "a database named by an old form" "names no database" "-scratch" U skip
refused R2b "a value of U that is none" "schema.table" appdb U nodot
refused R2c "a node's row with no uuid" "uuid" "appdb@typo" U skip
refused R2d "an F row with no known prefix" "no known prefix" "nosuch.x" F 1
refused R2e "a recon option it does not have" "unknown option" recon.nosuch F 1
refused R2f "a chunk of 0" "chunk must be" recon.chunk F 0
refused R2g "a -bin header" "-bin" otel.x-bin F v
refused R2h "a route with no columns" "no ':'" "feed./q/r2" F public.t
refused R2i "the old databases row" "module U" databases C "*"
refused R2j "the old otel_headers row" "module F" otel_headers C "a=b"
refused R2k "recon_run with its options" "recon_run names the table alone" recon_run C "$YX_DB.public.mr_t;chunk=5"

echo "-- R3 recon_run"
for n in "${NODES[@]}"; do q "$n" "drop table if exists mr_t; create table mr_t (id int primary key, v text)" >/dev/null; done
register_table public.mr_t ""
e="$(cw "$L" "insert into $YX_CFG (name,module,value) values ('recon.chunk','F','250'), ('recon.mode','F','report')")"
case "$e" in *ERROR*) bad "R3 the options: $e";; *) ok "R3 the options written";; esac
e="$(cw "$L" "delete from $YX_CFG where module='C' and name='recon_run'; insert into $YX_CFG (name,module,value) values ('recon_run','C','$YX_DB.public.mr_t')")"
case "$e" in *ERROR*) bad "R3 recon_run: $e";; *) ok "R3 recon_run written";; esac
said=""
# the job's line names the table and how: "<mode>, chunk <n>, whole table"
for ((i = 0; i < 60; i += 2)); do said="$(q "$L" "select yt_info('E')")"; case "$said" in *"mr_t"*"chunk 250"*|*"chunk 250"*"mr_t"*) break;; esac; sleep 2; done
case "$said" in *"mr_t"*"chunk 250"*|*"chunk 250"*"mr_t"*) ok "R3 the scan ran with its rows";; *) bad "R3 no scan of mr_t with chunk 250 in yt_info('E')";; esac
case "$said" in *"report, chunk 250"*) ok "R3 report, as asked";; *"repair, chunk 250"*) bad "R3 it says repair";; *) bad "R3 its mode is not said";; esac

cw "$L" "delete from $YX_CFG where module='F' and name like 'recon.%'; delete from $YX_CFG where module='C' and name='recon_run'" >/dev/null
for n in "${NODES[@]}"; do q "$n" "drop table if exists mr_t" >/dev/null; done
summary
