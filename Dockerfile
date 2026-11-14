FROM netbirdio/netbird-server:0.83.1@sha256:f6acc1a6dcb48d10b867ec7e6916c62ef5c8dc2bb198aec9cc637b2dd26c06c9 AS server
FROM netbirdio/dashboard:v2.97.0@sha256:203b2dc90dc20d3fd45729caac7c922deb399586a68202e0a35be099720bac7d AS dashboard
FROM netbirdio/reverse-proxy:0.83.1@sha256:7c8e11d39dfd88bd9f5a9e281b802b7e5772dc11869f53be81685283800816c5 AS proxy
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

# Copy the multi-architecture combined server image published for NetBird v0.83.1.
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
