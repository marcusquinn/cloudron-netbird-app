# NetBird for Cloudron

[Cloudron](https://cloudron.io) app package for [NetBird](https://netbird.io) -- a self-hosted WireGuard mesh VPN with SSO, MFA, and granular access controls.

## What is NetBird?

NetBird connects devices into a secure peer-to-peer WireGuard mesh network. Unlike Tailscale, the entire control plane is open-source and self-hostable.

| Feature | Details |
|---------|---------|
| Protocol | WireGuard (kernel or userspace) |
| Architecture | Peer-to-peer mesh (no hub-and-spoke) |
| NAT traversal | ICE + STUN + TURN relay fallback |
| Auth | Any OIDC provider (Keycloak, Google, Entra ID, etc.) |
| Access control | Group-based policies with posture checks |
| API | Full REST API + Terraform provider |
| License | BSD-3 (client), AGPL-3.0 (server) |

## What this package provides

This Cloudron app packages the **NetBird management server**, which includes:

- **Management API** -- peer registry, ACLs, setup keys, network routes
- **Signal server** -- WebRTC ICE negotiation for P2P connection setup
- **Relay server** -- TURN fallback for peers behind strict NAT
- **STUN server** -- NAT type detection (UDP 3478)
- **Dashboard** -- web UI for administration

NetBird clients on your devices connect to this management server to join the mesh.

## Requirements

| Resource | Minimum |
|----------|---------|
| Cloudron | v7.6.0+ |
| Memory | 512 MB (configurable in manifest) |
| Ports | TCP 80/443 (handled by Cloudron) + **UDP 3478** (STUN, exposed via `tcpPorts`) |

**Important**: UDP port 3478 must be accessible from all NetBird clients for NAT traversal. Cloudron exposes this via the `tcpPorts` manifest option.

## Installation

### From source (development)

```bash
# Install Cloudron CLI
npm install -g cloudron

# Login to your Cloudron instance
cloudron login my.cloudron.example

# Clone and build
git clone https://github.com/marcusquinn/cloudron-netbird-app.git
cd cloudron-netbird-app
cloudron build

# Install
cloudron install --location netbird
```

### From Cloudron App Store

Not yet available. See [Contributing](#contributing) if you'd like to help get it there.

## First Run

1. Open `https://netbird.your-cloudron.example` in your browser
2. The `/setup` page appears on first run -- create your admin account
3. Navigate to **Setup Keys** to create a key for connecting devices
4. Install the NetBird client on your devices and connect:

```bash
# Install client
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Connect to your self-hosted management server
sudo netbird up \
  --setup-key YOUR_SETUP_KEY \
  --management-url https://netbird.your-cloudron.example
```

## Architecture

```text
Cloudron Server
+-------------------------------------------------------+
|  Cloudron nginx (TLS termination, port 443)            |
|    |                                                   |
|    v                                                   |
|  +---------------------------------------------------+ |
|  | App Container (this package)                       | |
|  |                                                    | |
|  |  nginx :8080 (internal reverse proxy)              | |
|  |    |-- /api, /oauth2, /setup  -> management :8081  | |
|  |    |-- /signalexchange/       -> signal gRPC :8081 | |
|  |    |-- /management/           -> mgmt gRPC :8081   | |
|  |    |-- /relay                 -> relay WS :8081    | |
|  |    |-- /*                     -> dashboard (static)| |
|  |                                                    | |
|  |  netbird-server :8081 (combined binary)            | |
|  |    Management + Signal + Relay + STUN              | |
|  |                                                    | |
|  +---------------------------------------------------+ |
|                                                        |
|  PostgreSQL addon (Cloudron-managed)                   |
|  UDP :3478 (STUN, exposed via tcpPorts)                |
+-------------------------------------------------------+
```

## Configuration

### Database

Uses Cloudron's PostgreSQL addon automatically. No manual database setup required.

### Identity Provider

**Default**: Embedded IdP (Dex). Users are managed directly from the NetBird dashboard.

**Recommended for production**: Connect to an OIDC provider. If you run Keycloak on Cloudron, you can use it as the IdP for single sign-on across all your apps.

### Persistent Data

All persistent data is stored in `/app/data/` and included in Cloudron backups:

| Path | Contents |
|------|----------|
| `/app/data/config/` | Management server config, encryption key |
| `/app/data/netbird/` | Server state and data |
| `/app/data/dashboard/` | Dashboard environment config |

The encryption key at `/app/data/config/.encryption_key` is generated on first run and encrypts setup keys and API tokens at rest. It is included in Cloudron backups.

## Development

```bash
# Build and install
cloudron build
cloudron install --location netbird

# Iterate after changes
cloudron build && cloudron update --app netbird

# View logs
cloudron logs -f --app netbird

# Shell into the container
cloudron exec --app netbird

# Debug mode (writable filesystem)
cloudron debug --app netbird

# Uninstall
cloudron uninstall --app netbird
```

### Testing Checklist

- [ ] Fresh install completes without errors
- [ ] Dashboard loads at app URL
- [ ] `/setup` page appears on first run
- [ ] Admin account creation works
- [ ] Setup key creation works
- [ ] Client connects with setup key
- [ ] Peers can ping each other through the mesh
- [ ] App survives restart (`cloudron restart --app netbird`)
- [ ] Backup/restore preserves all state
- [ ] Memory stays within 512 MB limit
- [ ] STUN port (UDP 3478) is accessible from clients

## File Structure

```text
cloudron-netbird-app/
  CloudronManifest.json    # Cloudron app metadata and addon requirements
  Dockerfile               # Build instructions
  start.sh                 # Runtime entry point (config injection, process launch)
  supervisord.conf         # Multi-process management (nginx + netbird-server)
  config.template.yaml     # Default config reference
  nginx-netbird.conf       # Default nginx config reference
  logo.png                 # App icon (256x256)
  PACKAGING-NOTES.md       # Detailed feasibility assessment and notes
  LICENSE                  # MIT
```

## Known Limitations

1. **STUN port**: UDP 3478 must be directly accessible -- it cannot go through Cloudron's HTTP reverse proxy. Verify your firewall allows this.

2. **No Cloudron SSO yet**: The initial version uses NetBird's built-in IdP. Cloudron OIDC addon integration is planned for a future release.

3. **Single account mode**: All users join the same network by default. This is appropriate for most self-hosted deployments.

4. **Logo**: Uses NetBird's official logo from their [dashboard repository](https://github.com/netbirdio/dashboard).

## Upstream

- **NetBird**: https://github.com/netbirdio/netbird
- **NetBird Docs**: https://docs.netbird.io
- **NetBird Self-Hosting**: https://docs.netbird.io/selfhosted/selfhosted-quickstart

## Contributing

Contributions are welcome. The main areas that need work:

1. **Testing on a real Cloudron instance** -- the packaging scaffold is complete but needs real-world validation
2. **Cloudron OIDC integration** -- connect NetBird auth to Cloudron's OIDC addon
3. **Logo** -- add a 256x256 `logo.png`
4. **App Store submission** -- once tested, submit to the [Cloudron App Store](https://docs.cloudron.io/packaging/publishing/)

### Submitting to the Cloudron App Store

1. Test thoroughly on a real Cloudron instance
2. Post on the [Cloudron forum packaging category](https://forum.cloudron.io/category/96/app-packaging-development) to request a project on git.cloudron.io
3. The Cloudron team creates a repo under `git.cloudron.io/packages/netbird-app`
4. Push the package and submit for review

Note: git.cloudron.io does not allow personal project creation. The Cloudron team manages the `packages/` namespace.

## License

This Cloudron app package is licensed under the [MIT License](LICENSE).

NetBird itself is licensed under BSD-3 (client) and AGPL-3.0 (server). See the [NetBird repository](https://github.com/netbirdio/netbird) for details.
