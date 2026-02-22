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

# Extract domain from CLOUDRON_APP_ORIGIN (strip https://)
NETBIRD_DOMAIN="${CLOUDRON_APP_DOMAIN}"

# Generate or preserve encryption key
if [[ ! -f /app/data/config/.encryption_key ]]; then
	openssl rand -hex 16 >/app/data/config/.encryption_key
	chmod 600 /app/data/config/.encryption_key
fi
ENCRYPTION_KEY=$(cat /app/data/config/.encryption_key)

# Build the management server config
cat >/app/data/config/management.json <<MGMT_EOF
{
  "Stuns": [
    {
      "Proto": "udp",
      "URI": "stun:${NETBIRD_DOMAIN}:${STUN_PORT:-3478}"
    }
  ],
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

# Dashboard environment
cat >/app/data/dashboard/.env <<DASH_EOF
# NetBird Dashboard Configuration
NETBIRD_MGMT_API_ENDPOINT=${CLOUDRON_APP_ORIGIN}
NETBIRD_MGMT_GRPC_API_ENDPOINT=${CLOUDRON_APP_ORIGIN}
AUTH_SUPPORTED_SCOPES=openid profile email
NETBIRD_TOKEN_SOURCE=idToken
DASH_EOF

# nginx config for reverse proxy
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

        # Management API and OAuth
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
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf
