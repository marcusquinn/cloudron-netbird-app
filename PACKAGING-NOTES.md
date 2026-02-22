# NetBird Cloudron App - Packaging Notes

## Feasibility Assessment

**Overall: Medium complexity, achievable.**

### What works well with Cloudron

1. **PostgreSQL addon** -- NetBird supports PostgreSQL natively, Cloudron provides it as an addon
2. **HTTP reverse proxy** -- Dashboard, Management API, Signal gRPC, and Relay WebSocket all work over HTTP/HTTPS on port 443
3. **Single domain** -- All services multiplex on one domain via path-based routing
4. **Docker-based** -- NetBird provides pre-built binaries and Docker images
5. **Supervisord** -- Multi-process pattern (nginx + netbird-server) is well-supported by Cloudron

### Challenges and solutions

| Challenge | Solution | Risk |
|-----------|----------|------|
| **UDP 3478 (STUN)** | Use `tcpPorts` in manifest (supports UDP despite the name) | Low -- Cloudron handles port mapping |
| **gRPC over HTTP/2** | nginx `grpc_pass` directive handles this | Low -- well-tested pattern |
| **Combined server binary** | NetBird v0.29+ ships a single `netbird-server` binary | Low -- simplifies packaging |
| **IdP integration** | Start with embedded Dex (built-in), upgrade to Cloudron OIDC later | Medium -- OIDC addon integration needs testing |
| **Let's Encrypt** | Not needed -- Cloudron handles TLS termination | None |
| **WebSocket relay** | nginx `proxy_pass` with upgrade headers | Low |

### What needs testing

1. **gRPC multiplexing** -- Management and Signal both use gRPC on the same port; nginx must route by service path
2. **STUN UDP port** -- Verify Cloudron's `tcpPorts` correctly exposes UDP
3. **Client compatibility** -- Ensure official NetBird clients can connect to a Cloudron-hosted management server
4. **Backup/restore** -- Verify PostgreSQL + `/app/data/` backup captures all state
5. **Memory usage** -- Monitor actual usage; 512MB may need adjustment

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

1. **OIDC addon** -- Integrate with Cloudron's OIDC for single sign-on (users log into NetBird with their Cloudron credentials)
2. **LDAP addon** -- Sync Cloudron users to NetBird groups
3. **Health check** -- Implement proper `/health` endpoint check instead of `/api/accounts`

### Publishing to Cloudron App Store

1. Test thoroughly on a real Cloudron instance
2. Create repo on git.cloudron.io (Marcus has an account)
3. Submit for review via merge request to the app store
4. Iterate based on Cloudron team feedback

### References

- NetBird self-hosting: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- Cloudron packaging: https://docs.cloudron.io/packaging/tutorial/
- Cloudron manifest: https://docs.cloudron.io/packaging/manifest/
- Cloudron tcpPorts: https://docs.cloudron.io/packaging/manifest/#tcpports
- Example Go app packages: https://git.cloudron.io/explore/projects/topics/go
