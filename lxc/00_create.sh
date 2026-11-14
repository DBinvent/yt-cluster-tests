#!/usr/bin/env bash
# Launch the test container and install PostgreSQL.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if lxc info "$YX_CONTAINER" >/dev/null 2>&1; then
	echo "Container $YX_CONTAINER already exists - reusing (90_destroy.sh to reset)."
else
	lxc init "$YX_IMAGE" "$YX_CONTAINER"
	if [ "$YX_NIC" = "macvlan" ]; then
		parent="$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
		echo "Using macvlan on $parent (Docker-on-host workaround, see tests/README.md)"
		lxc config device add "$YX_CONTAINER" eth0 nic nictype=macvlan parent="$parent" name=eth0
	fi
	lxc start "$YX_CONTAINER"
fi

wait_for_container

echo "Installing PostgreSQL..."
# a mirror caught mid-sync answers "File has unexpected size ... Mirror sync in progress?" and
# apt-get update exits 100 (nightly 2026-11-10): try again after a pause, as the sync ends in minutes
for try in 1 2 3 4 5; do
	xc apt-get update -q -o Acquire::Retries=3 && break
	if [ "$try" = 5 ]; then echo "  FAIL: apt-get update failed 5 times" >&2; exit 1; fi
	echo "apt-get update failed (try $try of 5), again in 60 s"
	sleep 60
done
# libprotobuf-c1: runtime dep of the yt_cluster extension .so (matches deb Depends)
xc env DEBIAN_FRONTEND=noninteractive apt-get install -qy postgresql postgresql-client libpq-dev binutils libprotobuf-c1
xc systemctl enable --now postgresql

assert "postgres accepts connections" xc sudo -u postgres psql -tc "select 1"
echo "Container $YX_CONTAINER ready."
