# pgbench-m2m node - one YT Cluster node: the dbinvent/yt image (PostgreSQL 18 and ytserv beside
# it) with the yt-cluster deb under test installed over its package, as mongodb/ytdoc does, and
# the pgbench tables made and filled on its first start (10-m2m.sh). Built by run.sh; nothing
# here is published.
#
# WITH_DEB=0: the published image as it is - its own package - with the pgbench tables only:
# the backward-compatibility cell's nodes of the last release (run.sh, M2M_COMPAT).
ARG YT_BASE_IMAGE=dbinvent/yt:latest
FROM ${YT_BASE_IMAGE}
ARG WITH_DEB=1
COPY yt-cluster.deb /tmp/yt-cluster.deb
RUN set -eux; \
    if [ "$WITH_DEB" != 1 ]; then rm -f /tmp/yt-cluster.deb; /usr/local/bin/yt-cluster/ytserv --version; exit 0; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-downgrades /tmp/yt-cluster.deb; \
    rm -rf /var/lib/apt/lists/* /tmp/yt-cluster.deb; \
    B=/usr/local/bin/yt-cluster; E=/usr/local/include/yt-cluster; \
    rm -f /usr/local/bin/ytctl-* "$B"/ytserv-* "$E"/*.a; \
    rm -rf /usr/local/lib/yt-cluster /etc/ld.so.conf.d/yt-cluster.conf; ldconfig; \
    glibc="$(ldd --version | head -1 | grep -oE '[0-9]+$')"; so=""; \
    for f in $(ls "$E"/yt_cluster*-pg"$PG_MAJOR"-glibc2_*.so | sort -V); do \
        m="${f##*-glibc2_}"; [ "${m%.so}" -gt "$glibc" ] || so="$f"; \
    done; \
    test -n "$so"; \
    find "$E" -name 'yt_cluster*.so' ! -path "$so" -delete; \
    cp "$so" "$(pg_config --pkglibdir)/yt_cluster.so"; \
    cp "$E/yt_cluster.control" "$E"/yt_cluster--*.sql "$(pg_config --sharedir)/extension/"; \
    "$B/ytserv" --version
COPY 10-m2m.sh /docker-entrypoint-initdb.d/10-m2m.sh
RUN chmod 755 /docker-entrypoint-initdb.d/10-m2m.sh
