#!/bin/bash
set -eu

echo "==> Starting NetBird for Cloudron"

# ============================================
# PHASE 1: First-Run Detection
# ============================================
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
    echo "==> First run detected"
else
    FIRST_RUN=false
fi

# ============================================
# PHASE 2: Directory Structure
# ============================================
mkdir -p /app/data/config
mkdir -p /app/data/netbird
mkdir -p /app/data/dashboard
mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi
mkdir -p /run/netbird

# ============================================
# PHASE 3: Generate or Preserve Secrets
# ============================================

# Encryption key for database-at-rest encryption
if [[ ! -f /app/data/config/.encryption_key ]]; then
    openssl rand -hex 16 >/app/data/config/.encryption_key
    chmod 600 /app/data/config/.encryption_key
fi
ENCRYPTION_KEY=$(cat /app/data/config/.encryption_key)

# Auth secret for relay credential validation
if [[ ! -f /app/data/config/.auth_secret ]]; then
    openssl rand -hex 32 >/app/data/config/.auth_secret
    chmod 600 /app/data/config/.auth_secret
fi
AUTH_SECRET=$(cat /app/data/config/.auth_secret)

# ============================================
# PHASE 4: Configuration Generation
# ============================================
echo "==> Generating NetBird configuration"

NETBIRD_DOMAIN="${CLOUDRON_APP_DOMAIN}"

# ============================================
# PHASE 4a: config.yaml (Combined Server)
# ============================================
# The combined netbird-server uses config.yaml (not management.json).
# This enables the embedded IdP (Dex) which provides /oauth2/* endpoints
# and the /setup page for first-run onboarding.

# Build store DSN for PostgreSQL
PG_DSN="host=${CLOUDRON_POSTGRESQL_HOST} user=${CLOUDRON_POSTGRESQL_USERNAME} password=${CLOUDRON_POSTGRESQL_PASSWORD} dbname=${CLOUDRON_POSTGRESQL_DATABASE} port=${CLOUDRON_POSTGRESQL_PORT} sslmode=disable"

cat >/app/data/config/config.yaml <<CONFIG_EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://${NETBIRD_DOMAIN}:443"
  stunPorts:
    - ${STUN_PORT:-3478}
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"

  authSecret: "${AUTH_SECRET}"
  dataDir: "/app/data/netbird"

  auth:
    issuer: "https://${NETBIRD_DOMAIN}/oauth2"
    signKeyRefreshEnabled: true
    dashboardRedirectURIs:
      - "https://${NETBIRD_DOMAIN}/nb-auth"
      - "https://${NETBIRD_DOMAIN}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  store:
    engine: "postgres"
    dsn: "${PG_DSN}"
    encryptionKey: "${ENCRYPTION_KEY}"
CONFIG_EOF

# Also export DSN as env var (the server checks both config.yaml and env)
export NETBIRD_STORE_ENGINE_POSTGRES_DSN="postgres://${CLOUDRON_POSTGRESQL_USERNAME}:${CLOUDRON_POSTGRESQL_PASSWORD}@${CLOUDRON_POSTGRESQL_HOST}:${CLOUDRON_POSTGRESQL_PORT}/${CLOUDRON_POSTGRESQL_DATABASE}?sslmode=disable"

# ============================================
# PHASE 4b: Dashboard Environment
# ============================================
# The dashboard container (netbirdio/dashboard) reads these from dashboard.env.
# We serve the dashboard static files via our nginx, but the JS app reads
# these values from /api and window.__RUNTIME_CONFIG__ at load time.
# The dashboard's own nginx injects these -- since we serve the static files
# directly, we write a runtime config JS file instead.

cat >/app/data/dashboard/config.json <<DASH_EOF
{
  "NETBIRD_MGMT_API_ENDPOINT": "https://${NETBIRD_DOMAIN}",
  "NETBIRD_MGMT_GRPC_API_ENDPOINT": "https://${NETBIRD_DOMAIN}",
  "AUTH_AUDIENCE": "netbird-dashboard",
  "AUTH_CLIENT_ID": "netbird-dashboard",
  "AUTH_CLIENT_SECRET": "",
  "AUTH_AUTHORITY": "https://${NETBIRD_DOMAIN}/oauth2",
  "USE_AUTH0": "false",
  "AUTH_SUPPORTED_SCOPES": "openid profile email groups",
  "AUTH_REDIRECT_URI": "/nb-auth",
  "AUTH_SILENT_REDIRECT_URI": "/nb-silent-auth"
}
DASH_EOF

