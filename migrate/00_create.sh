#!/usr/bin/env bash
# The boxes: one container with PostgreSQL installed and nothing of YT Cluster,
# copied into the database servers - the copy's box (MIG_COPY) among them. Records
# each one's address and the uuid its `ytctl --peers` roster gives it. Replication
# connections are let in too, as a copy's source must (35_copy.sh).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

nodes() { local n; for n in $MIG_NODES $MIG_COPY; do cname "$n"; done; }
base="$MIG_PREFIX-base"
for c in "$base" $(nodes); do lxc delete --force "$c" >/dev/null 2>&1; done
rm -rf "${RUN:?}"/*

say "-- $(now) $base: $MIG_IMAGE with PostgreSQL $MIG_PG (apt.postgresql.org)"
lxc init "$MIG_IMAGE" "$base" >/dev/null || { bad "lxc init $MIG_IMAGE"; finish; }
if [ "$MIG_NIC" = macvlan ]; then
	parent="$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
	lxc config device add "$base" eth0 nic nictype=macvlan parent="$parent" name=eth0 >/dev/null
fi
lxc start "$base"
wait_container "$base" || { bad "$base did not come up"; finish; }
lxc exec "$base" -- apt-get update -q >/dev/null 2>&1
lxc exec "$base" -- env DEBIAN_FRONTEND=noninteractive apt-get install -qy postgresql-common ca-certificates curl >/dev/null 2>&1
lxc exec "$base" -- /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1
lxc exec "$base" -- env DEBIAN_FRONTEND=noninteractive apt-get install -qy "postgresql-$MIG_PG" >/dev/null 2>&1
# an ordinary server: reachable over the network, password auth
lxc exec "$base" -- sh -c "echo \"listen_addresses = '*'\" > /etc/postgresql/$MIG_PG/main/conf.d/listen.conf \
	&& echo 'host all all 0.0.0.0/0 scram-sha-256' >> /etc/postgresql/$MIG_PG/main/pg_hba.conf \
	&& echo 'host replication all 0.0.0.0/0 scram-sha-256' >> /etc/postgresql/$MIG_PG/main/pg_hba.conf \
	&& chown -R postgres:postgres /etc/postgresql/$MIG_PG/main/conf.d"
v="$(lxc exec "$base" -- su postgres -c "psql -X -At -c 'show server_version'" 2>/dev/null | cut -d. -f1)"
check "$base runs PostgreSQL $MIG_PG from apt.postgresql.org" "$MIG_PG" "$v"
check "$base: max_prepared_transactions is PostgreSQL's default, 0" 0 \
	"$(lxc exec "$base" -- su postgres -c "psql -X -At -c 'show max_prepared_transactions'" 2>/dev/null)"
lxc stop "$base"

for c in $(nodes); do lxc copy "$base" "$c" && lxc start "$c"; done
for c in $(nodes); do wait_container "$c" || bad "$c did not come up"; done
lxc delete --force "$base" >/dev/null
for n in $MIG_NODES $MIG_COPY; do
	ip="$(nip "$n")"
	if [ -n "$ip" ]; then
		echo "$ip" > "$RUN/ip.$n"
		node_uuid "$ip" > "$RUN/uuid.$n"
		ok "$(cname "$n") at $ip, yt.node to be $(nuuid "$n")"
	else
		bad "$(cname "$n") has no address"
	fi
done
finish
