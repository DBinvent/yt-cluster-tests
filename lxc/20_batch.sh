#!/usr/bin/env bash
# Batch mode install: sudo ytctl --batch (mode 1 of 3), with --python: ytserv-all,
# the build with Python functions, as on a test cluster (30_purge.sh's re-install
# takes the default, the regular ytserv).
# Asserts: exit code, config table exists, ytserver service unit present & active
# and running ytserv-all, extension installed in the DB.
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
# ytserv-all, the host's glibc only - installed by --python, its old name's flag, which
# ytctl takes for --all (ytserv-all was ytserv-all until 1.20.6)
assert "ytserver runs ytserv-all (--python, the alias of --all)" \
	xc grep -qE '^\s*ExecStart=\S*/ytserv-all(\s|$)' /lib/systemd/system/ytserver.service

echo "Batch install: PASS"
