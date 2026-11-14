# A YT Cluster node for the rmc test: PostgreSQL 18, the yt-cluster package (the
# extension and ytserv). The same image runs the load client, with its own
# entrypoint (lib.sh load_run), for psql.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        postgresql-18 postgresql-client-18 ca-certificates
COPY yt-cluster.deb /tmp/yt-cluster.deb
# apt, not dpkg -i: the package's dependencies come with it. libexpat1: the
# vendored libpython links it and the package does not depend on it.
RUN apt-get update -q \
    && apt-get install -qy /tmp/yt-cluster.deb libexpat1 \
    && rm -f /tmp/yt-cluster.deb && rm -rf /var/lib/apt/lists/*
RUN ldconfig \
    && test -x /usr/local/bin/yt-cluster/ytserv \
    && ! ldd /usr/local/bin/yt-cluster/ytserv | grep -q "not found"
# By pattern: the names carry the extension's version. One library, or the build stops.
RUN so="$(ls /usr/local/include/yt-cluster/yt_cluster*-pg18-glibc2_39.so)" \
    && { [ "$(printf '%s\n' "$so" | wc -l)" = 1 ] \
         || { echo "one yt_cluster library for PostgreSQL 18 and glibc 2.39 expected in the package, found:" $so >&2; exit 1; }; } \
    && cp "$so" "$(pg_config --pkglibdir)/yt_cluster.so" \
    && cp /usr/local/include/yt-cluster/yt_cluster.control /usr/local/include/yt-cluster/yt_cluster--*.sql \
          "$(pg_config --sharedir)/extension/"
RUN mkdir -p /var/yt-cluster /var/log/yt-cluster \
    && chown postgres:postgres /var/yt-cluster /var/log/yt-cluster
COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
