# NetBird Cloudron App - Packaging Notes

## Feasibility Assessment

**Overall: Medium complexity, achievable.**

### What works well with Cloudron

1. **PostgreSQL addon** -- NetBird supports PostgreSQL natively, Cloudron provides it as an addon
2. **HTTP reverse proxy** -- Dashboard, Management API, Signal gRPC, and Relay WebSocket all work over HTTP/HTTPS on port 443
3. **Single domain** -- All services multiplex on one domain via path-based routing
4. **Docker-based** -- NetBird provides pre-built binaries and Docker images
5. **Supervisord** -- Multi-process pattern (nginx + netbird-server) is well-supported by Cloudron
6. **OIDC addon** -- Cloudron's built-in OIDC provider maps directly to NetBird's "Generic OIDC" connector
7. **TURN addon** -- Cloudron provides a TURN server that NetBird can use for NAT traversal relay

### Cloudron addon integration

| Addon | Purpose | Integration method |
|-------|---------|-------------------|
| `postgresql` | Database | `CLOUDRON_POSTGRESQL_*` env vars -> PostgreSQL DSN |
| `localstorage` | Persistent data | `/app/data/` for config, encryption key, PAT |
| `oidc` | Cloudron SSO | `CLOUDRON_OIDC_*` env vars -> NetBird identity provider API |
| `turn` | NAT traversal relay | `CLOUDRON_TURN_*` env vars -> management.json TURN config |

### OIDC integration details

NetBird supports adding OIDC providers via its REST API (`POST /api/identity-providers`). The integration works as follows:

1. Cloudron provides `CLOUDRON_OIDC_ISSUER`, `CLOUDRON_OIDC_CLIENT_ID`, `CLOUDRON_OIDC_CLIENT_SECRET`
2. The manifest declares `loginRedirectUri: "/oauth2/callback/cloudron"` which Cloudron registers with its OIDC provider
3. On startup, `start.sh` waits for the management API to become available
4. If an admin PAT exists at `/app/data/config/.admin_pat`, it registers Cloudron as a Generic OIDC provider via the API
5. If no PAT exists, it prints manual setup instructions to the logs

**Key consideration**: The OIDC registration happens via the API (not config files) because NetBird manages identity providers as runtime state in the database. This means:
- The registration survives restarts (stored in PostgreSQL)
- The startup script checks for existing registration to avoid duplicates
- The PAT is needed because the API requires authentication

### TURN integration details

Cloudron's TURN addon provides `CLOUDRON_TURN_SERVER`, `CLOUDRON_TURN_PORT`, `CLOUDRON_TURN_TLS_PORT`, and `CLOUDRON_TURN_SECRET`. These map to NetBird's `TURNConfig` in `management.json`:

- TURN is added as an additional relay alongside NetBird's built-in relay
- Time-based credentials are used (standard TURN auth with shared secret)
- The STUN port (UDP 3478) is still exposed for NAT type detection

### Challenges and solutions

| Challenge | Solution | Risk |
|-----------|----------|------|
| **UDP 3478 (STUN)** | Use `tcpPorts` in manifest (supports UDP despite the name) | Low -- Cloudron handles port mapping |
| **gRPC over HTTP/2** | nginx `grpc_pass` directive handles this | Low -- well-tested pattern |
| **Combined server binary** | NetBird v0.29+ ships a single `netbird-server` binary | Low -- simplifies packaging |
| **OIDC registration** | Post-start API call with PAT, fallback to manual instructions | Low -- graceful degradation |
| **OIDC redirect URI** | Declared in manifest `loginRedirectUri`, matches NetBird's callback pattern | Low |
| **Let's Encrypt** | Not needed -- Cloudron handles TLS termination | None |
| **WebSocket relay** | nginx `proxy_pass` with upgrade headers | Low |

### What needs testing

1. **gRPC multiplexing** -- Management and Signal both use gRPC on the same port; nginx must route by service path
2. **STUN UDP port** -- Verify Cloudron's `tcpPorts` correctly exposes UDP
3. **OIDC login flow** -- Full end-to-end: Cloudron login page -> NetBird dashboard access
4. **OIDC redirect URI** -- Verify `/oauth2/callback/cloudron` matches what NetBird generates
5. **TURN relay** -- Verify peers behind strict NAT can connect via Cloudron's TURN server
6. **Client compatibility** -- Ensure official NetBird clients can connect to a Cloudron-hosted management server
7. **Backup/restore** -- Verify PostgreSQL + `/app/data/` backup captures all state (including OIDC config in DB)
8. **Memory usage** -- Monitor actual usage; 512MB may need adjustment

### Development workflow

```bash
# Prerequisites
npm install -g cloudron
cloudron login my.cloudron.example

# Build and test
cloudron build
cloudron install --location netbird

# Iterate
cloudron build && cloudron update --app netbird
cloudron logs -f --app netbird

# Debug
cloudron exec --app netbird
cloudron debug --app netbird
```

### Future enhancements

1. **LDAP addon** -- Sync Cloudron users to NetBird groups
2. **JWT group sync** -- Map Cloudron groups to NetBird access control groups automatically
3. **Health check** -- Implement proper `/health` endpoint check instead of `/api/accounts`
4. **Auto-PAT generation** -- Explore creating a PAT during first-run setup to avoid the manual step

### Publishing to Cloudron App Store

1. Test thoroughly on a real Cloudron instance
2. Post on the [Cloudron forum packaging category](https://forum.cloudron.io/category/96/app-packaging-development) to request a project on git.cloudron.io
3. The Cloudron team creates a repo under `git.cloudron.io/packages/netbird-app`
4. Push the package and submit for review
5. Iterate based on Cloudron team feedback

Note: git.cloudron.io does not allow personal project creation (`can_create_project: false`). The Cloudron team manages the `packages/` namespace.

### References

- NetBird self-hosting: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- NetBird OIDC guide: https://docs.netbird.io/selfhosted/identity-providers/generic-oidc
- NetBird identity providers: https://docs.netbird.io/selfhosted/identity-providers
- Cloudron packaging: https://docs.cloudron.io/packaging/tutorial/
- Cloudron manifest: https://docs.cloudron.io/packaging/manifest/
- Cloudron addons (OIDC, TURN): https://docs.cloudron.io/packaging/addons/
- Cloudron tcpPorts: https://docs.cloudron.io/packaging/manifest/#tcpports
- Example Go app packages: https://git.cloudron.io/explore/projects/topics/go
