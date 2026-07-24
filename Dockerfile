FROM netbirdio/netbird-server:0.75.0@sha256:9f8dbb2fee412f91acee1a280c6c06fe8a7bea7b615c37530d6a7bba2edcf901 AS server
FROM netbirdio/dashboard:v2.90.7@sha256:4b9d5eedede5b55737546124162f15ba0c79a32e78ba4c3218549be96ad22fb1 AS dashboard
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the multi-architecture combined server image published for NetBird v0.75.0.
RUN mkdir -p /app/code/bin
COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server
RUN chmod +x /app/code/bin/netbird-server

# Copy the dashboard release current when NetBird v0.75.0 was published.
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
