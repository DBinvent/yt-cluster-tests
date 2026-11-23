#!/usr/bin/env bash
# [labac] Build what the environment runs, here: ytproxy with its labac feature, and the host
# program (host/). Both run in $LABAC_BASE_IMAGE containers on the docker host, so this machine's
# libc must be that image's (ubuntu:24.04 unless set).
cd "$(dirname "$0")"
source ./env.sh

[ -f "$YTPROXY_ROOT/Cargo.toml" ] || { echo "no ytproxy checkout at $YTPROXY_ROOT - set YTPROXY" >&2; exit 1; }
echo "Building ytproxy (--features labac) in $YTPROXY_ROOT ..."
( cd "$YTPROXY_ROOT" && cargo build --release --features labac 2>&1 | tail -1 )
echo "Building labac-host ..."
( cd "$LABAC_ROOT/host" && cargo build --release 2>&1 | tail -1 )
for b in "$LX_YTPROXY_BIN" "$LX_HOST_BIN"; do
	[ -x "$b" ] || { echo "not built: $b" >&2; exit 1; }
	echo "  $(basename "$b") $(stat -c '%s bytes, %y' "$b" | cut -d. -f1)"
done
