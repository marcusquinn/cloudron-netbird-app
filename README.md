# NetBird for Cloudron

[Cloudron](https://cloudron.io) app package for [NetBird](https://netbird.io) -- a self-hosted WireGuard mesh VPN with SSO, MFA, and granular access controls.

## What is NetBird?

NetBird connects devices into a secure peer-to-peer WireGuard mesh network. Unlike Tailscale, the entire control plane is open-source and self-hostable.

| Feature | Details |
|---------|---------|
| Protocol | WireGuard (kernel or userspace) |
| Architecture | Peer-to-peer mesh (no hub-and-spoke) |
| NAT traversal | ICE + STUN + TURN relay fallback |
| Auth | Any OIDC provider (Cloudron SSO, Keycloak, Google, Entra ID, etc.) |
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
- **Cloudron SSO** -- log in with your Cloudron credentials via OIDC
- **Cloudron TURN** -- uses Cloudron's built-in TURN server for NAT traversal relay

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

## Cloudron SSO (Single Sign-On)

This package integrates with Cloudron's built-in OIDC provider. Users can log into NetBird with their Cloudron credentials -- no separate Keycloak or other IdP needed.

### How it works

1. Cloudron provides OIDC credentials to the app via the `oidc` addon
2. On startup, the app registers Cloudron as a "Generic OIDC" identity provider in NetBird
3. The NetBird login page shows a "Cloudron" button alongside the local email/password option
4. Users authenticate against Cloudron's user directory and are redirected back to NetBird

### Automatic setup

If you have a Personal Access Token (PAT) stored at `/app/data/config/.admin_pat`, the Cloudron OIDC provider is registered automatically on each app start. To set this up:

1. Log into the NetBird dashboard with your admin account
2. Go to **Settings > Personal Access Tokens**
3. Create a new token
4. Shell into the container and save it:

```bash
cloudron exec --app netbird
echo "YOUR_PAT_HERE" > /app/data/config/.admin_pat
chmod 600 /app/data/config/.admin_pat
```

5. Restart the app -- Cloudron SSO will be registered automatically

### Manual setup

If you prefer to configure it manually (or the automatic registration didn't work):

1. Log into the NetBird dashboard
2. Go to **Settings > Identity Providers > Add Identity Provider**
3. Select **Generic OIDC**
4. Fill in the fields (these are printed in the app logs on startup):
   - **Name**: `Cloudron`
   - **Issuer**: (from `CLOUDRON_OIDC_ISSUER` -- check app logs)
   - **Client ID**: (from `CLOUDRON_OIDC_CLIENT_ID` -- check app logs)
   - **Client Secret**: (from `CLOUDRON_OIDC_CLIENT_SECRET` -- available inside the container)
5. Copy the **Redirect URL** that NetBird shows and verify it matches the `loginRedirectUri` in the manifest

### Notes

- Local email/password authentication remains available alongside Cloudron SSO
- Multiple identity providers can coexist (Cloudron + Google + Keycloak, etc.)
- NetBird supports JWT group sync -- Cloudron user groups can map to NetBird access control groups

## Cloudron TURN Integration

This package uses Cloudron's built-in TURN server (via the `turn` addon) as an additional relay for NAT traversal. This means:

- Peers behind strict/symmetric NAT can relay through Cloudron's TURN server
- The standalone STUN port (UDP 3478) is still used for NAT type detection
- Both STUN and TURN work together for maximum connectivity

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
|  OIDC addon (Cloudron SSO)                             |
|  TURN addon (Cloudron TURN relay)                      |
|  UDP :3478 (STUN, exposed via tcpPorts)                |
+-------------------------------------------------------+
```

## Configuration

### Database

Uses Cloudron's PostgreSQL addon automatically. No manual database setup required.

### Identity Provider

**Built-in**: Cloudron SSO via OIDC addon (see [Cloudron SSO](#cloudron-sso-single-sign-on) above).

**Also available**: Local email/password (NetBird's embedded IdP), or any additional OIDC provider added via the dashboard (Google, Microsoft, Keycloak, Authentik, etc.). Multiple providers can coexist.

### Persistent Data

All persistent data is stored in `/app/data/` and included in Cloudron backups:

| Path | Contents |
|------|----------|
| `/app/data/config/` | Management server config, encryption key, admin PAT |
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
- [ ] Cloudron SSO login button appears on login page
- [ ] Cloudron users can log in via SSO
- [ ] Setup key creation works
- [ ] Client connects with setup key
- [ ] Peers can ping each other through the mesh
- [ ] Peers behind NAT connect via TURN relay
- [ ] App survives restart (`cloudron restart --app netbird`)
- [ ] Backup/restore preserves all state (including OIDC config)
- [ ] Memory stays within 512 MB limit
- [ ] STUN port (UDP 3478) is accessible from clients

## File Structure

```text
cloudron-netbird-app/
  CloudronManifest.json    # Cloudron app metadata and addon requirements
  Dockerfile               # Build instructions
  start.sh                 # Runtime entry point (config injection, OIDC setup, process launch)
  supervisord.conf         # Multi-process management (nginx + netbird-server)
  config.template.yaml     # Default config reference
  nginx-netbird.conf       # Default nginx config reference
  logo.png                 # App icon (256x256)
  PACKAGING-NOTES.md       # Detailed feasibility assessment and notes
  LICENSE                  # MIT
```

## Reverse Proxy Feature

NetBird v0.65+ includes a [Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy) feature (beta) that can expose internal services on mesh peers to the public internet with automatic TLS and optional SSO/password/PIN authentication.

**This feature is NOT compatible with this Cloudron package.** The reverse proxy requires [Traefik with TLS passthrough](https://docs.netbird.io/selfhosted/reverse-proxy) in front of the management server. Cloudron uses nginx for TLS termination, which does not support TLS passthrough. The NetBird proxy container (`netbirdio/netbird-proxy`) needs to handle TLS termination itself, which is impossible when Cloudron's nginx has already terminated TLS.

If you need the reverse proxy feature, deploy NetBird standalone (outside Cloudron) with Traefik as documented in the [NetBird self-hosted guide](https://docs.netbird.io/selfhosted/selfhosted-quickstart).

**What still works without it**: All core mesh VPN functionality -- peer-to-peer WireGuard tunnels, NAT traversal, access control, DNS, network routes, setup keys, and the management dashboard. The reverse proxy is an optional add-on for exposing internal services publicly; the mesh itself does not depend on it.

## Known Limitations

1. **STUN port**: UDP 3478 must be directly accessible -- it cannot go through Cloudron's HTTP reverse proxy. Verify your firewall allows this.

2. **OIDC auto-registration requires a PAT**: The automatic Cloudron SSO setup needs a Personal Access Token saved to `/app/data/config/.admin_pat`. Without it, you can still add Cloudron as an OIDC provider manually via the dashboard.

3. **Reverse proxy not supported**: NetBird's reverse proxy feature requires Traefik with TLS passthrough, which is incompatible with Cloudron's nginx. See [Reverse Proxy Feature](#reverse-proxy-feature) above.

4. **Single account mode**: All users join the same network by default. This is appropriate for most self-hosted deployments.

5. **No pre-shared keys or Rosenpass**: These features are not yet compatible with the reverse proxy or some relay configurations.

## Upstream

- **NetBird**: https://github.com/netbirdio/netbird
- **NetBird Docs**: https://docs.netbird.io
- **NetBird Self-Hosting**: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- **NetBird OIDC Guide**: https://docs.netbird.io/selfhosted/identity-providers/generic-oidc
- **NetBird Reverse Proxy**: https://docs.netbird.io/manage/reverse-proxy (not compatible with Cloudron -- see above)

## Contributing

Contributions are welcome. The main areas that need work:

1. **Testing on a real Cloudron instance** -- the packaging scaffold is complete but needs real-world validation
2. **OIDC flow testing** -- verify the Cloudron SSO login flow end-to-end
3. **TURN relay testing** -- verify peers behind strict NAT can connect via Cloudron's TURN server
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
