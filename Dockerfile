FROM netbirdio/netbird-server:0.81.1@sha256:5d3af2d0ed14562ea7da97a4d47d1459fc5769647aeb8557c40b2322df6585c0 AS server
FROM netbirdio/dashboard:v2.94.0@sha256:70e0fc6dd3b7758148d182fb55ecd8d4f9ce01e9bba56c9389224e0b8354009d AS dashboard
FROM netbirdio/reverse-proxy:0.81.1@sha256:53e64cbb5ac5a9d27f3b1ea8d5063163f016194778c9060ac0e368563909254b AS proxy
FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    gettext-base \
    ca-certificates \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Copy the multi-architecture combined server image published for NetBird v0.81.1.
RUN mkdir -p /app/code/bin
COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server
RUN chmod +x /app/code/bin/netbird-server

COPY --from=proxy /go/bin/netbird-proxy /app/code/bin/netbird-proxy
COPY scripts/start-proxy.sh /app/code/start-proxy.sh
COPY scripts/setup-sso-bootstrap.py /app/code/setup-sso-bootstrap.py
RUN chmod +x /app/code/bin/netbird-proxy /app/code/start-proxy.sh /app/code/setup-sso-bootstrap.py

# Copy the independently pinned dashboard release.
COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/

# Copy supervisord config
COPY supervisord.conf /app/code/supervisord.conf

# Copy start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# Expose dashboard/API HTTP plus the dedicated native TLS transport.
EXPOSE 8080 33074 8443

# STUN defaults to Cloudron's platform service. The optional embedded STUN
# server listens on the operator-selected UDP port, so no fixed port is exposed.

CMD ["/app/code/start.sh"]
