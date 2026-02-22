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
mkdir -p /app/data/letsencrypt
mkdir -p /app/data/dashboard
mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi
mkdir -p /run/netbird

# ============================================
# PHASE 3: First-Run Initialization
# ============================================
if [[ "$FIRST_RUN" == "true" ]]; then
    echo "==> Initializing default configuration"
    cp -n /app/code/defaults/config.yaml /app/data/config/config.yaml 2>/dev/null || true
fi

# ============================================
# PHASE 4: Configuration Injection
# ============================================
echo "==> Injecting Cloudron configuration"

# Extract domain from CLOUDRON_APP_ORIGIN
NETBIRD_DOMAIN="${CLOUDRON_APP_DOMAIN}"

# Generate or preserve encryption key
if [[ ! -f /app/data/config/.encryption_key ]]; then
    openssl rand -hex 16 >/app/data/config/.encryption_key
    chmod 600 /app/data/config/.encryption_key
fi
ENCRYPTION_KEY=$(cat /app/data/config/.encryption_key)

# ============================================
# PHASE 4a: STUN/TURN Configuration
# ============================================
# Build STUN entries -- always include the local STUN server
STUN_ENTRIES="[{\"Proto\": \"udp\", \"URI\": \"stun:${NETBIRD_DOMAIN}:${STUN_PORT:-3478}\"}"

# If Cloudron TURN addon is available, add it as an additional STUN source
if [[ -n "${CLOUDRON_TURN_SERVER:-}" ]]; then
    echo "==> Cloudron TURN addon detected: ${CLOUDRON_TURN_SERVER}:${CLOUDRON_TURN_PORT:-3478}"
    STUN_ENTRIES="${STUN_ENTRIES}, {\"Proto\": \"udp\", \"URI\": \"stun:${CLOUDRON_TURN_SERVER}:${CLOUDRON_TURN_PORT:-3478}\"}"
fi
STUN_ENTRIES="${STUN_ENTRIES}]"

# Build TURN config if Cloudron TURN addon is available
TURN_CONFIG="[]"
if [[ -n "${CLOUDRON_TURN_SERVER:-}" ]] && [[ -n "${CLOUDRON_TURN_SECRET:-}" ]]; then
    echo "==> Configuring Cloudron TURN relay"
    TURN_CONFIG="[{\"Proto\": \"udp\", \"URI\": \"turn:${CLOUDRON_TURN_SERVER}:${CLOUDRON_TURN_PORT:-3478}\", \"Username\": \"netbird\", \"Password\": \"${CLOUDRON_TURN_SECRET}\"}]"
fi

# ============================================
# PHASE 4b: Management Server Config
# ============================================
cat >/app/data/config/management.json <<MGMT_EOF
{
  "Stuns": ${STUN_ENTRIES},
  "TURNConfig": {
    "Turns": ${TURN_CONFIG},
    "TimeBasedCredentials": true,
    "CredentialsTTL": "24h",
    "Secret": "${CLOUDRON_TURN_SECRET:-${ENCRYPTION_KEY}}"
  },
  "Relay": {
    "Addresses": ["rel://${NETBIRD_DOMAIN}:443/relay"],
    "CredentialsTTL": "24h",
    "Secret": "${ENCRYPTION_KEY}"
  },
  "Signal": {
    "Proto": "https",
    "URI": "${NETBIRD_DOMAIN}:443",
    "SkipCertVerify": false
  },
  "HttpConfig": {
    "Address": "0.0.0.0:8081",
    "AuthIssuer": "${CLOUDRON_APP_ORIGIN}",
    "AuthAudience": "${NETBIRD_DOMAIN}",
    "CertFile": "",
    "CertKey": "",
    "IdpSignKeyRefreshEnabled": false
  },
  "IdpManagerConfig": {
    "ManagerType": "none"
  },
  "DeviceAuthorizationFlow": {
    "Provider": "none"
  },
  "StoreConfig": {
    "Engine": "postgres",
    "DataDir": "/app/data/netbird/"
  },
  "DataStoreEncryptionKey": "${ENCRYPTION_KEY}"
}
MGMT_EOF

# PostgreSQL DSN for management server
export NETBIRD_STORE_ENGINE_POSTGRES_DSN="postgres://${CLOUDRON_POSTGRESQL_USERNAME}:${CLOUDRON_POSTGRESQL_PASSWORD}@${CLOUDRON_POSTGRESQL_HOST}:${CLOUDRON_POSTGRESQL_PORT}/${CLOUDRON_POSTGRESQL_DATABASE}?sslmode=disable"

# ============================================
# PHASE 4c: Dashboard Configuration
# ============================================
cat >/app/data/dashboard/.env <<DASH_EOF
# NetBird Dashboard Configuration
NETBIRD_MGMT_API_ENDPOINT=${CLOUDRON_APP_ORIGIN}
NETBIRD_MGMT_GRPC_API_ENDPOINT=${CLOUDRON_APP_ORIGIN}
AUTH_SUPPORTED_SCOPES=openid profile email
NETBIRD_TOKEN_SOURCE=idToken
DASH_EOF

