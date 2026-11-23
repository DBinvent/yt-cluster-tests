#!/usr/bin/env bash
# [labac] The containers that need no setup of ours: PostgreSQL with its databases and roles,
# FerrisKey (its schema migrated first) and etcd. A run before is taken down first: every run
# starts from nothing.
cd "$(dirname "$0")"
source ./env.sh
labac_urls

echo "== down what a run before left =="
rh "docker rm -f ${LX_ALL[*]} >/dev/null 2>&1; docker network rm $LX_NET >/dev/null 2>&1; true"
rh "docker network create $LX_NET >/dev/null"

echo "== PostgreSQL =="
rh "docker run -q -d --name $LX_PG --network $LX_NET -e POSTGRES_PASSWORD=$LX_PG_PW $LABAC_PG_IMAGE >/dev/null"
for _ in $(seq 1 60); do
	# the server the image starts first, to initialize, listens on its socket only: wait for TCP
	rh "docker exec $LX_PG pg_isready -q -h 127.0.0.1 -U postgres" 2>/dev/null && break
	sleep 1
done
pg postgres <<SQL
CREATE DATABASE ferriskey;
CREATE DATABASE signon;
CREATE DATABASE app_lsr;
CREATE DATABASE app_rls;
-- the application's login: what a session through ytproxy starts as
CREATE ROLE $LX_APP_USER LOGIN PASSWORD '$LX_APP_PW';
-- the role signon's rules give a person: what ytproxy logs in to the node as for one
CREATE ROLE $LX_STAFF_ROLE LOGIN PASSWORD '$LX_STAFF_PW';
SQL
echo "  databases ferriskey, signon, app_lsr, app_rls; roles $LX_APP_USER, $LX_STAFF_ROLE"

echo "== etcd =="
rh "docker run -q -d --name $LX_ETCD --network $LX_NET $LABAC_ETCD_IMAGE etcd --name labac \
	--listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://$LX_ETCD:2379 >/dev/null"

echo "== FerrisKey =="
# its schema: the migrations its own image carries
rh "docker run -q --rm --network $LX_NET -e DATABASE_URL=postgresql://postgres:$LX_PG_PW@$LX_PG/ferriskey \
	--entrypoint sqlx $LABAC_FK_IMAGE migrate run --source /usr/local/src/ferriskey/migrations 2>&1 | tail -1"
rh "docker run -q -d --name $LX_FK --network $LX_NET -p $LABAC_FK_PORT:3333 \
	-e DATABASE_HOST=$LX_PG -e DATABASE_NAME=ferriskey -e DATABASE_USER=postgres -e DATABASE_PASSWORD=$LX_PG_PW \
	-e ALLOWED_ORIGINS=$FK_URL -e WEBAPP_URL=$FK_URL $LABAC_FK_IMAGE >/dev/null"
up=""
for _ in $(seq 1 60); do
	code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$FK_URL/realms/master/.well-known/openid-configuration" || true)"
	[ "$code" = 200 ] && { up=1; break; }
	sleep 1
done
[ -n "$up" ] || { echo "FerrisKey does not answer at $FK_URL" >&2; rh "docker logs --tail 20 $LX_FK" >&2; exit 1; }
echo "  FerrisKey answers at $FK_URL"
rh "docker ps --filter network=$LX_NET --format '  {{.Names}}  {{.Status}}'"
