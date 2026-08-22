FROM netbirdio/netbird-server:0.77.1@sha256:e71f39cefcd90956d818dc4179084fd47d39f0741d1211b818ec640766b5794d AS server
FROM netbirdio/dashboard:v2.91.1@sha256:f3eb26c93ca9901a7385e88e12f6ad98d04e075e8817c664d73557fea123875f AS dashboard
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the multi-architecture combined server image published for NetBird v0.77.1.
RUN mkdir -p /app/code/bin
COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server
RUN chmod +x /app/code/bin/netbird-server

# Copy the dashboard release current when NetBird v0.77.1 was published.
COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/

# Copy supervisord config
COPY supervisord.conf /app/code/supervisord.conf

# Copy start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# Expose HTTP port (Cloudron's reverse proxy handles TLS)
EXPOSE 8080

# Expose STUN UDP port
EXPOSE 3478/udp

CMD ["/app/code/start.sh"]
