# NetBird Cloudron App - Agent Context

## Project Overview

Cloudron app package for [NetBird](https://netbird.io) v0.65.3+ -- a self-hosted WireGuard mesh VPN. Packages the **combined server** binary (`netbird-server`) with an internal nginx reverse proxy, served on Cloudron's single HTTP port.

## Architecture

- **Cloudron base image**: `cloudron/base:5.0.0`
- **Combined server**: Single `netbird-server` binary (management + signal + relay + embedded STUN + embedded IdP)
- **Internal nginx**: Port 8080 (Cloudron's `httpPort`) routes to netbird-server on port 80
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

STUN uses UDP. The manifest declares it under `udpPorts`, not `tcpPorts`. This was a bug in v1.x.

### Dashboard config: `OIDCConfigResponse`

The upstream `netbirdio/dashboard` container has its own nginx that generates runtime config from env vars. Since we serve the dashboard static files directly, `start.sh` writes an `OIDCConfigResponse` JSON file to `/app/code/dashboard/` that the dashboard JS reads at load time.

## nginx Routing (Critical)

Must match upstream docs: https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined

| Path | Directive | Why |
|------|-----------|-----|
| `/signalexchange.SignalExchange/*` | `grpc_pass` | gRPC requires HTTP/2 cleartext (h2c) |
| `/management.ManagementService/*` | `grpc_pass` | Same |
| `/relay*`, `/ws-proxy/*` | `proxy_pass` + Upgrade | WebSocket long-lived connections |
| `/api/*`, `/oauth2/*` | `proxy_pass` | REST API + embedded IdP |
| `/OIDCConfigResponse` | static file | Dashboard auth config |
| `/*` | `try_files` | Dashboard SPA (includes `/setup` route) |

Timeouts must be `1d` for gRPC and WebSocket. `grpc_socket_keepalive on` is required.

## File Map

| File | Purpose |
|------|---------|
| `CloudronManifest.json` | Cloudron app metadata, addons (postgresql, localstorage), udpPorts |
| `Dockerfile` | Downloads netbird-server binary + dashboard static files |
| `start.sh` | Runtime config generation (config.yaml, nginx.conf, OIDCConfigResponse) |
| `supervisord.conf` | Process management (nginx on 8080, netbird-server on 80) |
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
- Cloudron TURN addon not integrated (NetBird's built-in relay is used instead)
- Not yet tested on a real Cloudron instance -- needs validation
