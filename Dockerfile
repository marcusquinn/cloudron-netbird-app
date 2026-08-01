FROM netbirdio/netbird-server:0.76.1@sha256:71a9d94dd0118d361a70d5705c0144289a31cf3f8f15b0744dade23786da47d2 AS server
FROM netbirdio/dashboard:v2.90.8@sha256:6b3df5d07cbcf8fb81a6a18bb99fadb220e66a554c0e0fe71cd17a93c15769b1 AS dashboard
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the multi-architecture combined server image published for NetBird v0.76.1.
RUN mkdir -p /app/code/bin
COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server
RUN chmod +x /app/code/bin/netbird-server

# Copy the dashboard release current when NetBird v0.76.1 was published.
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
