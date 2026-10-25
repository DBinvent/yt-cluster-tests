#!/usr/bin/env bash
# [identity] Identity, generated and serial columns replicate and copy, and every
# node's sequences follow the values its replicated and copied rows brought.
#
# A row of a table with an identity column GENERATED ALWAYS reached no member:
# the apply named the identity column without OVERRIDING SYSTEM VALUE and the
# member refused it ("cannot insert a non-DEFAULT value into column"), as it
# refused the stored generated column the trigger sent along. An update set the
# key it left as it was ("can only be updated to DEFAULT"). A copy - a joining
# node's fill, a stage job, a reshape, a recon repair - wrote every column with
# `select *` and was refused the same way. And a member's own identity sequence
# stayed where it was: its next insert drew a key a replicated row already held.
#
# Written 2026-10-22 without a run; its first run is the next nightly.
#
# I1 rows written on n1 reach every node with n1's keys, each node computing the
#    generated column itself
# I2 an update of the column it is computed from replicates; the generated column
#    follows on every node
# I3 n2's own insert draws keys past n1's - its identity and serial sequences, and
#    the sequence of its own a column's default calls, were moved past them - and
#    reaches every node
# I4 a stage job copies a table with an identity key and a generated column from
#    the one node holding its rows to every member
# I5 after the copy a member's own insert draws a key past the copied ones
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== identity: identity ALWAYS, generated and serial columns replicate and copy; sequences follow =="

JT=public.yt_job
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
leader_now() {
	local n v
	for n in "${NODES[@]}"; do
		v="$(info "$n" O cluster)"
		case "$v" in *", Leader"|*", Leader, discrepancy"*) printf '%s' "$n"; return 0 ;; esac
	done
}
# a stage job asked for on <node>: its id, or what the insert said (26_stage.sh)
job_new() { # job_new <node> <table> <params>
	local out i
	for i in 1 2 3; do
		out="$(qt "$1" "begin; insert into $JT (kind, tabl, params) values ('stage', '$2', '$3') returning id; \
			select yt_complete(true); commit;" | head -1)"
		[[ "$out" =~ ^[0-9]+$ ]] && { printf '%s' "$out"; return 0; }
		sleep 5
	done
	printf '%s' "$out"
}
job_wait() { # job_wait <secs> <node> <id> <state>
	local i v=""
	for i in $(seq 1 $(( $1 / 5 ))); do
		v="$(qt "$2" "select state || ' ' || coalesce(reason, '') from $JT where id = $3")"
		case "$v" in "$4"*) break ;; failed*|refused*|cancelled*) break ;; esac
		sleep 5
	done
	printf '%s' "$v"
}
cleanup() {
	set +e
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists ident_t, ident_st; drop sequence if exists ident_g;" >/dev/null 2>&1
		cfg_delete "$n" public.ident_t A >/dev/null 2>&1 || true
		cfg_delete "$n" public.ident_st A >/dev/null 2>&1 || true
		# the job layer back off, as the fixture had it
		q "$n" "drop trigger if exists zytsync_public_yt_job_trigger on $JT;
		        drop trigger if exists zytsynct_public_yt_job on $JT;
		        delete from $JT where kind = 'stage';" >/dev/null 2>&1
		cfg_delete "$n" "$JT" A >/dev/null 2>&1 || true
	done
}

# ── setup ────────────────────────────────────────────────────────────────────
SRC=n2
trap cleanup EXIT
cleanup
for n in "${NODES[@]}"; do
	q "$n" "create sequence ident_g;
	        create table ident_t (id bigint generated always as identity primary key, s serial not null,
	          qty int not null, total int generated always as (qty * 2) stored, note text,
	          g bigint not null default nextval('ident_g'));
	        create table ident_st (id bigint generated always as identity primary key, qty int not null,
	          total int generated always as (qty * 2) stored);" >/dev/null
done
# rows written before the table is synced stay where they were written (I4)
q "$SRC" "insert into ident_st (qty) select g from generate_series(1, 20) g;" >/dev/null
register_table public.ident_t
register_table public.ident_st ""
register_table "$JT" ""
restart_all
await_cluster

# ── I1-I3: replicated writes ────────────────────────────────────────────────
q n1 "begin; insert into ident_t (qty, note) select g, 'n1-' || g from generate_series(1, 5) g;
      select yt_complete(true); commit;" >/dev/null
sleep 5
for n in "${NODES[@]}"; do
	check "I1 n1's rows on $n: count, keys, the generated column, the default's sequence" "5|5|5|30|5" \
		"$(q "$n" "select count(*) || '|' || max(id) || '|' || max(s) || '|' || sum(total) || '|' || max(g) from ident_t")"
done

q n1 "begin; update ident_t set qty = qty + 10 where id = 1; select yt_complete(true); commit;" >/dev/null
sleep 5
for n in "${NODES[@]}"; do
	check "I2 the update on $n, its generated column following" "11|22" \
		"$(q "$n" "select qty || '|' || total from ident_t where id = 1")"
done

q n2 "begin; insert into ident_t (qty, note) values (100, 'n2'); select yt_complete(true); commit;" >/dev/null
sleep 5
for n in "${NODES[@]}"; do
	check "I3 n2's own row on $n, its keys past n1's" "6|6|200|6" \
		"$(q "$n" "select id || '|' || s || '|' || total || '|' || g from ident_t where note = 'n2'")"
done

# ── I4-I5: a copy (a stage job) ─────────────────────────────────────────────
L="$(leader_now)"
[ -n "$L" ] || { bad "I4 no leader"; summary; }
ID="$(job_new "$L" "$YX_DB.public.ident_st" "source=$(node_uuid $SRC)")"
if [[ "$ID" =~ ^[0-9]+$ ]]; then
	r="$(job_wait 420 "$L" "$ID" done)"
	case "$r" in
		done*) ok "I4 the stage job is done - ${r#done }" ;;
		*) bad "I4 the stage job did not end done within 420s: [$r]" ;;
	esac
else
	bad "I4 the stage job was not inserted: $ID"
fi
for n in "${NODES[@]}"; do
	check "I4 the copied rows on $n: count, keys, the generated column" "20|20|420" \
		"$(q "$n" "select count(*) || '|' || max(id) || '|' || sum(total) from ident_st")"
done

q n4 "begin; insert into ident_st (qty) values (500); select yt_complete(true); commit;" >/dev/null
got=0
for i in $(seq 1 12); do
	got=0
	for n in "${NODES[@]}"; do [ "$(q "$n" "select id || '|' || total from ident_st where qty = 500")" = "21|1000" ] && got=$((got + 1)); done
	[ "$got" = "${#NODES[@]}" ] && break
	sleep 5
done
check "I5 n4's own row, its key past the copied ones, on every node" "${#NODES[@]}" "$got"
summary
