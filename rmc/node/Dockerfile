# A yt-cluster node for the rmc test: PostgreSQL 18, the yt-cluster package (the
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
RUN cp /usr/local/include/yt-cluster/yt_cluster0_5-pg18-glibc2_39.so "$(pg_config --pkglibdir)/yt_cluster.so" \
    && cp /usr/local/include/yt-cluster/yt_cluster.control /usr/local/include/yt-cluster/yt_cluster--0.5.sql \
          "$(pg_config --sharedir)/extension/"
RUN mkdir -p /var/yt-cluster /var/log/yt-cluster \
    && chown postgres:postgres /var/yt-cluster /var/log/yt-cluster
COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
