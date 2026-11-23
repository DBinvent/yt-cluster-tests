#!/usr/bin/env bash
# [labac] signon's side and ytproxy's: the host program with signon's tables, its mapping rules
# and its ACL (signon.json); the test schema deployed by schema_guard into app_lsr (lsr) and
# app_rls (rls) with its rows (schema.yaml, data.sql); the schema map in etcd; ytproxy twice,
# one per mode. Needs 00_build.sh and 10_up.sh.
cd "$(dirname "$0")"
source ./env.sh
labac_urls
for b in "$LX_YTPROXY_BIN" "$LX_HOST_BIN"; do [ -x "$b" ] || { echo "not built: $b - run 00_build.sh" >&2; exit 1; }; done
PGURL="postgres://postgres:$LX_PG_PW@$LX_PG:5432"

echo "== this run's keys =="
# signon's labac token key: the host program signs a person's token with it, ytproxy checks it
# (token_key_file). And the key of the rls database (its labac.key): ytproxy signs what it enters
# a subject with, the database checks it. Two keys, neither kept past the run.
( umask 077
  python3 -c 'import secrets; print(secrets.token_hex(32))' > "$LX_RUN/token.key"
  python3 -c 'import secrets; print(secrets.token_hex(32))' > "$LX_RUN/enter.key" )

echo "== the host program =="
rh "docker rm -f $LX_HOSTC $LX_LSR $LX_RLS >/dev/null 2>&1; true"
rh "docker create --name $LX_HOSTC --network $LX_NET -p $LABAC_HOST_PORT:8080 \
	-e LABAC_DB_URL=$PGURL/signon -e LABAC_TOKEN_KEY_FILE=/labac/token.key \
	-e LABAC_ISSUER=$LX_ISSUER -e LABAC_AUDIENCE=$LX_CLIENT \
	-e LABAC_JWKS_URL=http://$LX_FK:3333/realms/$LX_REALM/protocol/openid-connect/jwks.json \
	$LABAC_BASE_IMAGE /labac/labac-host serve >/dev/null"
mkdir -p "$LX_RUN/labac"
cp "$LX_HOST_BIN" "$LX_RUN/token.key" "$LX_RUN/enter.key" signon.json schema.yaml "$LX_RUN/labac/"
put_file "$LX_HOSTC" "$LX_RUN/labac" /
rh "docker start $LX_HOSTC >/dev/null"
up=""
for _ in $(seq 1 60); do
	[ "$(curl -s -m 5 "$HOST_URL/health" || true)" = ok ] && { up=1; break; }
	sleep 1
done
[ -n "$up" ] || { echo "the host program does not answer at $HOST_URL" >&2; rh "docker logs --tail 30 $LX_HOSTC" >&2; exit 1; }
echo "  answers at $HOST_URL: signon's tables are in"
# hx <command..>: a command of the host program, in its container; its last line is what it did
hx() { rh "docker exec -e RUST_LOG=warn $LX_HOSTC /labac/labac-host $*"; }

echo "== signon: the mapping rules, the resources, the ACL =="
echo "  $(hx seed /labac/signon.json | tail -1)"

echo "== the test schema: app_lsr under lsr, app_rls under rls =="
echo "  app_lsr: $(hx deploy "$PGURL/app_lsr" /labac/schema.yaml lsr | tail -1)"
echo "  app_rls: $(hx deploy "$PGURL/app_rls" /labac/schema.yaml rls | tail -1)"
echo "  app_rls: $(hx key "$PGURL/app_rls" /labac/enter.key | tail -1)"
for db in app_lsr app_rls; do pg "$db" < data.sql; done
check "app_lsr: the tables are registered, no policy made" "4 0" \
	"$(echo "SELECT (SELECT count(*) FROM labac.tables), (SELECT count(*) FROM pg_policies)" | pg app_lsr | tr '|' ' ')"
