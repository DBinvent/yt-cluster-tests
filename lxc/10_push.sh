#!/usr/bin/env bash
# Push ytctl artifacts into the container: the .deb when YX_DEB is set,
# otherwise raw binaries + extension files from the build tree.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ -n "$YX_DEB" ]; then
	echo "Pushing $YX_DEB ..."
	lxc file push "$YX_DEB" "$YX_CONTAINER/tmp/yt-cluster.deb"
	xc env DEBIAN_FRONTEND=noninteractive apt-get install -qy /tmp/yt-cluster.deb
else
	echo "No YX_DEB set — pushing binaries from $YX_BIN_DIR ..."
	for b in ytctl ytserv; do
		if [ ! -x "$YX_BIN_DIR/$b" ]; then
			echo "missing $YX_BIN_DIR/$b — run: cargo build --release" >&2
			exit 1
		fi
	done
	xc mkdir -p /usr/local/bin/yt-cluster /usr/local/include/yt-cluster
	lxc file push "$YX_BIN_DIR/ytctl" "$YX_CONTAINER/usr/local/bin/ytctl"
	lxc file push "$YX_BIN_DIR/ytserv" "$YX_CONTAINER/usr/local/bin/yt-cluster/ytserv"
	# per-libc variants (deb layout) when built — exercises find_bin's best-match
	# selection among ytserv, ytserv-glibc2_35, ytserv-musl
	for v in "$REPO_ROOT"/target/glibc*/ytserv-glibc* "$REPO_ROOT"/target/musl/ytserv-musl; do
		if [ -f "$v" ]; then
			lxc file push "$v" "$YX_CONTAINER/usr/local/bin/yt-cluster/$(basename "$v")"
			xc chmod 755 "/usr/local/bin/yt-cluster/$(basename "$v")"
		fi
	done
	# extension binaries + control/sql (installed by ytctl into the PG dirs)
	if ls "$REPO_ROOT"/ytpgc/dist/*.so >/dev/null 2>&1; then
		for f in "$REPO_ROOT"/ytpgc/dist/*; do
			[ -f "$f" ] && lxc file push "$f" "$YX_CONTAINER/usr/local/include/yt-cluster/"
		done
	fi
	for f in "$REPO_ROOT"/ytpgc/yt_cluster.control "$REPO_ROOT"/ytpgc/yt_cluster--*.sql; do
		[ -f "$f" ] && lxc file push "$f" "$YX_CONTAINER/usr/local/include/yt-cluster/"
	done
	xc chmod 755 /usr/local/bin/ytctl /usr/local/bin/yt-cluster/ytserv
fi

# older container (e.g. ubuntu:22.04, glibc 2.35) cannot run the host-built ytctl —
# fall back to the glibc variant, same as a real user on that release would
if ! xc ytctl --help >/dev/null 2>&1; then
	for alt in "$REPO_ROOT"/target/glibc*/ytctl-glibc*; do
		if [ -f "$alt" ]; then
			echo "native ytctl does not run here — pushing $(basename "$alt") as ytctl"
			lxc file push "$alt" "$YX_CONTAINER/usr/local/bin/ytctl"
			xc chmod 755 /usr/local/bin/ytctl
			break
		fi
	done
fi

assert "ytctl --help runs" xc ytctl --help
echo "Artifacts pushed."
