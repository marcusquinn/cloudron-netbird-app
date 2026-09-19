#!/bin/bash
set -eu

echo "==> Starting NetBird for Cloudron"

# ============================================
# PHASE 0: Validate Required Environment Variables
# ============================================
# Cloudron injects these via addons (postgresql) and platform env.
# If addon injection fails, the app would start with broken/empty config
# silently. Fail fast with a clear error instead.

validate_env() {
    local required_vars=(
        "CLOUDRON_APP_DOMAIN"
        "CLOUDRON_POSTGRESQL_HOST"
        "CLOUDRON_POSTGRESQL_USERNAME"
        "CLOUDRON_POSTGRESQL_PASSWORD"
        "CLOUDRON_POSTGRESQL_DATABASE"
        "CLOUDRON_POSTGRESQL_PORT"
        "NETBIRD_PORT"
    )
    local errors=()
    local cert_file
    local var

    # Collect all missing required variables
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("Required environment variable '${var}' is not set.")
        fi
    done

    # Validate CLOUDRON_POSTGRESQL_PORT if it is present (PR #23 review:
    # consolidate missing + invalid errors into a single report so the user
    # can fix all configuration issues in one step)
    if [[ -n "${CLOUDRON_POSTGRESQL_PORT:-}" ]]; then
        if ! [[ "${CLOUDRON_POSTGRESQL_PORT}" =~ ^[0-9]+$ ]] ||
            ((CLOUDRON_POSTGRESQL_PORT < 1 || CLOUDRON_POSTGRESQL_PORT > 65535)); then
            errors+=("CLOUDRON_POSTGRESQL_PORT must be an integer between 1 and 65535 (got: '${CLOUDRON_POSTGRESQL_PORT}').")
        fi
    fi

    if [[ -n "${NETBIRD_PORT:-}" ]]; then
        if ! [[ "${NETBIRD_PORT}" =~ ^[0-9]+$ ]] ||
            ((NETBIRD_PORT < 1 || NETBIRD_PORT > 65535)); then
            errors+=("NETBIRD_PORT must be an integer between 1 and 65535 (got: '${NETBIRD_PORT}').")
        fi
    fi

    for cert_file in /etc/certs/tls_cert.pem /etc/certs/tls_key.pem; do
        if [[ ! -s "${cert_file}" ]]; then
            errors+=("Required TLS addon file '${cert_file}' is missing or empty.")
        fi
    done

    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "ERROR: Environment validation failed with ${#errors[@]} error(s):" >&2
        printf " - %s\n" "${errors[@]}" >&2
        return 1
    fi

    echo "==> Environment validated (${#required_vars[@]} required variables present)"
    return 0
}

validate_env || exit 1

# ============================================
# PHASE 1: First-Run Detection
# ============================================
if [[ ! -f /app/data/.initialized ]]; then
    echo "==> First run detected — will initialize config and secrets"
else
    echo "==> Existing installation detected"
fi

# ============================================
# PHASE 2: Directory Structure
# ============================================
mkdir -p /app/data/config
mkdir -p /app/data/netbird
mkdir -p /run/dashboard
cp -a /app/code/dashboard/. /run/dashboard/
mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/scgi /run/nginx/uwsgi
mkdir -p /run/netbird

# ============================================
# PHASE 3: Generate or Preserve Secrets
# ============================================

# Generate a hex secret file if it doesn't already exist and is non-empty.
# Uses -s (exists AND non-empty) instead of -f (exists only) to handle the
# case where a previous failed run left an empty file (PR #18 review).
# On openssl failure, removes any partial/empty file to prevent the app
# from starting with a blank secret on the next attempt (PR #12 review).
generate_secret() {
    local file_path="$1"
    local key_length="$2"
    local key_name="$3"

    if [[ -s "${file_path}" ]]; then
        return 0
    fi

    if ! openssl rand -hex "${key_length}" >"${file_path}"; then
        echo "ERROR: Failed to generate ${key_name}" >&2
        rm -f "${file_path}"
        exit 1
    fi
    chmod 600 "${file_path}"
    return 0
}

generate_encryption_key() {
    local file_path="$1"

    if [[ -s "${file_path}" ]]; then
        return 0
    fi

    if ! openssl rand -base64 32 >"${file_path}"; then
        echo "ERROR: Failed to generate encryption key" >&2
        rm -f "${file_path}"
        return 1
    fi
    chmod 600 "${file_path}"
    return 0
}

generate_encryption_key "/app/data/config/.encryption_key" || exit 1
ENCRYPTION_KEY=$(cat /app/data/config/.encryption_key)

generate_secret "/app/data/config/.auth_secret" 32 "auth secret"
AUTH_SECRET=$(cat /app/data/config/.auth_secret)