# ============================================
# PHASE 4d: nginx Reverse Proxy
# ============================================
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

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 8080;
        server_name _;

        # gRPC services (management + signal)
        location ~ ^/(signalexchange\.SignalExchange|management\.ManagementService)/ {
            grpc_pass grpc://127.0.0.1:8081;
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
        }

        # Relay WebSocket
        location /relay {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
        }

        # Management API, OAuth, and OIDC callbacks
        location ~ ^/(api|oauth2|setup|ws-proxy) {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
        }

        # Dashboard (catch-all)
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
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf &
SUPERVISOR_PID=$!

# ============================================
# PHASE 7: Post-Start OIDC Registration
# ============================================
# Wait for management API to become available, then register Cloudron
# as an OIDC identity provider. This runs after supervisord starts
# because the API must be live to accept the registration.
if [[ -n "${CLOUDRON_OIDC_ISSUER:-}" ]] && [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    echo "==> Cloudron OIDC addon detected, will register as identity provider"

    # Wait for management API (up to 60 seconds)
    RETRIES=0
    MAX_RETRIES=30
    until curl -sf http://127.0.0.1:8081/api/accounts >/dev/null 2>&1; do
        RETRIES=$((RETRIES + 1))
        if [[ $RETRIES -ge $MAX_RETRIES ]]; then
            echo "==> WARNING: Management API not ready after 60s, skipping OIDC registration"
            echo "==> You can add Cloudron as an OIDC provider manually via the dashboard"
            wait $SUPERVISOR_PID
            exit 0
        fi
        sleep 2
    done

    echo "==> Management API is ready"

    # Check if Cloudron OIDC provider is already registered
    # We need a PAT or the first-run setup token. On first run, the embedded
    # IdP handles initial auth. After that, we use a stored PAT.
    if [[ -f /app/data/config/.admin_pat ]]; then
        ADMIN_TOKEN=$(cat /app/data/config/.admin_pat)

        # Check if Cloudron provider already exists
        EXISTING=$(curl -sf "http://127.0.0.1:8081/api/identity-providers" \
            -H "Authorization: Token ${ADMIN_TOKEN}" 2>/dev/null || echo "[]")

        if echo "${EXISTING}" | jq -e '.[] | select(.name == "Cloudron")' >/dev/null 2>&1; then
            echo "==> Cloudron OIDC provider already registered"
        else
            echo "==> Registering Cloudron as OIDC identity provider"
            RESULT=$(curl -sf -X POST "http://127.0.0.1:8081/api/identity-providers" \
                -H "Authorization: Token ${ADMIN_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"type\": \"oidc\",
                    \"name\": \"Cloudron\",
                    \"client_id\": \"${CLOUDRON_OIDC_CLIENT_ID}\",
                    \"client_secret\": \"${CLOUDRON_OIDC_CLIENT_SECRET}\",
                    \"issuer\": \"${CLOUDRON_OIDC_ISSUER}\"
                }" 2>/dev/null || echo "FAILED")

            if [[ "${RESULT}" == "FAILED" ]]; then
                echo "==> WARNING: Failed to register Cloudron OIDC provider automatically"
                echo "==> You can add it manually via Dashboard > Settings > Identity Providers:"
                echo "==>   Type: Generic OIDC"
                echo "==>   Name: Cloudron"
                echo "==>   Issuer: ${CLOUDRON_OIDC_ISSUER}"
                echo "==>   Client ID: ${CLOUDRON_OIDC_CLIENT_ID}"
            else
                echo "==> Cloudron OIDC provider registered successfully"
                echo "==> Users can now log in with their Cloudron credentials"
            fi
        fi
    else
        echo "==> No admin PAT found at /app/data/config/.admin_pat"
        echo "==> To enable automatic Cloudron SSO registration:"
        echo "==>   1. Log into the NetBird dashboard"
        echo "==>   2. Go to Settings > Personal Access Tokens"
        echo "==>   3. Create a token and save it to /app/data/config/.admin_pat"
        echo "==>   4. Restart the app (the token will be used on next start)"
        echo "==> Or add Cloudron as an OIDC provider manually via the dashboard:"
        echo "==>   Settings > Identity Providers > Add Identity Provider"
        echo "==>   Type: Generic OIDC"
        echo "==>   Name: Cloudron"
        echo "==>   Issuer: ${CLOUDRON_OIDC_ISSUER}"
        echo "==>   Client ID: ${CLOUDRON_OIDC_CLIENT_ID}"
    fi
fi

# Wait for supervisord (the main process)
wait $SUPERVISOR_PID
