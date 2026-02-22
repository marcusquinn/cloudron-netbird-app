FROM cloudron/base:5.0.0

# NetBird upstream version
ARG NETBIRD_VERSION=0.65.3

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download NetBird server (combined management + signal + relay)
RUN mkdir -p /app/code/bin && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird-server_${NETBIRD_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /app/code/bin/ && \
    chmod +x /app/code/bin/netbird-server

# Download NetBird dashboard
RUN ARCH=$(dpkg --print-architecture) && \
    mkdir -p /app/code/dashboard && \
    curl -fsSL "https://github.com/netbirdio/dashboard/releases/latest/download/dashboard.tar.gz" \
    | tar -xz -C /app/code/dashboard/

# Copy configuration templates
COPY config.template.yaml /app/code/defaults/config.yaml
COPY nginx-netbird.conf /app/code/defaults/nginx-netbird.conf
COPY supervisord.conf /app/code/supervisord.conf

# Copy start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8080

CMD ["/app/code/start.sh"]
