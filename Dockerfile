FROM netbirdio/netbird-server:0.83.0@sha256:c353ffadb8a12de0c453ed5d3d074f15e7003b6231346fcfd86f206dd02bd5be AS server
FROM netbirdio/dashboard:v2.97.0@sha256:203b2dc90dc20d3fd45729caac7c922deb399586a68202e0a35be099720bac7d AS dashboard
FROM netbirdio/reverse-proxy:0.83.0@sha256:23b072ab2b7f432c9187a916188ff254b299b24fcce85a11cbbc15c6d464ccf5 AS proxy
FROM cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

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

# Copy the multi-architecture combined server image published for NetBird v0.83.0.
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
