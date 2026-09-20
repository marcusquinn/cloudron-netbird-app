# NetBird Cloudron App - Agent Context

## Project Overview

Cloudron app package for [NetBird](https://netbird.io) -- a self-hosted
WireGuard mesh VPN. It packages the **combined server** binary (`netbird-server`)
with an internal nginx proxy that separates web and native client traffic.

The root manifest and version catalog define exact versions. Start with the
[documentation index](docs/README.md). Human/operator guides belong in `docs/`;
AI-only working instructions belong in `.agents/`. Keep conventional root
entrypoints and update package checks and relative links when moving guides.

Before auth, group or routing changes, read
[Cloudron integration boundaries](docs/CLOUDRON-INTEGRATION.md): custom OIDC
does not inherit app ACLs; username is not immutable identity; owner/setup-key
peers need migration; Cloudron 10.0.5 VPN protection accepts only OpenVPN.
The [access reconciler](docs/ACCESS-SYNC.md) is an opt-in operator tool, not an
automatic app service. Preserve owner peers; do not claim unexecuted revocation
scenarios or native VPN-provider support were verified.

## Architecture

- **Cloudron base image**: `cloudron/base:5.1.0`
- **Combined server**: Single `netbird-server` binary (management + signal + relay + embedded STUN + embedded IdP)
- **Internal nginx**: Port 8080 serves Cloudron-proxied web traffic. Port 33074
  terminates Cloudron-addon TLS for native clients. Both route to port 80.
- **Dashboard**: Static files from `netbirdio/dashboard` served directly by nginx
- **Database**: Cloudron PostgreSQL addon
- **Process management**: supervisord (nginx + netbird-server)

## Critical Design Decisions

### Multiple app instances

Read [multi-instance guidance](docs/MULTI-INSTANCE.md) before adding a brand.
Private meshes share the primary IP with unique native/STUN ports. The current
host proxy helper is single-instance; additional IPs alone do not enable reuse.
Preserve organisation boundaries and require separate multi-instance qualification.

### Config format: `config.yaml` NOT `management.json`

The combined server (v0.65.0+) uses `config.yaml` with a `server:` top-level key. The old `management.json` format is for the legacy multi-container architecture and **does not enable the embedded IdP**. Using the wrong format was the root cause of the auth failure in v1.x.

- Correct: `netbird-server --config /app/data/config/config.yaml`
- Wrong: `netbird-server --management-config management.json`

Reference: https://docs.netbird.io/selfhosted/configuration-files

### Auth flow: Embedded IdP first, external OIDC second

The embedded IdP (Dex) provides first-owner setup and token issuance. Keep recovery
login tested before adding Cloudron OIDC. New installs retain the optional addon;
existing no-SSO installs can use the supported custom-client path in
[SSO switching](docs/SSO-SWITCH.md), without changing Cloudron's install-time flag.
Preserve client/connector IDs across toggles and require new-user approval.
Public ingress protection and its separate host-update lifecycle are documented
in [ingress hardening](docs/INGRESS-HARDENING.md).

Do not auto-register the connector at startup. NetBird v0.79.0 requires an
authenticated owner for `/api/identity-providers`, and startup must not persist
an owner PAT, overwrite an existing connector, or log the client secret.
Embedded and external identities remain distinct even when email matches; never
silently link or promote an external identity.

### STUN port: UDP not TCP

STUN uses UDP. Declare it under `udpPorts`, not `tcpPorts`, and omit a fixed `containerPort`: the combined server uses one value for both its listener and advertised endpoint, so it must listen on Cloudron's selected external port.

### Native client transport: dedicated TLS port

Cloudron's app HTTPS proxy does not preserve native HTTP/2 gRPC to the
container. Declare `NETBIRD_PORT` under `tcpPorts` with fixed container port
33074, require the `tls` addon, and terminate TLS/HTTP2 in nginx. Advertise the
selected external port in `server.exposedAddress`. Keep dashboard/API/OIDC on
normal HTTPS port 443. NetBird reserves container port 33073 for its legacy gRPC
listener, so nginx must not bind there.

### Dashboard runtime config

The exported dashboard embeds environment placeholders in `config.json` and generated assets. Copy the immutable export to `/run/dashboard` and apply the same allowlisted `envsubst` contract as the pinned upstream dashboard init script. Serving unprocessed `/app/code/dashboard` makes the instance-status request fail and incorrectly falls into OIDC login.

## nginx Routing (Critical)

The dedicated TLS listener must match the [upstream routing documentation](https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined).

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
| `supervisord.conf` | Process management (nginx on 8080/33074, netbird-server on 80) |
| `docs/PACKAGING-NOTES.md` | Architecture history, lessons and testing plan |
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

- Cloudron OIDC registration is intentionally owner-managed; safe startup has no
  least-privilege connector bootstrap credential
- Optional single-VPS Reverse Proxy uses a second-IP host bridge, not Cloudron
  HTTPS. See docs/REVERSE-PROXY.md. Trust the dedicated SNAT IP /32, never the shared
  Docker gateway: Cloudron masquerades intra-bridge traffic.
- Cloudron TURN uses an incompatible relay credential model; built-in
  relay/STUN are used
- Live native registration, ACME/TLS, remote peer HTTP traffic, header auth and
  forged-forwarding-header denial are verified. Full VPS reboot and platform
  upgrade qualification still require a maintenance window.
