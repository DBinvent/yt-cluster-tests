#!/bin/bash
# ytperf-ytdoc, a fresh volume: DocumentDB's settings beside the yt image's. Its libraries
# join shared_preload_libraries wherever the list is: yt.conf (conf.d, written by the yt
# image's 00-yt-cluster.sh, which may run first - the locale's collation ignores the `-`)
# or postgresql.conf, which yt-node conf reads and keeps. The extension itself is created
# by run.sh once the server runs with them: this script runs on the official entrypoint's
# temporary server, which does not load them.
#   DOCDB_DB  the database DocumentDB keeps its collections in (default docdb) - one the
#             cluster replicates (YT_USERS_DB)
set -Eeuo pipefail
db="${DOCDB_DB:-docdb}"
libs="pg_cron, pg_documentdb_core, pg_documentdb"
y="$PGDATA/conf.d/yt.conf"
if [ -f "$y" ]; then
	sed -i -E "s/^[[:space:]]*shared_preload_libraries[[:space:]]*=[[:space:]]*'([^']*)'/shared_preload_libraries = '$libs, \1'/" "$y"
	grep -q "pg_documentdb" "$y"
else
	echo "shared_preload_libraries = '$libs'" >> "$PGDATA/postgresql.conf"
fi
cat >> "$PGDATA/postgresql.conf" <<EOF
# ytperf-ytdoc: DocumentDB (0-docdb.sh)
cron.database_name = '$db'
EOF
# the gateway's own connection: the superuser over the loopback, trusted - the first
# line of pg_hba.conf, ahead of the image's password rule for every host
sed -i '1i host all postgres 127.0.0.1/32 trust' "$PGDATA/pg_hba.conf"
