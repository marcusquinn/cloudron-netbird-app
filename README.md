# NetBird for Cloudron

[Cloudron](https://cloudron.io) app package for [NetBird](https://netbird.io) -- a self-hosted WireGuard mesh VPN with SSO, MFA, and granular access controls.

## What is NetBird?

NetBird connects devices into a secure peer-to-peer WireGuard mesh network. The entire control plane is open-source and self-hostable.

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

This Cloudron app packages the **NetBird combined server** (v0.77.0+), which includes:

- **Management API** -- peer registry, ACLs, setup keys, network routes
- **Signal server** -- WebRTC ICE negotiation for P2P connection setup
- **Relay server** -- fallback for peers behind strict NAT
- **STUN server** -- NAT type detection (UDP 3478)
- **Embedded IdP** -- built-in user management (Dex) with `/setup` onboarding page
- **Dashboard** -- web UI for administration

NetBird clients connect to this server to join the mesh.

## Requirements

| Resource | Minimum |
|----------|---------|
| Cloudron | v9.1.0+ |
| Memory | 512 MB (configurable in manifest) |
| Ports | TCP 443 plus configurable TCP 33073 and UDP 3478 by default |

**Important**: Keep both selected NetBird ports accessible from clients. Cloudron
maps the external native TCP port to container port 33074. NetBird listens
directly on the selected STUN UDP port.

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

# Connect to your self-hosted management server.
# Port 33073 is the default; replace it if Cloudron assigned another TCP port.
sudo netbird up \
  --setup-key YOUR_SETUP_KEY \
  --management-url https://netbird.your-cloudron.example:33073
```

The `/setup` page is only accessible when no users exist. After creating the first user, it redirects to the regular login page.

## Adding Cloudron SSO (Optional)

After initial setup, you can add Cloudron as an external identity provider so users can log in with their Cloudron credentials.

The manifest sets `optionalSso: true`, so Cloudron shows an "Enable SSO" toggle during installation. SSO must be enabled at install time (or via reconfigure) for the `CLOUDRON_OIDC_*` environment variables to be available.

1. Ensure SSO is enabled for the app (Cloudron dashboard > App Settings > Enable SSO)
2. Log into the NetBird dashboard with your admin account
3. Go to **Settings > Identity Providers > Add Identity Provider**
4. Select **Generic OIDC** and fill in:
   - **Name**: `Cloudron`
   - **Issuer**: Run `cloudron exec --app netbird -- printenv CLOUDRON_OIDC_ISSUER`
   - **Client ID**: Run `cloudron exec --app netbird -- printenv CLOUDRON_OIDC_CLIENT_ID`
   - **Client Secret**: Run `cloudron exec --app netbird -- printenv CLOUDRON_OIDC_CLIENT_SECRET`
5. Save -- the login page will now show a "Cloudron" button alongside local email/password

**Notes**:
- Local email/password authentication remains available alongside Cloudron SSO
- Multiple identity providers can coexist (Cloudron + Google + Keycloak, etc.)
- NetBird supports JWT group sync for mapping Cloudron groups to access control groups

## Architecture

```text
Cloudron Server
+----------------------------------------------------------+
| Cloudron HTTPS :443 -> nginx :8080                       |
|   dashboard, REST API, embedded IdP                      |
|                                                          |
| selected TCP port -> nginx :33074 (Cloudron TLS cert)    |
|   native HTTP/2 gRPC + relay/WebSocket                   |
|                          |                               |
|                          v                               |
|                 netbird-server :80                       |
|          Management + Signal + Relay + embedded IdP      |
|                                                          |
| selected UDP port -> embedded STUN                       |
| PostgreSQL addon -> persistent application data          |
+----------------------------------------------------------+
```

## Configuration

All configuration is generated at runtime by `start.sh`. There are no config files to edit manually -- the app reads Cloudron environment variables, writes `config.yaml` and `nginx.conf`, and substitutes those values into an ephemeral dashboard export on each start.

### Database

Uses Cloudron's PostgreSQL addon automatically. No manual database setup required.

### Identity Provider

**Built-in**: NetBird's embedded IdP (Dex) handles initial setup and local user management. The `/setup` page creates the first admin account.

**Optional**: Cloudron SSO or any OIDC provider can be added via the dashboard after initial setup. Multiple providers can coexist. See [Adding Cloudron SSO](#adding-cloudron-sso-optional).

### Health Check

The manifest uses `/oauth2/.well-known/openid-configuration` as the health check
endpoint, served through the internal nginx proxy on port 8080. The combined
server also exposes a health endpoint on port 9000, which is not routed through
nginx.

### Persistent Data

All persistent data is stored in `/app/data/` (Cloudron's `localstorage` addon) and included in Cloudron backups:

| Path | Contents |
|------|----------|
| `/app/data/config/config.yaml` | Combined server configuration (regenerated on each start) |
| `/app/data/config/nginx.conf` | Internal nginx configuration (regenerated on each start) |
| `/app/data/config/.encryption_key` | Database encryption key (generated on first run, persisted) |
| `/app/data/config/.auth_secret` | Relay authentication secret (generated on first run, persisted) |
| `/app/data/netbird/` | Server state and data |
| `/app/data/.initialized` | First-run marker file |

The encryption key encrypts setup keys and API tokens at rest in PostgreSQL. Both `.encryption_key` and `.auth_secret` are included in Cloudron backups. **Do not lose them** -- losing the encryption key means regenerating all setup keys and API tokens, while losing the auth secret may disrupt relay server authentication.

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

#### Local container smoke check

The optional smoke check requires Python 3 and a running Docker engine. Build
the linux/amd64 candidate and pull the pinned PostgreSQL 16 fixture first:

```bash
docker build --platform linux/amd64 -t netbird-smoke:candidate .
docker pull postgres@sha256:33f923b05f64ca54ac4401c01126a6b92afe839a0aa0a52bc5aeb5cc958e5f20
python3 test/runtime-smoke.py --image netbird-smoke:candidate
```

The runner never pulls a candidate automatically. It uses disposable labeled
containers, a network, application-data and certificate fixture volumes, with no
published host ports or TTY. Runtime containers are limited to 512 MB and two
CPUs. The app has a read-only root filesystem and writable `/run`, `/tmp`, and
`/app/data`.
Outbound access is needed for NetBird's geolocation database download.

Fresh startup and restart must pass the manifest health check, setup/config
requests, dedicated TLS listener and HTTP/2 negotiation checks, stable
parent/child UID checks, database initialization, and persisted secret/data
checks. Raw logs,
credentials, and secret fingerprints are withheld.
The default test deadline is 180 seconds (`--timeout` adjusts it), plus up to 60
seconds for ownership-checked cleanup on success, failure, or SIGINT/SIGTERM.
Cleanup failures print the exact owned resource names and label to inspect;
remove only those resources after confirming that label. SIGKILL or a stopped
Docker daemon can prevent cleanup. Never use a broad Docker prune as recovery.

This is not a live Cloudron, backup/restore, VPN-client, or SSO test. The fast
`bash test/package-test.sh` remains independent of Docker. The only supported
runtime target is explicit `--target local-docker`; it never discovers a remote
host or defaults to a production instance. See
[`test/QUALIFICATION.md`](test/QUALIFICATION.md) for the evidence-indexed
qualification matrix, maintenance consent boundaries, and open live-instance
cases.

- [ ] Fresh install completes without errors
- [ ] Dashboard loads at app URL
- [ ] `/setup` page appears on first run (no users exist)
- [ ] Admin account creation works via setup page
- [ ] Login with created credentials works
- [ ] Setup key creation works in dashboard
- [ ] Client connects with a setup key and selected TCP management port
- [ ] Peers can ping each other through the mesh
- [ ] Peers behind NAT connect via relay
- [ ] Native HTTP/2 gRPC works on the dedicated port (signal + management)
- [ ] WebSocket connections work (relay + ws-proxy)
- [ ] App survives restart (`cloudron restart --app netbird`)
- [ ] Backup/restore preserves all state
- [ ] Memory stays within 512 MB limit
- [ ] Selected STUN UDP port is accessible from clients
- [ ] (Optional) Cloudron SSO can be added as external IdP via dashboard

### Repository Automation Dashboard

The pinned supervisor health issue reports repository-development activity; it
is not the deployed NetBird application's health check. Its refresh can pause
while the repository has no active pull requests, assigned issues,
auto-dispatch work, or workers. Before treating an old `last_refresh:` value as
a scheduler or application failure, confirm that the stats launch agent is
loaded and that recent stats-log entries end with a successful health-issue
update.

## File Structure

```text
cloudron-netbird-app/
  CloudronManifest.json    # Cloudron app metadata and addon requirements
  Dockerfile               # Build instructions (copies netbird-server + dashboard)
  start.sh                 # Runtime entry point (config generation, process launch)
  supervisord.conf         # Process management (nginx + netbird-server)
  logo.png                 # App icon (256x256)
  PACKAGING-NOTES.md       # Architecture decisions, lessons learned, testing plan
  CHANGELOG.md             # Version history
  CONTRIBUTING.md          # Contribution guidelines
  LICENSE                  # MIT
  .editorconfig            # Editor formatting rules
```

## Known Limitations

1. **Native client port**: Clients must include the selected TCP port in
   `--management-url`. The normal app URL remains the dashboard and REST API.
2. **STUN port**: The selected UDP port must be directly accessible. Cloudron
   TURN cannot replace NetBird's embedded relay/STUN because its shared-secret
   credentials do not map to NetBird's static external-server configuration.
3. **Reverse Proxy clusters are not supported**: NetBird's [Reverse
   Proxy](https://docs.netbird.io/manage/reverse-proxy) component must terminate
   TLS for public service domains on port 443. Cloudron owns host port 443 and
   does not provide per-app TLS passthrough. See the [TLS passthrough feature
   request](https://forum.cloudron.io/topic/15109/tls-passthrough-option-for-apps-requiring-end-to-end-tls).
   Core mesh VPN functionality remains available.
4. **Single account mode**: All users join the same network. This suits most
   self-hosted deployments.
5. **Live qualification remains in progress**: Community testing has verified
   first-run setup and dashboard login. The dedicated native transport still
   needs confirmation on a real Cloudron instance.

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
3. **gRPC/WebSocket testing** -- verify signal, management, and relay on the
   dedicated TLS port
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