# Also write the OIDCConfigResponse that the dashboard fetches
# The dashboard JS fetches this from the management API, but we also
# need to ensure the static dashboard files have the right config.
# Write a .env file that the dashboard's entrypoint would use:
cat >/app/data/dashboard/.env <<DASHENV_EOF
NETBIRD_MGMT_API_ENDPOINT=https://${NETBIRD_DOMAIN}
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://${NETBIRD_DOMAIN}
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=https://${NETBIRD_DOMAIN}/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NGINX_SSL_PORT=443
LETSENCRYPT_DOMAIN=none
DASHENV_EOF

# ============================================
# PHASE 4c: Inject Dashboard Runtime Config
# ============================================
# The upstream netbirdio/dashboard container has its own nginx that
# generates a runtime config. Since we serve the dashboard static files
# directly, we need to generate the config that the dashboard JS expects.
# The dashboard looks for /OIDCConfigResponse at load time.

# Generate the transfer config file that the dashboard reads
# This is what the dashboard's nginx would normally generate from env vars
DASHBOARD_DIR="/app/code/dashboard"
if [[ -d "${DASHBOARD_DIR}" ]]; then
    # Write the auth config that the dashboard JS reads
    cat >"${DASHBOARD_DIR}/OIDCConfigResponse" <<OIDC_EOF
{
  "audience": "netbird-dashboard",
  "authority": "https://${NETBIRD_DOMAIN}/oauth2",
  "clientId": "netbird-dashboard",
  "clientSecret": "",
  "apiOrigin": "https://${NETBIRD_DOMAIN}",
  "grpcApiOrigin": "https://${NETBIRD_DOMAIN}",
  "redirectURI": "/nb-auth",
  "silentRedirectURI": "/nb-silent-auth",
  "scopes": "openid profile email groups",
  "useAuth0": false
}
OIDC_EOF
fi

# ============================================
# PHASE 4d: nginx Configuration
# ============================================
# This nginx sits between Cloudron's reverse proxy (which terminates TLS)
# and the netbird-server (which listens on port 80 internally).
# Cloudron sends HTTP to our port 8080, we route to the right backend.
#
# Key routing from upstream docs:
# - gRPC paths need grpc_pass (nginx handles h2c natively with grpc_pass)
# - WebSocket paths need proxy_pass with Upgrade headers
# - /api and /oauth2 are standard HTTP
# - Dashboard is the catch-all

cat >/app/data/config/nginx.conf <<'NGINX_EOF'
worker_processes auto;
pid /run/nginx/nginx.pid;
error_log /dev/stderr;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;

    client_body_temp_path /run/nginx/client_body;
    proxy_temp_path /run/nginx/proxy;
    fastcgi_temp_path /run/nginx/fastcgi;

    # Required for long-lived gRPC and WebSocket connections
    client_header_timeout 1d;
    client_body_timeout 1d;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    upstream netbird_server {
        server 127.0.0.1:80;
    }

    server {
        listen 8080 http2;
        server_name _;

        # Common proxy headers
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;

        # ---- gRPC: Signal + Management ----
        # These need grpc_pass which handles h2c (HTTP/2 cleartext) natively
        location ~ ^/(signalexchange\.SignalExchange|management\.ManagementService)/ {
            grpc_pass grpc://netbird_server;
            grpc_read_timeout 1d;
            grpc_send_timeout 1d;
            grpc_socket_keepalive on;
            grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        # ---- WebSocket: Relay + Signal WS + Management WS ----
        location ~ ^/(relay|ws-proxy/) {
            proxy_pass http://netbird_server;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 1d;
        }

        # ---- HTTP: API + OAuth2 (embedded IdP) ----
        location ~ ^/(api|oauth2)/ {
            proxy_pass http://netbird_server;
            proxy_set_header Host $host;
        }

        # ---- Dashboard OIDC config endpoint ----
        location = /OIDCConfigResponse {
            root /app/code/dashboard;
            default_type application/json;
            try_files /OIDCConfigResponse =404;
        }

        # ---- Dashboard (catch-all, lowest priority) ----
        location / {
            root /app/code/dashboard;
            try_files $uri $uri/ /index.html;
        }
    }
}
NGINX_EOF

# ============================================
# PHASE 5: Permissions
# ============================================
chown -R cloudron:cloudron /app/data /run/nginx /run/netbird

# Mark initialized
touch /app/data/.initialized

# ============================================
# PHASE 6: Process Launch (supervisord)
# ============================================
echo "==> Launching NetBird services"
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf --nodaemon
