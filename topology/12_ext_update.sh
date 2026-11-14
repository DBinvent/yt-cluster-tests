#!/usr/bin/env bash
# [ext-update] The extension's update script, in a real PostgreSQL: a database that has an
# earlier version of yt_cluster moves to this one with ALTER EXTENSION yt_cluster UPDATE.
#
# The extension's version is YT Cluster's major.minor (yt-cluster-lite's VERSION). Before
# 1.21 it was 0.5 for every build, so every database installed before has 0.5, and the
# package carries yt_cluster--0.5--<version>.sql - made from the script by ytpgc's
# update-sql.py - for `ytctl --batch` to run the update with.
#
# No cluster: one throwaway container of the node image, PostgreSQL alone, no ytserv. An
# earlier version's script is not in the package, so the database "at <earlier>" is made
# from this version's script under the earlier name - what the last build of it installed -
# and what an older build of it lacked is taken out by hand.
#
#   U1  the image holds the script, the update script from every earlier version, no
#       script of another version, and a control file that names this one
#   U2  a database at the earlier version, nothing else changed: the update brings it to
#       this version with no object kept as it was, and it is what a database created at
#       this version is - members, functions, views, tables, event triggers, dumped tables
#   U3  ...its C functions answer, and a second update has nothing to do
#   U4  a database an older build made - a function, a view, a table and an event trigger
#       missing, and a table made by hand, no member of the extension: the update makes
#       what is missing and makes it the extension's, keeps the hand-made table and says
#       so in a WARNING, and fails on nothing
#   U5  ...and the rows it had are still there
#   U6  a database whose tables an older version shaped - the config table keyed by id, a
#       column of another missing: the update alters no table, says each in a WARNING, and
#       goes on to this version
#   U7  a C function the loaded library does not have - an older library still in memory:
#       the update stops and says to restart PostgreSQL, the database left at its version;
#       with the library's function there it then runs
export YX_NO_SWEEP=1   # no cluster in this one: nothing of the fixture's nodes is touched
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== ext-update: a database at an earlier version of the extension, updated =="

C="${YX_EXTUP_NAME:-${YX_NET}-extupd}"
LITE_V="$(tr -d ' \n' < "$LITE_ROOT/VERSION" 2>/dev/null | cut -d. -f1,2)"
EARLIER=()
while IFS= read -r l; do
	l="${l%%#*}"; l="${l//[[:space:]]/}"
	[ -z "$l" ] || EARLIER+=("$l")
done < "$LITE_ROOT/ytpgc/previous-versions.txt"
[ "${#EARLIER[@]}" -gt 0 ] || { bad "no earlier version in $LITE_ROOT/ytpgc/previous-versions.txt"; summary; }

