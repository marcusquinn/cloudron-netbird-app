FROM netbirdio/dashboard:v2.32.4@sha256:10afad121e564f0288cae8fc966dc50d00a92fb067b6f5af642ffa2a91e27ccb AS dashboard
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# NetBird upstream version
ARG NETBIRD_VERSION=0.65.3

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download NetBird combined server (management + signal + relay + embedded STUN)
RUN mkdir -p /app/code/bin && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird-server_${NETBIRD_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /app/code/bin/ && \
    chmod +x /app/code/bin/netbird-server

# Copy the dashboard release published alongside NetBird v0.65.3.
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
