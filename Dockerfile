FROM netbirdio/netbird-server:0.81.2@sha256:7caa37d30b20e54196e1076d4009fcdc4c9d83d174d8b9a8be52fb29c00708df AS server
FROM netbirdio/dashboard:v2.94.0@sha256:70e0fc6dd3b7758148d182fb55ecd8d4f9ce01e9bba56c9389224e0b8354009d AS dashboard
FROM netbirdio/reverse-proxy:0.81.2@sha256:606f7af5e0dfe41b2f532dd7e3f6ec067e51b3954e8e6807e41271a71079bdd4 AS proxy
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

# Copy the multi-architecture combined server image published for NetBird v0.81.2.
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