# a script on stdin, as root in the container. Status 0 whatever it did: the script runs
# under set -e, and what went wrong is for a check to say, not for the shell to die of
cxs() { rh "docker exec -i $C bash -s" || true; }
# psql in the container, the SQL on stdin (env.sh q: it has to survive ssh -> docker ->
# psql), each value alone on its line - and psql's errors and warnings with them
px() { # px <db> <sql>
	if [ "$YX_HOST" = "local" ]; then
		printf '%s\n' "$2" | docker exec -i -u postgres "$C" psql -X -tAq -d "$1" 2>&1 || true
	else
		printf '%s\n' "$2" | "${YX_SSH[@]}" "$YX_HOST" "docker exec -i -u postgres $C psql -X -tAq -d $1" 2>&1 || true
	fi
}
# the words of a list, sorted, one space between
words() { tr ' ' '\n' <<< "$1" | grep . | sort | tr '\n' ' ' || true; }
# same <description> <expected> <actual>: check, with a diff in place of two long texts
same() {
	if [ "$2" = "$3" ]; then ok "$1"; else
		bad "$1"
		# diff exits 1 on a difference: under pipefail and set -e that would end the script
		diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /' || true
	fi
}
EXT="(select oid from pg_extension where extname = 'yt_cluster')"
version_of() { px "$1" "select extversion from pg_extension where extname = 'yt_cluster'"; }
# the extension's members in a database, one a line
members() {
	px "$1" "select pg_describe_object(d.classid, d.objid, 0) from pg_depend d
	         where d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e' order by 1"
}
is_member() { # is_member <db> <catalog> <oid expression>: t or f
	px "$1" "select exists(select 1 from pg_depend d where d.refclassid = 'pg_extension'::regclass
	         and d.refobjid = $EXT and d.deptype = 'e' and d.classid = '$2'::regclass and d.objid = $3)"
}
# what the members are: every function's definition and grants, every view's query, every
# table's columns, the event triggers, the tables pg_dump carries the rows of
shape() {
	px "$1" "
	select 'functions ' || md5(string_agg(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, ''), chr(10)
	                                      order by p.oid::regprocedure::text))
	  from pg_proc p join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid
	 where d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e';
	select 'views ' || md5(string_agg(c.relname || ' ' || pg_get_viewdef(c.oid), chr(10) order by c.relname))
	  from pg_class c join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = c.oid
	 where c.relkind = 'v' and d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e';
	select 'table ' || c.relname || ' ' || md5(string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
	                                                || ' ' || a.attnotnull || ' ' || coalesce(pg_get_expr(ad.adbin, ad.adrelid), ''),
	                                                chr(10) order by a.attnum))
	  from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
	  left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
	  join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = c.oid
	 where c.relkind = 'r' and d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e'
	 group by c.relname order by c.relname;
	select 'constraint ' || k.conrelid::regclass || ' ' || k.conname || ' ' || pg_get_constraintdef(k.oid)
	  from pg_constraint k join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = k.conrelid
	 where d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e' order by 1;
	select 'index ' || i.indexrelid::regclass || ' ' || md5(pg_get_indexdef(i.indexrelid))
	  from pg_index i join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = i.indrelid
	 where d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e' order by 1;
	select 'event trigger ' || t.evtname || ' ' || t.evtevent || ' ' || coalesce(array_to_string(t.evttags, ','), '')
	       || ' ' || t.evtfoid::regproc || ' ' || t.evtenabled
	  from pg_event_trigger t join pg_depend d on d.classid = 'pg_event_trigger'::regclass and d.objid = t.oid
	 where d.refclassid = 'pg_extension'::regclass and d.refobjid = $EXT and d.deptype = 'e' order by t.evtname;
	select 'dumped ' || coalesce(string_agg(c::regclass::text, ',' order by c::regclass::text), '')
	  from pg_extension e left join lateral unnest(e.extconfig) c on true where e.extname = 'yt_cluster';" | LC_ALL=C sort
	# sorted: each line names its object, and the lines of one database came back in
	# another order once (a run of 2026-11-13), the same lines
}

# ── the container: the node image, its own entrypoint not run - PostgreSQL alone ──
rh "docker rm -f $C >/dev/null 2>&1; docker run -d --name $C --entrypoint sleep $YX_IMAGE infinity >/dev/null" \
	|| { bad "no container of image $YX_IMAGE on the docker host (00_build.sh makes it)"; summary; }
trap 'rh "docker rm -f $C >/dev/null 2>&1" || true' EXIT

# PostgreSQL as a node runs it: the library preloaded (node-entrypoint.sh, as ytctl writes it)
started="$(cxs <<'IN' 2>&1
major="$(pg_config --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
cat > "/etc/postgresql/$major/main/conf.d/yt.conf" <<CONF
max_prepared_transactions = 100
shared_preload_libraries = 'yt_cluster'
yt.node = '00000000-0000-4000-8000-0000000000e1'
CONF
chown -R postgres:postgres "/etc/postgresql/$major/main/conf.d"
pg_ctlcluster "$major" main start
for _ in $(seq 1 60); do
	su postgres -c "psql -tAc 'select 1'" >/dev/null 2>&1 && { echo "postgres up"; exit 0; }
	sleep 1
done
echo "postgres did not answer in 60 s"
IN
)"
case "$started" in *"postgres up"*) ;; *) bad "PostgreSQL in the container: $(tail -1 <<< "$started")"; summary ;; esac

# ── U1: what the package installed ──────────────────────────────────────────────
facts="$(cxs <<'IN' 2>&1
share="$(pg_config --sharedir)/extension"
echo "share=$share"
echo "version=$(sed -n "s/^default_version *= *'\(.*\)'.*/\1/p" "$share/yt_cluster.control")"
echo "scripts=$(cd "$share" && ls yt_cluster--*.sql 2>/dev/null | tr '\n' ' ')"
IN
)"
SHARE="$(sed -n 's/^share=//p' <<< "$facts")"
V="$(sed -n 's/^version=//p' <<< "$facts")"
SCRIPTS=" $(sed -n 's/^scripts=//p' <<< "$facts")"
check "U1 the image's control file names the version of yt-cluster-lite's VERSION" "$LITE_V" "$V"
case "$SCRIPTS" in *" yt_cluster--$V.sql "*) ok "U1 the image holds the script yt_cluster--$V.sql" ;;
	*) bad "U1 no yt_cluster--$V.sql in $SHARE: [$SCRIPTS ]" ;; esac
