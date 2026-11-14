# ytperf-ytdoc - one YT Cluster node with DocumentDB: the dbinvent/yt image (PostgreSQL 18
# and ytserv beside it), the yt-cluster deb under test installed over its package,
# DocumentDB's extension from the PostgreSQL apt repository (postgresql-18-documentdb,
# the official 1.0 build) and DocumentDB's gateway - the MongoDB wire protocol - copied
# from DocumentDB's own image of the same release. Built by mongodb/run.sh, for the
# YCSB comparison only: nothing here is published.
ARG YT_BASE_IMAGE=dbinvent/yt:latest
ARG DOCDB_IMAGE=ghcr.io/documentdb/documentdb/documentdb-local:pg18-1.0.0
FROM ${DOCDB_IMAGE} AS docdb

FROM ${YT_BASE_IMAGE}
# the deb under test, over the image's package: its extension copied where PostgreSQL
# loads it from, as the yt image's own Dockerfile does
COPY yt-cluster.deb /tmp/yt-cluster.deb
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-downgrades /tmp/yt-cluster.deb postgresql-18-documentdb; \
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
    "$B/ytserv" --version; \
    test -f "$(pg_config --sharedir)/extension/documentdb.control"

COPY --from=docdb /home/documentdb/gateway/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway \
    /usr/local/bin/documentdb_gateway
COPY 0-docdb.sh /docker-entrypoint-initdb.d/0-docdb.sh
COPY docdb-gateway.sh docdb-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/documentdb_gateway /usr/local/bin/docdb-gateway.sh /usr/local/bin/docdb-entrypoint.sh \
    && chmod 644 /docker-entrypoint-initdb.d/0-docdb.sh \
    && ldd /usr/local/bin/documentdb_gateway | grep -v 'not found' >/dev/null

EXPOSE 10260
ENTRYPOINT ["tini", "--", "docdb-entrypoint.sh"]
CMD ["postgres"]
