#!/bin/bash
# ytperf-ytdoc: the yt image's entrypoint as it is (PostgreSQL, the node's setup, ytserv),
# and DocumentDB's gateway beside them as the postgres user (docdb-gateway.sh)
set -Eeuo pipefail
if [ "${1:-}" = postgres ]; then
	gosu postgres docdb-gateway.sh &
fi
exec yt-entrypoint.sh "$@"
