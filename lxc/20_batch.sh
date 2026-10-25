#!/usr/bin/env bash
# Batch mode install: sudo ytctl --batch (mode 1 of 3), with --python: ytserv-py,
# the build with Python functions, as on a test cluster (30_purge.sh's re-install
# takes the default, the regular ytserv).
# Asserts: exit code, config table exists, ytserver service unit present & active
# and running ytserv-py, extension installed in the DB.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "Running batch install (-t $YX_TARGET, --python)..."
xc ytctl -v --python --batch -t "$YX_TARGET" \
	--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql"

assert "config table $YX_TARGET exists" \
	xc sudo -u postgres psql -tc "select 1 from $YX_TARGET limit 1"
assert "yt_cluster extension present in DB" \
	xc sudo -u postgres psql -tc "select 1 from pg_extension where extname like 'ya%' or extname like 'yt%'"
assert "ytserver unit exists" xc test -f /lib/systemd/system/ytserver.service
assert "ytserver active" xc systemctl is-active ytserver
# ytserv-py or its per-libc variant (ytserv-py-glibc2_35, ytserv-py-musl)
assert "ytserver runs ytserv-py (--python)" \
	xc grep -qE '^\s*ExecStart=\S*/ytserv-py(-glibc[0-9_]+|-musl)?(\s|$)' /lib/systemd/system/ytserver.service

echo "Batch install: PASS"
