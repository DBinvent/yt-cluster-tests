# ytperf-ycsb - YCSB with its MongoDB binding, the load generator of mongodb/run.sh: the
# same client against MongoDB and against DocumentDB's gateway on YT Cluster.
FROM eclipse-temurin:17-jre
ARG YCSB_VERSION=0.17.0
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://github.com/brianfrankcooper/YCSB/releases/download/${YCSB_VERSION}/ycsb-mongodb-binding-${YCSB_VERSION}.tar.gz" \
        | tar xz -C /opt; \
    ln -s "/opt/ycsb-mongodb-binding-${YCSB_VERSION}" /opt/ycsb; \
    test -x /opt/ycsb/bin/ycsb.sh
WORKDIR /opt/ycsb
ENTRYPOINT ["/opt/ycsb/bin/ycsb.sh"]
