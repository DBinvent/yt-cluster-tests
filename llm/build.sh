#!/usr/bin/env bash
# Build the node image (ytllm-node) from a yt-cluster package, and pull ClickHouse.
#
#   ./build.sh                 # YT_CLUSTER_DEB from .env / the environment
#
# YT_CLUSTER_DEB: a yt-cluster_<version>_amd64.deb, 0.16.7 or newer (R1's ClickHouse fallback),
# e.g. built in yt-pgxt with `cargo deb -p ytctl --no-build`. Unset: the newest
# in ../../yt-pgxt/target/debian, when that checkout is next to this one.
. "$(dirname "$0")/lib.sh"

deb="${YT_CLUSTER_DEB:-$(ls -t "$HERE"/../../yt-pgxt/target/debian/yt-cluster_*_amd64.deb 2>/dev/null | head -1)}"
[ -n "$deb" ] && [ -f "$deb" ] || die "no yt-cluster package: set YT_CLUSTER_DEB to a yt-cluster_<version>_amd64.deb"
say "== package $(basename "$deb") ($(md5sum < "$deb" | cut -c1-12)), docker ${DOCKER_HOST:-(default)}"

stage="$HERE/build"
rm -rf "$stage" && mkdir -p "$stage"
cp "$HERE"/node/Dockerfile "$HERE"/node/entrypoint.sh "$HERE"/node/requirements.txt "$stage"/
cp "$deb" "$stage/yt-cluster.deb"
docker build -t "$IMAGE" "$stage" || die "docker build failed"
rm -f "$stage/yt-cluster.deb"

docker pull -q "$CH_IMAGE" || die "docker pull $CH_IMAGE failed"
say "== $IMAGE: $(docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
    'dpkg-query -W -f="yt-cluster \${Version}, " yt-cluster; /opt/llm-df/bin/python -c "import datafusion, pyarrow; print(\"datafusion\", datafusion.__version__, \"pyarrow\", pyarrow.__version__)"')"