# ============================================
# PHASE 4: Configuration Generation
# ============================================
echo "==> Generating NetBird configuration"

# envsubst reads the process environment, not unexported shell variables.
export NETBIRD_DOMAIN="${CLOUDRON_APP_DOMAIN}"
NETBIRD_NATIVE_PORT="${NETBIRD_PORT}"

# ============================================
# PHASE 4a: config.yaml (Combined Server)
# ============================================
# The combined netbird-server uses config.yaml (not management.json).
# This enables the embedded IdP (Dex) which provides /oauth2/* endpoints
# and the /setup page for first-run onboarding.

# Build store DSN for PostgreSQL
# Use sslmode=prefer (opportunistic TLS): encrypts the connection if the server
# supports it, falls back to unencrypted if not. Cloudron's PostgreSQL addon docs
# don't document SSL support or export a CA certificate path, so verify-full would
# break if no cert is available. prefer is the safe upgrade from disable — it will
# use encryption when possible without requiring a trusted CA cert on the client.
# See: https://docs.cloudron.io/packaging/addons/#postgresql
# shellcheck disable=SC2153 # CLOUDRON_POSTGRESQL_HOST is injected and validated above.
PG_DSN="host=${CLOUDRON_POSTGRESQL_HOST} user=${CLOUDRON_POSTGRESQL_USERNAME} password=${CLOUDRON_POSTGRESQL_PASSWORD} dbname=${CLOUDRON_POSTGRESQL_DATABASE} port=${CLOUDRON_POSTGRESQL_PORT} sslmode=prefer"

cat >/app/data/config/config.yaml <<CONFIG_EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://${NETBIRD_DOMAIN}:${NETBIRD_NATIVE_PORT}"
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
export NETBIRD_STORE_ENGINE_POSTGRES_DSN="postgres://${CLOUDRON_POSTGRESQL_USERNAME}:${CLOUDRON_POSTGRESQL_PASSWORD}@${CLOUDRON_POSTGRESQL_HOST}:${CLOUDRON_POSTGRESQL_PORT}/${CLOUDRON_POSTGRESQL_DATABASE}?sslmode=prefer"

# ============================================
# PHASE 4b: Dashboard Runtime Configuration
# ============================================
# The exported dashboard embeds placeholders in config.json and generated
# assets. Mirror the pinned upstream dashboard init script: replace only the
# supported runtime variables in an ephemeral copy, leaving /app/code readonly.

export USE_AUTH0="false"
export AUTH_AUDIENCE="netbird-dashboard"
export AUTH_AUTHORITY="https://${NETBIRD_DOMAIN}/oauth2"
export AUTH_CLIENT_ID="netbird-dashboard"
export AUTH_CLIENT_SECRET=""
export AUTH_SUPPORTED_SCOPES="openid profile email groups"
export NETBIRD_MGMT_API_ENDPOINT="https://${NETBIRD_DOMAIN}"
export NETBIRD_MGMT_GRPC_API_ENDPOINT="https://${NETBIRD_DOMAIN}:${NETBIRD_NATIVE_PORT}"
export AUTH_REDIRECT_URI="/nb-auth"
export AUTH_SILENT_REDIRECT_URI="/nb-silent-auth"
export NETBIRD_TOKEN_SOURCE="accessToken"
export NETBIRD_DRAG_QUERY_PARAMS="false"
export NETBIRD_AUTH_SERVICE_URL=""
export NETBIRD_WASM_PATH=""
export NETBIRD_LICENSED="false"
export NETBIRD_CLOUD="false"
export NETBIRD_AGENT_NETWORK_ONLY="false"
export NETBIRD_AGENT_NETWORK_ENABLED="false"

# Keep these placeholders literal for the envsubst allowlist.
# shellcheck disable=SC2016
DASHBOARD_ENV_VARS='${USE_AUTH0} ${AUTH_AUDIENCE} ${AUTH_AUTHORITY} ${AUTH_CLIENT_ID} ${AUTH_CLIENT_SECRET} ${AUTH_SUPPORTED_SCOPES} ${NETBIRD_MGMT_API_ENDPOINT} ${NETBIRD_MGMT_GRPC_API_ENDPOINT} ${AUTH_REDIRECT_URI} ${AUTH_SILENT_REDIRECT_URI} ${NETBIRD_TOKEN_SOURCE} ${NETBIRD_DRAG_QUERY_PARAMS} ${NETBIRD_AUTH_SERVICE_URL} ${NETBIRD_WASM_PATH} ${NETBIRD_LICENSED} ${NETBIRD_CLOUD} ${NETBIRD_AGENT_NETWORK_ONLY} ${NETBIRD_AGENT_NETWORK_ENABLED}'
dashboard_files=()
while IFS= read -r -d '' dashboard_file; do
    dashboard_files+=("${dashboard_file}")
