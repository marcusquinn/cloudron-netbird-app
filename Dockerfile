FROM netbirdio/netbird-server:0.80.0@sha256:05b3d8d6d056e5062a2965d4d6e5d6d83f09f2bf9133947a8e5972e0e0e7a261 AS server
FROM netbirdio/dashboard:v2.93.0@sha256:b96c67fe89aaed7164513579d00565bd4326d8a5b8b8ee8c8ccf9ca7efa3f288 AS dashboard
FROM netbirdio/reverse-proxy:0.80.0@sha256:6d6655b3f13f837d80cc44878033866713932d3c5c1381ed869af9542b523bc5 AS proxy
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

# Copy the multi-architecture combined server image published for NetBird v0.80.0.
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
