# NetBird Cloudron App - Packaging Notes

## Feasibility Assessment

**Overall: Medium complexity, achievable.**

### Architecture (v2.0.0)

This package uses the **combined server** architecture (`netbird-server` binary, `config.yaml` format) introduced in NetBird v0.65.0. This is the recommended approach for new deployments per the [upstream docs](https://docs.netbird.io/selfhosted/configuration-files).

Key design decisions:

1. **Embedded IdP (Dex)** handles initial authentication. The `/setup` page creates the first admin account. No external IdP is required for first-run.
2. **Cloudron OIDC is optional** and added post-setup via the dashboard UI. This avoids the Catch-22 where you need to log in to configure the IdP you need to log in with.
3. **config.yaml** (not `management.json`) is used for server configuration. The old `management.json` format is for the legacy multi-container architecture and does not enable the embedded IdP.
4. **Dashboard static files** are served directly by our nginx. The upstream `netbirdio/dashboard` container has its own nginx that generates runtime config from env vars -- we replicate this by writing `OIDCConfigResponse` directly.

### What works well with Cloudron

1. **PostgreSQL addon** -- NetBird supports PostgreSQL natively, Cloudron provides it as an addon
2. **HTTP reverse proxy** -- Dashboard, Management API, Signal gRPC, and Relay WebSocket all work over HTTP/HTTPS on port 443
3. **Single domain** -- All services multiplex on one domain via path-based routing
4. **Docker-based** -- NetBird provides pre-built binaries and Docker images
5. **Supervisord** -- Multi-process pattern (nginx + netbird-server) is well-supported by Cloudron

### Cloudron addon integration

| Addon | Purpose | Integration method |
|-------|---------|-------------------|
| `postgresql` | Database | `CLOUDRON_POSTGRESQL_*` env vars -> `server.store.dsn` in config.yaml |
| `localstorage` | Persistent data | `/app/data/` for config, encryption key, auth secret |

### Addons NOT used (and why)

| Addon | Why not |
|-------|---------|
| `oidc` | NetBird's embedded IdP handles initial auth. Cloudron OIDC can be added post-setup via the dashboard, but the manifest doesn't require it. Set `optionalSso: true` so users can choose. |
| `turn` | NetBird's built-in relay handles NAT traversal. The combined server includes relay functionality. Cloudron's TURN addon uses a different auth model (shared secret) that doesn't map cleanly to NetBird's relay config. |

### nginx routing (critical)

The internal nginx routes traffic from Cloudron's reverse proxy (port 8080) to the combined server (port 80). The routing must match the [upstream nginx configuration](https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined):

| Path | Protocol | nginx directive | Notes |
|------|----------|----------------|-------|
| `/signalexchange.SignalExchange/*` | gRPC | `grpc_pass` | HTTP/2 cleartext (h2c) |
| `/management.ManagementService/*` | gRPC | `grpc_pass` | HTTP/2 cleartext (h2c) |
| `/relay*`, `/ws-proxy/*` | WebSocket | `proxy_pass` + Upgrade | Long-lived connections |
| `/api/*`, `/oauth2/*` | HTTP | `proxy_pass` | REST API + embedded IdP |
| `/setup` | HTTP | `proxy_pass` | First-run onboarding |
| `/*` | HTTP | static files | Dashboard catch-all |

**Key gotchas**:
- gRPC paths MUST use `grpc_pass`, not `proxy_pass`. nginx handles h2c natively with `grpc_pass`.
- WebSocket paths need `proxy_http_version 1.1` and `Upgrade`/`Connection` headers.
- Timeouts must be `1d` for long-lived gRPC and WebSocket connections.
- The combined server listens on port 80 internally (not 8081 as in the old architecture).

### Challenges and solutions

| Challenge | Solution | Risk |
|-----------|----------|------|
| **UDP 3478 (STUN)** | Use `udpPorts` in manifest (NOT `tcpPorts` -- STUN is UDP) | Low -- Cloudron handles port mapping |
| **gRPC over HTTP/2** | nginx `grpc_pass` directive with `grpc_socket_keepalive on` | Low -- well-tested pattern |
| **Combined server binary** | NetBird v0.65+ ships a single `netbird-server` binary | Low -- simplifies packaging |
| **Embedded IdP** | `config.yaml` with `server.auth.*` enables Dex automatically | Low -- upstream default |
| **Dashboard config** | Write `OIDCConfigResponse` file that dashboard JS reads | Medium -- replicates dashboard container's nginx behavior |
| **Let's Encrypt** | Not needed -- Cloudron handles TLS termination | None |

### What needs testing

1. **Embedded IdP flow** -- `/setup` page creates admin, `/oauth2/token` issues tokens, dashboard login works
2. **gRPC routing** -- Signal and Management gRPC connections through nginx `grpc_pass`
3. **WebSocket routing** -- Relay and ws-proxy connections with proper Upgrade headers
4. **STUN UDP port** -- Verify Cloudron's `udpPorts` correctly exposes UDP 3478
5. **Client connectivity** -- NetBird clients can connect with setup key and management URL
6. **Peer-to-peer mesh** -- Peers can communicate through WireGuard tunnels
7. **NAT traversal** -- Peers behind NAT can connect via the built-in relay
8. **Backup/restore** -- PostgreSQL + `/app/data/` backup captures all state
9. **Memory usage** -- Monitor actual usage; 512MB may need adjustment
10. **(Optional) Cloudron SSO** -- Adding Cloudron as external OIDC provider via dashboard

### Lessons learned from v1.x

The v1.x packaging had several critical issues identified by tester `timconsidine` on the [Cloudron forum](https://forum.cloudron.io/topic/7571/netbird-foss-noconf-mesh-vpn-using-wireguard-alternative-to-zerotier-tailscale-omniedge-netmaker-etc):

1. **Auth Catch-22**: Using `management.json` with `IdpManagerConfig.ManagerType: "none"` disabled the embedded IdP entirely. The `/oauth2/token` endpoint returned 401, making it impossible to log in.
2. **Wrong config format**: `management.json` is the legacy multi-container format. The combined server uses `config.yaml`.
3. **Wrong server flags**: `--management-config` is for the old management binary. The combined server uses `--config`.
4. **STUN as TCP**: STUN uses UDP. Declaring it under `tcpPorts` wouldn't expose UDP traffic.
5. **Missing dashboard config**: The dashboard JS needs `AUTH_AUDIENCE`, `AUTH_CLIENT_ID`, `AUTH_AUTHORITY`, etc. -- not just the API endpoint.
6. **Missing WebSocket routes**: `/ws-proxy/` paths were not routed at all.

### Future enhancements

1. **Cloudron OIDC auto-configuration** -- Explore using the NetBird API to auto-register Cloudron as an IdP after first admin login
2. **LDAP addon** -- Sync Cloudron users to NetBird groups
3. **JWT group sync** -- Map Cloudron groups to NetBird access control groups automatically
4. **Cloudron TURN integration** -- Investigate mapping Cloudron's TURN addon to NetBird's relay config

### Publishing to Cloudron App Store

1. Test thoroughly on a real Cloudron instance
2. Post on the [Cloudron forum packaging category](https://forum.cloudron.io/category/96/app-packaging-development) to request a project on git.cloudron.io
3. The Cloudron team creates a repo under `git.cloudron.io/packages/netbird-app`
4. Push the package and submit for review
5. Iterate based on Cloudron team feedback

Note: git.cloudron.io does not allow personal project creation (`can_create_project: false`). The Cloudron team manages the `packages/` namespace.

### References

- NetBird self-hosting quickstart: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- NetBird configuration files: https://docs.netbird.io/selfhosted/configuration-files
- NetBird external reverse proxy: https://docs.netbird.io/selfhosted/external-reverse-proxy
- NetBird identity providers: https://docs.netbird.io/selfhosted/identity-providers
- Cloudron packaging tutorial: https://docs.cloudron.io/packaging/tutorial/
- Cloudron manifest reference: https://docs.cloudron.io/packaging/manifest/
- Cloudron addons (OIDC, TURN, etc.): https://docs.cloudron.io/packaging/addons/
- Cloudron udpPorts: https://docs.cloudron.io/packaging/manifest/#udpports
- Gitea Cloudron app (reference implementation): https://git.cloudron.io/packages/gitea-app