done < <(grep -RIlZ -- "AUTH_SUPPORTED_SCOPES" /run/dashboard)
if [[ ${#dashboard_files[@]} -eq 0 ]]; then
    echo "ERROR: Dashboard runtime configuration placeholders were not found" >&2
    exit 1
fi
for dashboard_file in "${dashboard_files[@]}"; do
    envsubst "${DASHBOARD_ENV_VARS}" <"${dashboard_file}" >"${dashboard_file}.tmp"
    mv "${dashboard_file}.tmp" "${dashboard_file}"
done

# PHASE 4d: nginx Configuration
# ============================================
# This nginx exposes two frontends for the server listening on port 80:
# - port 8080 receives dashboard/API HTTP from Cloudron's HTTPS proxy
# - port 33074 terminates TLS directly for native HTTP/2 gRPC and relay traffic
# The fixed container port must match tcpPorts.NETBIRD_PORT.containerPort.
#
# Key routing from upstream docs:
# - gRPC paths need grpc_pass (nginx handles h2c natively with grpc_pass)
# - WebSocket paths need proxy_pass with Upgrade headers
# - /api and /oauth2 are standard HTTP
# - Dashboard is the catch-all on the web listener. Browser navigation to the
#   native listener is redirected to the configured canonical HTTPS origin.

# Optional unattended-install protection: initialize via an app terminal before
# any internet caller can claim the first administrator account.
: >/run/nginx/setup-guard.conf
if [[ "${NETBIRD_SETUP_LOCAL_ONLY:-false}" == true ]]; then
    cat >/run/nginx/setup-guard.conf <<'SETUP_GUARD'
location ~ ^/api/setup(/|$) {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://netbird_server;
}
SETUP_GUARD
fi

cat >/app/data/config/nginx.conf.template <<'NGINX_EOF'
worker_processes auto;
pid /run/nginx/nginx.pid;
error_log /run/nginx/error.log;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /run/nginx/access.log;

    client_body_temp_path /run/nginx/client_body;
    proxy_temp_path /run/nginx/proxy;
    fastcgi_temp_path /run/nginx/fastcgi;
    scgi_temp_path /run/nginx/scgi;
    uwsgi_temp_path /run/nginx/uwsgi;

    # Required for long-lived gRPC and WebSocket connections
    client_header_timeout 1d;
    client_body_timeout 1d;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    # The direct-TLS listener is only for native transport. Redirect browser
    # navigation without trusting the incoming Host header or affecting native
    # gRPC, relay, WebSocket, API, or OAuth locations declared below.
    map "$server_port:$request_method" $native_dashboard_redirect {
        default "";
        ~^33074:(GET|HEAD)$ "https://${NETBIRD_DOMAIN}";
    }

    upstream netbird_server {
        server 127.0.0.1:80;
    }

    server {
        listen 8080;
        listen 33074 ssl http2;
        server_name _;

        ssl_certificate /etc/certs/tls_cert.pem;
        ssl_certificate_key /etc/certs/tls_key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;

        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "0" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "interest-cohort=()" always;

        # Common proxy headers
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;

        # ---- gRPC: Signal + Management ----
        # These need grpc_pass which handles h2c (HTTP/2 cleartext) natively
        location ~ ^/(signalexchange\.SignalExchange|management\.(ManagementService|ProxyService))/ {
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

        include /run/nginx/setup-guard.conf;

        # ---- HTTP: API + OAuth2 (embedded IdP) ----
        location ~ ^/(api|oauth2)/ {
            proxy_pass http://netbird_server;
            proxy_set_header Host $host;
        }

        # ---- Dashboard (catch-all, lowest priority) ----
        location / {
            if ($native_dashboard_redirect != "") {
                return 308 $native_dashboard_redirect$request_uri;
            }
            root /run/dashboard;
            # Next.js exports page.html beside page/ metadata directories.
            rewrite ^(.+)/$ $1 last;
            try_files $uri.html $uri $uri/ /index.html;
        }
    }
}
NGINX_EOF
# shellcheck disable=SC2016 # Expand only this trusted configuration placeholder.
envsubst '${NETBIRD_DOMAIN}' </app/data/config/nginx.conf.template >/app/data/config/nginx.conf
rm /app/data/config/nginx.conf.template

# ============================================
# PHASE 5: Permissions
# ============================================
chown -R cloudron:cloudron /app/data /run/dashboard /run/nginx /run/netbird

# Mark initialized
touch /app/data/.initialized

# ============================================
# PHASE 6: Process Launch (supervisord)
# ============================================
echo "==> Launching NetBird services"
# Supervisor needs root to open container log pipes and write its /run PID file.
# Both managed services drop to cloudron via their supervisord.conf user settings.
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf --nodaemon
