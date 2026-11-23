# A YT Cluster node for the rmc test: PostgreSQL 18, the yt-cluster package (the
# extension and ytserv). The same image runs the load client, with its own
# entrypoint (lib.sh load_run), for psql.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
# [apt-retry] the archive drops connections and answers 522 now and then (nightly 2026-11-19,
# three runs): each download retried, and apt-get-update tries the index again - from the
# third failure on a mirror
RUN printf 'Acquire::Retries "8";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/80-retries \
    && printf '%s\n' '#!/bin/sh' 'for i in 1 2 3 4 5 6; do' 'apt-get update "$@" && exit 0' '[ $i -lt 3 ] || sed -i -e "s#http://[a-z.]*archive.ubuntu.com#http://mirrors.kernel.org#g" /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null' 'sleep 20' 'done' 'exit 1' > /usr/local/bin/apt-get-update \
    && chmod 755 /usr/local/bin/apt-get-update
RUN apt-get-update -q && apt-get install -qy --no-install-recommends \
        postgresql-18 postgresql-client-18 ca-certificates
COPY yt-cluster.deb /tmp/yt-cluster.deb
# apt, not dpkg -i: the package's dependencies come with it. libexpat1: the
# vendored libpython links it and the package does not depend on it.
RUN apt-get-update -q \
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
