# NetBird Cloudron App - Agent Context

## Project Overview

Cloudron app package for [NetBird](https://netbird.io) v0.65.3+ -- a self-hosted WireGuard mesh VPN. Packages the **combined server** binary (`netbird-server`) with an internal nginx proxy that separates Cloudron web traffic from native HTTP/2 client traffic.

## Architecture

- **Cloudron base image**: `cloudron/base:5.1.0`
- **Combined server**: Single `netbird-server` binary (management + signal + relay + embedded STUN + embedded IdP)
- **Internal nginx**: Port 8080 serves Cloudron-proxied web traffic; port 33073 terminates Cloudron-addon TLS for native clients; both route to netbird-server on port 80
- **Dashboard**: Static files from `netbirdio/dashboard` served directly by nginx
- **Database**: Cloudron PostgreSQL addon
- **Process management**: supervisord (nginx + netbird-server)

## Critical Design Decisions

### Config format: `config.yaml` NOT `management.json`

The combined server (v0.65.0+) uses `config.yaml` with a `server:` top-level key. The old `management.json` format is for the legacy multi-container architecture and **does not enable the embedded IdP**. Using the wrong format was the root cause of the auth failure in v1.x.

- Correct: `netbird-server --config /app/data/config/config.yaml`
- Wrong: `netbird-server --management-config management.json`

Reference: https://docs.netbird.io/selfhosted/configuration-files

### Auth flow: Embedded IdP first, external OIDC second

The embedded IdP (Dex) provides the `/setup` page for first-run admin account creation and the `/oauth2/*` endpoints for token issuance. Cloudron OIDC is added **after** initial setup via the dashboard UI. This avoids the Catch-22 where you need to log in to configure the IdP you need to log in with.

### STUN port: UDP not TCP

STUN uses UDP. Declare it under `udpPorts`, not `tcpPorts`, and omit a fixed `containerPort`: the combined server uses one value for both its listener and advertised endpoint, so it must listen on Cloudron's selected external port.

### Native client transport: dedicated TLS port

Cloudron's app HTTPS proxy does not preserve native HTTP/2 gRPC to the container. Declare `NETBIRD_PORT` under `tcpPorts` with fixed container port 33073, require the `tls` addon, terminate TLS/HTTP2 in nginx, and advertise Cloudron's selected external port in `server.exposedAddress`. Keep dashboard/API/OIDC on normal HTTPS port 443.

### Dashboard runtime config

The exported dashboard embeds environment placeholders in `config.json` and generated assets. Copy the immutable export to `/run/dashboard` and apply the same allowlisted `envsubst` contract as the pinned upstream dashboard init script. Serving unprocessed `/app/code/dashboard` makes the instance-status request fail and incorrectly falls into OIDC login.

## nginx Routing (Critical)

The dedicated TLS listener must match upstream routing docs: https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined

| Path | Directive | Why |
|------|-----------|-----|
| `/signalexchange.SignalExchange/*` | `grpc_pass` | gRPC requires HTTP/2 cleartext (h2c) |
| `/management.ManagementService/*` | `grpc_pass` | Same |
| `/relay*`, `/ws-proxy/*` | `proxy_pass` + Upgrade | WebSocket long-lived connections |
| `/api/*`, `/oauth2/*` | `proxy_pass` | REST API + embedded IdP |
| `/*` | `try_files` | Dashboard SPA (includes `/setup` route) |

Timeouts must be `1d` for gRPC and WebSocket. `grpc_socket_keepalive on` is required.

## File Map

| File | Purpose |
|------|---------|
| `CloudronManifest.json` | Cloudron app metadata, addons (PostgreSQL, local storage, TLS), TCP/UDP ports |
| `Dockerfile` | Downloads netbird-server binary + dashboard static files |
| `start.sh` | Server/nginx config plus ephemeral dashboard runtime substitution |
| `supervisord.conf` | Process management (nginx on 8080/33073, netbird-server on 80) |
| `PACKAGING-NOTES.md` | Detailed architecture notes, lessons learned, testing plan |
| `CHANGELOG.md` | Version history with breaking changes documented |

## Secrets (generated at runtime, persisted in `/app/data/config/`)

| File | Purpose |
|------|---------|
| `.encryption_key` | 16-byte hex, encrypts setup keys and API tokens at rest in PostgreSQL |
| `.auth_secret` | 32-byte hex, relay credential validation |

Both are generated on first run and must survive across restarts/updates.

## Testing

Build and test with:
```bash
cloudron build && cloudron install --location netbird
cloudron logs -f --app netbird
```

Key verification points:
1. `/setup` page loads on first run (no users exist)
2. Admin account creation works
3. Dashboard login works with created credentials
4. Setup key creation and client connection work
5. gRPC (signal/management) and WebSocket (relay/ws-proxy) connections work

See README.md Testing Checklist for the full list.

## Upstream References

- Combined server config: https://docs.netbird.io/selfhosted/configuration-files
- nginx routing: https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined
- Embedded IdP: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- Cloudron packaging: https://docs.cloudron.io/packaging/manifest/
- Cloudron addons: https://docs.cloudron.io/packaging/addons/
- Gitea app (reference Cloudron package): https://git.cloudron.io/packages/gitea-app

## Known Issues / Future Work

- Cloudron OIDC auto-registration not implemented (manual dashboard setup required)
- NetBird reverse proxy feature incompatible (needs TLS passthrough, Cloudron doesn't support it)
- Cloudron TURN addon is incompatible with NetBird's relay credential model; built-in relay/STUN are used
- Not yet tested on a real Cloudron instance -- needs validation
