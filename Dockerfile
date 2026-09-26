FROM netbirdio/netbird-server:0.79.0@sha256:d1da0c0179c9e6f2ab7b48be54d06341b11037855a9426b9f2536aa79f13360b AS server
FROM netbirdio/dashboard:v2.92.0@sha256:fa2d8b02a81761e4d2a22df4041d13316b7635f1e93273eafeb53d4991e55b5a AS dashboard
FROM netbirdio/reverse-proxy:0.79.0@sha256:f18745746dfc797dfc60418b9c2714671aee0e020317df47fb22f37329c2dd54 AS proxy
FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    gettext-base \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the multi-architecture combined server image published for NetBird v0.79.0.
RUN mkdir -p /app/code/bin
COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server
RUN chmod +x /app/code/bin/netbird-server

COPY --from=proxy /go/bin/netbird-proxy /app/code/bin/netbird-proxy
COPY scripts/start-proxy.sh /app/code/start-proxy.sh
RUN chmod +x /app/code/bin/netbird-proxy /app/code/start-proxy.sh

# Copy the independently pinned dashboard release.
COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/

# Copy supervisord config
COPY supervisord.conf /app/code/supervisord.conf

# Copy start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# Expose dashboard/API HTTP plus the dedicated native TLS transport.
EXPOSE 8080 33074 8443

# Expose STUN UDP port
EXPOSE 3478/udp

CMD ["/app/code/start.sh"]
