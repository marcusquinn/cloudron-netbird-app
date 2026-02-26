# NetBird for Cloudron

[Cloudron](https://cloudron.io) app package for [NetBird](https://netbird.io) -- a self-hosted WireGuard mesh VPN with SSO, MFA, and granular access controls.

## What is NetBird?

NetBird connects devices into a secure peer-to-peer WireGuard mesh network. Unlike Tailscale, the entire control plane is open-source and self-hostable.

| Feature | Details |
|---------|---------|
| Protocol | WireGuard (kernel or userspace) |
| Architecture | Peer-to-peer mesh (no hub-and-spoke) |
| NAT traversal | ICE + STUN + built-in relay fallback |
| Auth | Embedded IdP + any OIDC provider (Cloudron SSO, Keycloak, Google, Entra ID, etc.) |
| Access control | Group-based policies with posture checks |
| API | Full REST API + Terraform provider |
| License | BSD-3 (client), AGPL-3.0 (server) |

## What this package provides

This Cloudron app packages the **NetBird combined server** (v0.65.3+), which includes:

- **Management API** -- peer registry, ACLs, setup keys, network routes
- **Signal server** -- WebRTC ICE negotiation for P2P connection setup
- **Relay server** -- fallback for peers behind strict NAT
- **STUN server** -- NAT type detection (UDP 3478)
- **Embedded IdP** -- built-in user management (Dex) with `/setup` onboarding page
- **Dashboard** -- web UI for administration

NetBird clients on your devices connect to this management server to join the mesh.

## Requirements

| Resource | Minimum |
|----------|---------|
| Cloudron | v7.6.0+ |
| Memory | 512 MB (configurable in manifest) |
| Ports | TCP 80/443 (handled by Cloudron) + **UDP 3478** (STUN, exposed via `udpPorts`) |

**Important**: UDP port 3478 must be accessible from all NetBird clients for NAT traversal.

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
2. You'll be redirected to the **setup page** (`/setup`)
3. Create your admin account (email + password)
4. Log in with the credentials you just created
5. Navigate to **Setup Keys** to create a key for connecting devices
6. Install the NetBird client on your devices and connect:

```bash
# Install client
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Connect to your self-hosted management server
sudo netbird up \
  --setup-key YOUR_SETUP_KEY \
  --management-url https://netbird.your-cloudron.example
```

The `/setup` page is only accessible when no users exist. After creating the first user, it redirects to the regular login page.

## Adding Cloudron SSO (Optional)

After initial setup, you can add Cloudron as an external identity provider so users can log in with their Cloudron credentials:

1. Install the app **with SSO enabled** (the OIDC addon provides `CLOUDRON_OIDC_*` environment variables)
2. Log into the NetBird dashboard with your admin account
3. Go to **Settings > Identity Providers > Add Identity Provider**
4. Select **Generic OIDC** and fill in:
   - **Name**: `Cloudron`
   - **Issuer**: Check app logs for `CLOUDRON_OIDC_ISSUER` value
   - **Client ID**: Check app logs for `CLOUDRON_OIDC_CLIENT_ID` value
   - **Client Secret**: Available inside the container at `$CLOUDRON_OIDC_CLIENT_SECRET`
5. Save -- the login page will now show a "Cloudron" button alongside local email/password

**Notes**:
- Local email/password authentication remains available alongside Cloudron SSO
- Multiple identity providers can coexist (Cloudron + Google + Keycloak, etc.)
- NetBird supports JWT group sync for mapping Cloudron groups to access control groups

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
|  |    |-- /signalexchange/  -> gRPC :80 (grpc_pass)   | |
|  |    |-- /management/      -> gRPC :80 (grpc_pass)   | |
|  |    |-- /relay, /ws-proxy -> WebSocket :80           | |
|  |    |-- /api, /oauth2     -> HTTP :80                | |
|  |    |-- /* (incl /setup)  -> dashboard (static SPA)  | |
|  |                                                    | |
|  |  netbird-server :80 (combined binary)              | |
|  |    Management + Signal + Relay + embedded IdP      | |
|  |    STUN :3478/udp (exposed directly)               | |
|  |                                                    | |
|  +---------------------------------------------------+ |
|                                                        |
|  PostgreSQL addon (Cloudron-managed)                   |
+-------------------------------------------------------+
```

## Configuration

### Database

Uses Cloudron's PostgreSQL addon automatically. No manual database setup required.

### Identity Provider

**Built-in**: NetBird's embedded IdP (Dex) handles initial setup and local user management. The `/setup` page creates the first admin account.

**Optional**: Cloudron SSO or any OIDC provider can be added via the dashboard after initial setup. Multiple providers can coexist.

### Persistent Data

All persistent data is stored in `/app/data/` and included in Cloudron backups:

| Path | Contents |
|------|----------|
| `/app/data/config/config.yaml` | Combined server configuration |
| `/app/data/config/.encryption_key` | Database encryption key (generated on first run) |
| `/app/data/config/.auth_secret` | Relay authentication secret (generated on first run) |
| `/app/data/netbird/` | Server state and data |
| `/app/data/dashboard/` | Dashboard environment config |

The encryption key encrypts setup keys and API tokens at rest. It is included in Cloudron backups. **Do not lose it** -- losing this key means regenerating all setup keys and API tokens.

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
- [ ] `/setup` page appears on first run (no users exist)
- [ ] Admin account creation works via setup page
- [ ] Login with created credentials works
- [ ] Setup key creation works in dashboard
- [ ] Client connects with setup key and management URL
- [ ] Peers can ping each other through the mesh
- [ ] Peers behind NAT connect via relay
- [ ] gRPC connections work (signal + management)
- [ ] WebSocket connections work (relay + ws-proxy)
- [ ] App survives restart (`cloudron restart --app netbird`)
- [ ] Backup/restore preserves all state
- [ ] Memory stays within 512 MB limit
- [ ] STUN port (UDP 3478) is accessible from clients
- [ ] (Optional) Cloudron SSO can be added as external IdP via dashboard

## File Structure

```text
cloudron-netbird-app/
  CloudronManifest.json    # Cloudron app metadata and addon requirements
  Dockerfile               # Build instructions
  start.sh                 # Runtime entry point (config generation, process launch)
  supervisord.conf         # Multi-process management (nginx + netbird-server)
  logo.png                 # App icon (256x256)
  PACKAGING-NOTES.md       # Detailed feasibility assessment and notes
  CHANGELOG.md             # Version history
  LICENSE                  # MIT
```

## Reverse Proxy Feature

NetBird v0.65+ includes a [Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy) feature that can expose internal services on mesh peers to the public internet with automatic TLS.

**This feature is NOT compatible with this Cloudron package.** It requires Traefik with TLS passthrough. Cloudron's nginx terminates TLS before traffic reaches the app, so TLS passthrough is not possible. See the [TLS passthrough feature request](https://forum.cloudron.io/topic/15109/tls-passthrough-option-for-apps-requiring-end-to-end-tls) on the Cloudron forum.

**What still works**: All core mesh VPN functionality -- peer-to-peer WireGuard tunnels, NAT traversal, access control, DNS, network routes, setup keys, and the management dashboard.

## Known Limitations

1. **STUN port**: UDP 3478 must be directly accessible -- it cannot go through Cloudron's HTTP reverse proxy.
2. **Reverse proxy not supported**: NetBird's reverse proxy feature requires Traefik with TLS passthrough, which is incompatible with Cloudron's nginx.
3. **Single account mode**: All users join the same network by default. This is appropriate for most self-hosted deployments.

## Upstream

- **NetBird**: https://github.com/netbirdio/netbird
- **NetBird Docs**: https://docs.netbird.io
- **NetBird Self-Hosting**: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- **NetBird Configuration**: https://docs.netbird.io/selfhosted/configuration-files
- **NetBird External Reverse Proxy**: https://docs.netbird.io/selfhosted/external-reverse-proxy

## Contributing

Contributions are welcome. The main areas that need work:

1. **Testing on a real Cloudron instance** -- the packaging needs real-world validation
2. **Auth flow testing** -- verify the embedded IdP setup page and login work end-to-end
3. **gRPC/WebSocket testing** -- verify signal and management connections work through the nginx proxy
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