want=" yt_cluster--$V.sql"
for E in "${EARLIER[@]}"; do
	want="$want yt_cluster--$E--$V.sql"
	case "$SCRIPTS" in *" yt_cluster--$E--$V.sql "*) ok "U1 ...and the update script from $E, yt_cluster--$E--$V.sql" ;;
		*) bad "U1 no yt_cluster--$E--$V.sql in $SHARE: [$SCRIPTS ]" ;; esac
done
# a script of another version beside them and CREATE EXTENSION would offer it
check "U1 ...and no script of another version" "$(words "$want")" "$(words "$SCRIPTS")"
[ -n "$V" ] || summary

# ── the reference: a database created at this version ───────────────────────────
px postgres "drop database if exists xu_new" >/dev/null
px postgres "create database xu_new" >/dev/null
made="$(px xu_new "create extension yt_cluster")"
check "a database created now has $V" "$V" "$(version_of xu_new)"
case "$made" in *ERROR*) echo "$made" | head -5 | sed 's/^/     /' ;; esac
NEW_MEMBERS="$(members xu_new)"; NEW_SHAPE="$(shape xu_new)"
n_members="$(grep -c . <<< "$NEW_MEMBERS" || true)"
# md5 of nothing is null: an empty extension would compare equal to another empty one
[ "$n_members" -ge 30 ] && grep -q '^functions [0-9a-f]\{32\}$' <<< "$NEW_SHAPE" \
	|| { bad "the reference database has $n_members member(s) and no function digest - nothing to compare with"; summary; }

for E in "${EARLIER[@]}"; do
	# the script of $E: this version's, under that name (see the header)
	cxs <<IN >/dev/null 2>&1
