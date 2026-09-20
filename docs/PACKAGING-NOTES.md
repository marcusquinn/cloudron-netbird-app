# NetBird Cloudron App - Packaging Notes

Historical architecture and implementation lessons. For current integration
boundaries, read [Cloudron access integration](CLOUDRON-INTEGRATION.md).
Exact released versions are defined by the root manifest and version catalog.

## Feasibility Assessment

**Overall: Medium complexity, achievable.**

### Architecture (v2.0.16)

This package uses the **combined server** architecture (`netbird-server` binary, `config.yaml` format) introduced in NetBird v0.65.0. This is the recommended approach for new deployments per the [upstream docs](https://docs.netbird.io/selfhosted/configuration-files).

Key design decisions:

1. **Embedded IdP (Dex)** handles initial authentication. The `/setup` page creates the first admin account. No external IdP is required for first-run.
2. **Cloudron OIDC is optional** and added post-setup via the dashboard UI. This avoids the Catch-22 where you need to log in to configure the IdP you need to log in with.
3. **config.yaml** (not `management.json`) is used for server configuration. The old `management.json` format is for the legacy multi-container architecture and does not enable the embedded IdP.
4. **Dashboard static files** are served directly by our nginx. The upstream `netbirdio/dashboard` container has its own nginx that generates runtime config from env vars -- we replicate its allowlisted `envsubst` pass in an ephemeral dashboard copy under `/run`.
5. **Native clients use a dedicated TLS port** because Cloudron's standard app
   proxy does not preserve native HTTP/2 gRPC. nginx listens on fixed container
   port 33074 using the `tls` addon. `server.exposedAddress` advertises the
   selected external `NETBIRD_PORT`. NetBird reserves container port 33073 for
   its backward-compatibility gRPC listener.

### What works well with Cloudron

1. **PostgreSQL addon** -- NetBird supports PostgreSQL natively, Cloudron provides it as an addon
2. **Split web/native transport** -- Dashboard, REST API, and OIDC use Cloudron
   HTTPS. Native gRPC and relay traffic use a dedicated TLS port.
3. **Single domain** -- Both listeners use the app domain. Clients include the
   selected native port.
4. **Docker-based** -- NetBird provides pre-built binaries and Docker images
5. **Supervisord** -- Multi-process pattern (nginx + netbird-server) is well-supported by Cloudron

### Cloudron addon integration

| Addon | Purpose | Integration method |
|-------|---------|-------------------|
| `postgresql` | Database | `CLOUDRON_POSTGRESQL_*` env vars -> `server.store.dsn` in config.yaml |
| `localstorage` | Persistent data | `/app/data/` for config, encryption key, auth secret |
| `oidc` | Optional Cloudron SSO client | Install-time credentials for manual owner-managed registration; callback `/oauth2/callback` |
| `tls` | Native TLS certificate | Cloudron certificate files on nginx port 33074 |

### Addons NOT used (and why)

| Addon | Why not |
|-------|---------|
| `turn` | NetBird's combined server already supplies relay/STUN. Cloudron TURN expects time-limited credentials derived from its shared secret, while NetBird's external STUN/TURN entries accept static credentials; advertising the addon directly would fail authentication. |

`optionalSso: true` makes the declared OIDC addon an installation choice. The
Cloudron SSO flag cannot be changed after installation, so a `--no-sso` instance
continues to use embedded auth across updates. NetBird v0.79.0 exposes
authenticated `/api/identity-providers` CRUD, but startup has no owner token.
Automatic registration is therefore intentionally excluded: it would require a
persisted privileged token and could race or overwrite an owner-managed
connector. Startup only reports whether a complete optional OIDC environment is
available and never logs or persists its values.

### nginx routing (critical)

The internal nginx accepts Cloudron-proxied HTTP on port 8080 and direct
TLS/HTTP2 on fixed container port 33074. Both listeners route to the combined
server on port 80. Native routing must match the [upstream nginx
configuration](https://docs.netbird.io/selfhosted/external-reverse-proxy#nginx-combined):

| Path | Protocol | nginx directive | Notes |
|------|----------|----------------|-------|
| `/signalexchange.SignalExchange/*` | gRPC | `grpc_pass` | HTTP/2 cleartext (h2c) |
| `/management.ManagementService/*` | gRPC | `grpc_pass` | HTTP/2 cleartext (h2c) |
| `/relay*`, `/ws-proxy/*` | WebSocket | `proxy_pass` + Upgrade | Long-lived connections |
| `/api/*`, `/oauth2/*` | HTTP | `proxy_pass` | REST API + embedded IdP |
| `/*` | HTTP | static files / canonical redirect | The web listener serves the dashboard; GET/HEAD browser navigation on the native listener redirects to canonical HTTPS |

**Key gotchas**:
- gRPC paths MUST use `grpc_pass`, not `proxy_pass`. nginx handles h2c natively with `grpc_pass`.
- WebSocket paths need `proxy_http_version 1.1` and `Upgrade`/`Connection` headers.
- Timeouts must be `1d` for long-lived gRPC and WebSocket connections.
- The combined server listens on port 80 internally (not 8081 as in the old architecture).
- The native listener's dashboard redirect uses the configured Cloudron domain,
  never the incoming `Host` header. Explicit native transport, API, and OAuth
  locations remain proxied without redirects.

### Challenges and solutions

| Challenge | Solution | Risk |
|-----------|----------|------|
| **Configurable UDP STUN** | Use `udpPorts` without a fixed `containerPort` so NetBird listens on the same port Cloudron exposes | Low -- avoids split listen/advertised ports |
| **gRPC over HTTP/2** | Dedicated TLS listener using Cloudron's certificate, then nginx `grpc_pass` to h2c | Medium -- requires live client qualification |
| **Combined server binary** | NetBird v0.65+ ships a single `netbird-server` binary | Low -- simplifies packaging |
| **Embedded IdP** | `config.yaml` with `server.auth.*` enables Dex automatically | Low -- upstream default |
| **Dashboard config** | Substitute the pinned dashboard's embedded runtime placeholders under `/run` | Medium -- must track the upstream init contract |
| **TLS certificates** | Use Cloudron's `tls` addon for the native port; Cloudron HTTPS still handles web traffic | Low |

### What needs testing

The reproducible status, provenance requirements, cleanup ownership, and safe
entrypoints for these cases are maintained in
[`test/QUALIFICATION.md`](../test/QUALIFICATION.md). Historical observations are
not a substitute for a current candidate run or production qualification.

1. **Embedded IdP flow** -- `/setup` page creates admin, `/oauth2/token` issues tokens, dashboard login works
2. **gRPC routing** -- Signal and Management negotiate HTTP/2 on the dedicated
   TLS port and pass through nginx `grpc_pass`.
3. **WebSocket routing** -- Relay and ws-proxy connections with proper Upgrade headers
4. **STUN UDP port** -- Verify Cloudron's `udpPorts` exposes the selected UDP port
5. **Client connectivity** -- Clients connect with a setup key and
   `https://<app-domain>:<NETBIRD_PORT>`.
6. **Peer-to-peer mesh** -- Peers can communicate through WireGuard tunnels
7. **NAT traversal** -- Peers behind NAT can connect via the built-in relay
8. **Backup/restore** -- PostgreSQL + `/app/data/` backup captures all state
9. **Memory usage** -- Monitor actual usage; 512MB may need adjustment
10. **(Optional) Cloudron SSO** -- On isolated staging, add Cloudron as a Generic
    OIDC provider, verify callback/login and a denied or pending user, then prove
    embedded-owner login and setup-key peer enrolment during IdP outage and after
    deleting the connector. Never infer identity linking from matching email:
    embedded and connector identities have different NetBird user IDs.

### Lessons learned from v1.x

The v1.x packaging had several critical issues identified by tester `timconsidine` on the [Cloudron forum](https://forum.cloudron.io/topic/7571/netbird-foss-noconf-mesh-vpn-using-wireguard-alternative-to-zerotier-tailscale-omniedge-netmaker-etc):

1. **Auth Catch-22**: Using `management.json` with `IdpManagerConfig.ManagerType: "none"` disabled the embedded IdP entirely. The `/oauth2/token` endpoint returned 401, making it impossible to log in.
2. **Wrong config format**: `management.json` is the legacy multi-container format. The combined server uses `config.yaml`.
3. **Wrong server flags**: `--management-config` is for the old management binary. The combined server uses `--config`.
4. **STUN as TCP**: STUN uses UDP. Declaring it under `tcpPorts` wouldn't expose UDP traffic.
5. **Missing dashboard config**: The dashboard JS needs `AUTH_AUDIENCE`, `AUTH_CLIENT_ID`, `AUTH_AUTHORITY`, etc. -- not just the API endpoint.
6. **Missing WebSocket routes**: `/ws-proxy/` paths were not routed at all.
7. **Cloudron 443 transport assumption**: native clients use gRPC over HTTP/2,
   which Cloudron's normal app proxy does not preserve. A dedicated TCP port
   plus the `tls` addon is required.

### Future enhancements

The 2.1.0 candidate adds an opt-in bundled proxy and dedicated-IP host bridge.
See [REVERSE-PROXY.md](REVERSE-PROXY.md) for its explicit trust boundaries,
provisioning steps, private health endpoint, rollback and qualification scope.

1. **Cloudron OIDC auto-configuration** -- Reconsider only if NetBird adds a
   least-privilege bootstrap API with compare-and-set connector semantics; never
   persist an owner PAT solely for startup registration
2. **LDAP addon** -- Sync Cloudron users to NetBird groups
3. **JWT group sync** -- Map Cloudron groups to NetBird access control groups automatically
4. **Live client smoke coverage** -- Automate setup-key creation and real client
   registration when a safe fixture is available.

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
