FROM netbirdio/netbird-server:0.82.1@sha256:7cf0268831221d2d4cc8ca89ca3d8d9419f890f0abb72c1fa9d00aae07e0b788 AS server
FROM netbirdio/dashboard:v2.96.0@sha256:340b13c00b84349572a2acc5605e907cb09250a9e6461c757097eabdb8e02f2c AS dashboard
FROM netbirdio/reverse-proxy:0.82.1@sha256:dc92ce5c361d9f7bffd484d9502077390020c2bb39ca1e27dd1834c80adb7ce0 AS proxy
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

# Copy the multi-architecture combined server image published for NetBird v0.82.1.
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