cp "$SHARE/yt_cluster--$V.sql" "$SHARE/yt_cluster--$E.sql"
IN

	# ── U2, U3: nothing changed but the version ─────────────────────────────────
	px postgres "drop database if exists xu_plain" >/dev/null
	px postgres "create database xu_plain" >/dev/null
	px xu_plain "create extension yt_cluster version '$E'" >/dev/null
	check "U2 a database created at $E has $E" "$E" "$(version_of xu_plain)"
	up="$(px xu_plain "alter extension yt_cluster update")"
	check "U2 its update runs without an error" "0" "$(grep -c 'ERROR' <<< "$up" || true)"
	check "U2 ...and brings it to $V" "$V" "$(version_of xu_plain)"
	# every line the update script says of its own starts the same way: none here
	kept="$(grep -c 'yt_cluster update to' <<< "$up" || true)"
	check "U2 ...with no object kept as it was, no table in an older shape" "0" "$kept"
	[ "$kept" = 0 ] || grep 'yt_cluster update to' <<< "$up" | head -10 | sed 's/^/     /'
	same "U2 ...its members are those of a database created at $V ($n_members)" "$NEW_MEMBERS" "$(members xu_plain)"
	same "U2 ...and so are their functions, views, tables, event triggers and dumped tables" "$NEW_SHAPE" "$(shape xu_plain)"
	check "U3 a C function of the updated database answers" '{"a": 1}' \
		"$(px xu_plain "select yt_bson_to_json(yt_bson_from_json('{\"a\": 1}'::jsonb))")"
	again="$(px xu_plain "alter extension yt_cluster update")"
	case "$again" in
		*ERROR*) bad "U3 a second update fails: $(grep -m1 ERROR <<< "$again")" ;;
		*"already installed"*) ok "U3 a second update has nothing to do: $(grep -m1 -o 'version .* is already installed' <<< "$again")" ;;
		*) bad "U3 a second update said neither an error nor already installed: [$again]" ;;
	esac

	# ── U4, U5: what an older build of $E made ──────────────────────────────────
	px postgres "drop database if exists xu_old" >/dev/null
	px postgres "create database xu_old" >/dev/null
	px xu_old "create extension yt_cluster version '$E'" >/dev/null
	older="$(px xu_old "
		insert into yt_config (name, module, value) values ('ext_update_probe', 'F', 'kept');
		insert into yt_alert (class, source, subject, detail) values (2, 'test', 'ext_update', 'kept');
		-- not there yet when that build was installed: a function, a view, a table, an event trigger
		alter extension yt_cluster drop function yt_approve(text);          drop function yt_approve(text);
		alter extension yt_cluster drop view yt_config_effective;           drop view yt_config_effective;
		alter extension yt_cluster drop table yt_stat;                      drop table yt_stat;
		alter extension yt_cluster drop event trigger yt_ddl_idx;           drop event trigger yt_ddl_idx;
		-- and a table somebody made by hand: there, with its rows, and not the extension's
		alter extension yt_cluster drop table yt_alert;")"
	check "U4 the older database is made (a function, a view, a table and an event trigger gone, yt_alert not a member)" "0" \
		"$(grep -c 'ERROR' <<< "$older" || true)"
	check "U4 ...4 objects missing before the update" "f f f f" \
		"$(px xu_old "select to_regprocedure('yt_approve(text)') is not null, to_regclass('yt_config_effective') is not null,
		              to_regclass('yt_stat') is not null, exists(select 1 from pg_event_trigger where evtname = 'yt_ddl_idx')" | tr '|' ' ')"
	up="$(px xu_old "alter extension yt_cluster update")"
	check "U4 its update runs without an error" "0" "$(grep -c 'ERROR' <<< "$up" || true)"
	check "U4 ...and brings it to $V" "$V" "$(version_of xu_old)"
	check "U4 ...the function is back, and the extension's" "t" "$(is_member xu_old pg_proc "to_regprocedure('yt_approve(text)')")"
	check "U4 ...the view is back, and the extension's" "t" "$(is_member xu_old pg_class "to_regclass('yt_config_effective')")"
	check "U4 ...the table is back, and the extension's" "t" "$(is_member xu_old pg_class "to_regclass('yt_stat')")"
	check "U4 ...the event trigger is back, and the extension's" "t" \
		"$(is_member xu_old pg_event_trigger "(select oid from pg_event_trigger where evtname = 'yt_ddl_idx')")"
	check "U4 ...the hand-made table is not taken over: still no member" "f" "$(is_member xu_old pg_class "to_regclass('yt_alert')")"
	said="$(grep 'is kept as it is' <<< "$up" || true)"
	check "U4 ...and the update says it kept that table, in a WARNING" "1" "$(grep -c 'WARNING.*table [a-z_.]*yt_alert is kept as it is' <<< "$said" || true)"
	# what hangs on that table may be said too (its index); nothing else is
	check "U4 ...nothing but that table and what is on it was kept" "0" "$(grep -v 'yt_alert' <<< "$said" | grep -c . || true)"
	printf '%s\n' "$said" | head -6 | sed 's/^/     /'
	# but for that table, the database is what a new one is (its row types go with it)
	same "U4 ...the members are a new database's, all but that table" \
		"$(grep -v '^table yt_alert$\|^type yt_alert$\|^type yt_alert\[\]$' <<< "$NEW_MEMBERS")" \
		"$(members xu_old | grep -v '^table yt_alert$\|^type yt_alert$\|^type yt_alert\[\]$')"
	same "U4 ...and so are their functions, views, tables, event triggers and dumped tables" \
		"$(grep -v '^table yt_alert \|^index yt_alert\|^constraint yt_alert ' <<< "$NEW_SHAPE")" \
		"$(shape xu_old | grep -v '^table yt_alert \|^index yt_alert\|^constraint yt_alert ')"
	check "U4 ...no table is said to be in an older shape" "0" "$(grep -c 'has the shape an older version gave it' <<< "$up" || true)"
	check "U5 the setting written before the update is there" "kept" \
		"$(px xu_old "select value from yt_config where module = 'F' and name = 'ext_update_probe'")"
	check "U5 ...and the hand-made table's row" "1" "$(px xu_old "select count(*) from yt_alert where subject = 'ext_update'")"

	# ── U6: tables in the shape an older version gave them ──────────────────────
	px postgres "drop database if exists xu_shape" >/dev/null
	px postgres "create database xu_shape" >/dev/null
	px xu_shape "create extension yt_cluster version '$E'" >/dev/null
	shaped="$(px xu_shape "
		insert into yt_config (name, module, value) values ('ext_update_probe', 'F', 'kept');
		-- the config table as it was keyed once, and an alert table from before one of its columns
		alter table yt_config drop constraint yt_config_pkey;
		alter table yt_config add primary key (id);
		alter table yt_alert drop column pk;")"
	check "U6 the older shapes are made (yt_config keyed by id, yt_alert without pk)" "0" "$(grep -c 'ERROR' <<< "$shaped" || true)"
	up="$(px xu_shape "alter extension yt_cluster update")"
	check "U6 its update runs without an error" "0" "$(grep -c 'ERROR' <<< "$up" || true)"
	check "U6 ...and brings it to $V" "$V" "$(version_of xu_shape)"
	check "U6 ...saying the config table's key in a WARNING" "1" \
		"$(grep -c "WARNING.*table [a-z_.]*yt_config has the shape an older version gave it (columns it lacks: none; primary key: id, this version's: module, name)" <<< "$up" || true)"
	check "U6 ...and the column the alert table lacks" "1" \
		"$(grep -c "WARNING.*table [a-z_.]*yt_alert has the shape an older version gave it (columns it lacks: pk; primary key: id, this version's: id)" <<< "$up" || true)"
	check "U6 ...and of no other table" "2" "$(grep -c 'has the shape an older version gave it' <<< "$up" || true)"
	check "U6 ...nothing kept for another reason" "0" "$(grep -c 'is kept as it is\|is not compared' <<< "$up" || true)"
	grep 'yt_cluster update to' <<< "$up" | head -4 | sed 's/^/     /'
	check "U6 ...the tables are as they were: an update alters none" "id|f" \
		"$(px xu_shape "select (select string_agg(a.attname, ',') from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
		                 where i.indrelid = 'yt_config'::regclass and i.indisprimary),
		                exists(select 1 from pg_attribute where attrelid = 'yt_alert'::regclass and attname = 'pk' and not attisdropped)")"
	check "U6 ...and the setting written before it is there" "kept" \
		"$(px xu_shape "select value from yt_config where module = 'F' and name = 'ext_update_probe'")"

	# ── U7: the loaded library is an older one ──────────────────────────────────
	# What an older library is to the update: a C function of the script it has no symbol
	# for. The library here is this version's, so the update script is given a symbol it
	# does not have - a copy with one name changed, put back after.
	px postgres "drop database if exists xu_lib" >/dev/null
	px postgres "create database xu_lib" >/dev/null
	px xu_lib "create extension yt_cluster version '$E'" >/dev/null
	changed="$(cxs <<IN 2>&1
cp "$SHARE/yt_cluster--$E--$V.sql" /tmp/yt_update.keep \
	&& sed -i "s/'MODULE_PATHNAME', 'yt_bson_to_json'/'MODULE_PATHNAME', 'yt_symbol_of_a_newer_library'/" "$SHARE/yt_cluster--$E--$V.sql" \
	&& grep -c "yt_symbol_of_a_newer_library" "$SHARE/yt_cluster--$E--$V.sql"
IN
)"
	check "U7 the update script asks for one symbol the library does not have" "1" "$(tail -1 <<< "$changed")"
	up="$(px xu_lib "alter extension yt_cluster update")"
	check "U7 the update stops, and says the library is not this version's and to restart PostgreSQL" "1" \
		"$(grep -c "ERROR.*yt_cluster update to $V: the yt_cluster library PostgreSQL has loaded is not this version's.*restart PostgreSQL, then run ALTER EXTENSION yt_cluster UPDATE again" <<< "$up" || true)"
	grep -m1 'ERROR' <<< "$up" | cut -c1-230 | sed 's/^/     /'
	check "U7 ...the database left at $E, for the update to run again" "$E" "$(version_of xu_lib)"
	check "U7 ...and as it was: the function it had is not replaced" "t" \
		"$(px xu_lib "select prosrc = 'yt_bson_to_json' from pg_proc where oid = 'yt_bson_to_json(bytea)'::regprocedure")"
	restored="$(cxs <<IN 2>&1
cp /tmp/yt_update.keep "$SHARE/yt_cluster--$E--$V.sql" && rm -f /tmp/yt_update.keep && grep -c "yt_symbol_of_a_newer_library" "$SHARE/yt_cluster--$E--$V.sql"
IN
)"
	check "U7 the update script is put back" "0" "$(tail -1 <<< "$restored")"
	up="$(px xu_lib "alter extension yt_cluster update")"
	check "U7 with the library's function there the update runs" "0" "$(grep -c 'ERROR' <<< "$up" || true)"
	check "U7 ...and brings the database to $V" "$V" "$(version_of xu_lib)"
	same "U7 ...as a database created at $V" "$NEW_SHAPE" "$(shape xu_lib)"

	cxs <<IN >/dev/null 2>&1
rm -f "$SHARE/yt_cluster--$E.sql"
IN
done

summary