check "app_rls: the tables are registered, row-level security forced on each" "4 4" \
	"$(echo "SELECT (SELECT count(*) FROM labac.tables WHERE rls), (SELECT count(*) FROM pg_class WHERE relforcerowsecurity)" | pg app_rls | tr '|' ' ')"
check "the declaration of docs: its three paths by name, in the registry" \
	'public.docs.project_id|public.projects.dept {"review":"review","sal":"public.docs.project_id|public.projects.sal"}' \
	"$(echo "SELECT column_name || ' ' || levels FROM labac.tables WHERE table_name = 'docs'" | pg app_rls)"

echo "== the schema map, in etcd =="
# What ytserv keeps there in YT Cluster - each table's structure, its primary key, its grants,
# its security declaration - which ytproxy reads the covered tables and their join keys from.
# No node runs here, so the host program says the keys and they are put by hand.
n=0
for db in app_lsr app_rls; do
	hx schema-map "$PGURL/$db" "$LX_CLUSTER" > "$LX_RUN/map.$db"
	while IFS=$'\t' read -r key value; do
		printf '%s' "$value" | rhi "docker exec -i $LX_ETCD etcdctl put '$key' >/dev/null"
		n=$((n+1))
	done < "$LX_RUN/map.$db"
done
check "8 tables in the map" 8 "$n"
check "docs in the map: schemaPath is the map of its named paths" \
	'{"dml": ["public.docs.project_id", "public.projects.dept"], "review": ["review"], "sal": ["public.docs.project_id", "public.projects.sal"]}' \
	"$(rh "docker exec $LX_ETCD etcdctl get --print-value-only schema/cluster:$LX_CLUSTER/app_lsr/public/docs" | jv security.schemaPath)"

echo "== ytproxy: lsr over app_lsr, rls over app_rls =="
verifier="$("$LX_YTPROXY_BIN" --hash "$LX_APP_PW")"
for mode in lsr rls; do
	if [ "$mode" = lsr ]; then c="$LX_LSR"; else c="$LX_RLS"; fi
	dir="$LX_RUN/ytproxy-$mode"; mkdir -p "$dir/ytproxy"
	cp "$LX_YTPROXY_BIN" "$LX_RUN/token.key" "$dir/ytproxy/"
	{
		cat <<TOML
listen = "0.0.0.0:6432"
nodes = ["$LX_PG:5432"]

# the application's login: a session starts as it and enters a person's token (SET labac.token)
[[users]]
name = "$LX_APP_USER"
secret = "$verifier"

[[backend]]
user = "$LX_APP_USER"
password = "$LX_APP_PW"

# the role signon's rules give a person: its statements run on the node as this one
[[backend]]
user = "$LX_STAFF_ROLE"
password = "$LX_STAFF_PW"

[security]
mode = "$mode"
enforce = true
db_url = "$PGURL/signon"
refresh_sec = 2
token_key_file = "/ytproxy/token.key"
etcd = "http://$LX_ETCD:2379"
cluster = "$LX_CLUSTER"
TOML
		# rls: the login that reads the database's labac.key, to sign what a subject is entered with
		[ "$mode" = lsr ] || echo "key_db_url = \"$PGURL/app_rls\""
	} > "$dir/ytproxy/ytproxy.toml"
	rh "docker create --name $c --network $LX_NET -e RUST_LOG=info $LABAC_BASE_IMAGE \
		/ytproxy/ytproxy --config /ytproxy/ytproxy.toml >/dev/null"
	put_file "$c" "$dir/ytproxy" /
	rh "docker start $c >/dev/null"
done
for mode in lsr rls; do
	got=""
	for _ in $(seq 1 30); do
		got="$(echo "SELECT 1" | sqlp "$mode" -)"
		[ "$got" = 1 ] && break
		sleep 1
	done
	check "ytproxy $mode answers the application's login" 1 "$got"
done
[ "$fail" -eq 0 ] || { for c in "$LX_LSR" "$LX_RLS"; do echo "--- $c"; rh "docker logs --tail 20 $c" || true; done; }
summary
