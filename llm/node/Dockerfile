# One YT Cluster node of the llm test cluster: PostgreSQL 18, the yt-cluster package
# (extension + ytserv + ytctl) and DataFusion for yt_llm's df target.
#
# build.sh stages this directory with the package as yt-cluster.deb. Nothing is
# compiled here: the package is built elsewhere, the same rule as a real node.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        postgresql-18 postgresql-client-18 ca-certificates python3 python3-venv

# `apt-get install ./file.deb`, not `dpkg -i`: the package's Depends (libcurl,
# libpq) are fetched too. libexpat1 is needed by the embedded libpython but is
# not in the Depends. The index is refreshed in this layer, so a cached one
# cannot point at superseded versions.
COPY yt-cluster.deb /tmp/yt-cluster.deb
RUN apt-get update -q \
    && apt-get install -qy /tmp/yt-cluster.deb libexpat1 \
    && rm -f /tmp/yt-cluster.deb && rm -rf /var/lib/apt/lists/*
RUN ldconfig \
    && test -x /usr/local/bin/yt-cluster/ytserv \
    && ! ldd /usr/local/bin/yt-cluster/ytserv | grep -q "not found"

# The extension in PostgreSQL's own directories (on a real node `ytctl --batch`
# copies it); baked in so the three containers share the layer.
# By pattern: the names carry the extension's version. One library, or the build stops.
RUN so="$(ls /usr/local/include/yt-cluster/yt_cluster*-pg18-glibc2_39.so)" \
    && { [ "$(printf '%s\n' "$so" | wc -l)" = 1 ] \
         || { echo "one yt_cluster library for PostgreSQL 18 and glibc 2.39 expected in the package, found:" $so >&2; exit 1; }; } \
    && cp "$so" "$(pg_config --pkglibdir)/yt_cluster.so" \
    && cp /usr/local/include/yt-cluster/yt_cluster.control /usr/local/include/yt-cluster/yt_cluster--*.sql \
          "$(pg_config --sharedir)/extension/"

# DataFusion for the df target: a venv of its own (C llm_df_python). ytserv
# copies the rows out itself; this python only computes.
COPY requirements.txt /opt/llm-df/requirements.txt
RUN python3 -m venv /opt/llm-df \
    && /opt/llm-df/bin/pip install -q --no-cache-dir --disable-pip-version-check -r /opt/llm-df/requirements.txt \
    && /opt/llm-df/bin/python -c "import datafusion, pyarrow; print('datafusion', datafusion.__version__, 'pyarrow', pyarrow.__version__)"

# the cluster WAL, the log, and the ClickHouse cluster file ytserv renders
RUN mkdir -p /var/yt-cluster /var/log/yt-cluster /etc/yt-cluster/clickhouse \
    && chown postgres:postgres /var/yt-cluster /var/log/yt-cluster

COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
