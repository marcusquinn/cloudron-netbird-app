# Optional single-VPS Reverse Proxy

Run commands from the repository root. This public ingress is not Cloudron's
native VPN-protection feature; see [integration boundaries](CLOUDRON-INTEGRATION.md).

The package bundles `netbird-proxy` 0.79.0. This is an opt-in,
administrator-managed deployment, not a Cloudron platform feature. No second
VPS is required, but a **second public IPv4** and root SSH access are required.
For Hetzner Cloud, use a Floating IPv4, not another Primary IPv4.

Apply the matching [public-ingress protection profile](INGRESS-HARDENING.md).
An app update does not update the separately installed host helper or its rules.

**Multiple apps:** private-only instances need no additional IP, and one proxy IP
can serve many HTTPS services within one instance. This host helper is currently
single-instance: do not rerun it for another app or overwrite its configuration.
Separate-IP and shared-SNI designs need further implementation and qualification;
see [multi-instance setup and security](MULTI-INSTANCE.md).

## Boundaries

```text
IP1:443 -> Cloudron nginx -> dashboard/API/OIDC (unchanged)
IP1:native-port -> app nginx TLS -> management/signal/relay (unchanged)
IP2:443 -> one DNAT -> IP2:18443 host HAProxy (no TLS termination)
        -> new TCP connection -> IP1:18444 Cloudron port -> app proxy:8443
        -> WireGuard peer -> target HTTP service
```

NetBird terminates public-service TLS and obtains certificates with TLS-ALPN-01.
There is no dependency on a fixed container IP or sequential Docker DNAT.

The helper owns one nftables table, one tagged INPUT exception, one secondary
address labelled `<interface>:nb`, and its own systemd units. It never changes
the default route, primary IP, Cloudron nginx, or global firewall policies.

Cloudron masquerades intra-bridge traffic. Accordingly, the bridge binds its
outgoing source to IP2, and an earlier SNAT rule preserves that identity. Trust
**IP2/32**, not the shared Docker gateway/subnet, for PROXY protocol. Incoming
packets spoofing IP2 are dropped. NetBird receives the actual external client IP
from HAProxy's PROXY v2 header; client-supplied forwarding headers cannot bypass
NetBird's IP restrictions (covered by the live smoke check).

## Setup

1. Assign the additional address at the provider. Verify your actual primary IP,
   interface and chosen ports. Have provider rescue/console access available.
2. Install HAProxy and nftables from the OS repositories. Prevent the stock
    HAProxy service from auto-starting: this setup uses `netbird-tcp-bridge.service`
    instead. Do not restart unrelated services as part of package installation.
    Both ingress ports must be unused on **all host addresses**, not only IP2.
    First installation/activation checks TCP listeners and Docker port bindings
    (including stopped containers), requiring working `ss` and Docker access.
    Do not enable the app proxy port until after the guard is active (step 6).
    The retained guard reserves these ports: never assign them to another app,
    even while the bridge is stopped. Avoid concurrent port provisioning during
    installation; these checks cannot lock Cloudron or another administrator.
3. Copy `scripts/netbird-ingress.py` to the host and run its `render` action for
   review, then `install --primary-ip IP1 --floating-ip IP2 --interface IFACE`.
   The installer saves a private pre-change network/firewall snapshot under
   `/etc/netbird-ingress/before.json`; it does **not** activate networking.
4. Schedule a short automatic rollback before first activation:

   ```sh
   systemd-run --unit=netbird-ingress-rollback --on-active=5m \
     systemctl stop netbird-tcp-bridge.service netbird-ingress.service
   systemctl start netbird-ingress.service netbird-tcp-bridge.service
   python3 /etc/netbird-ingress/netbird-ingress.py check
   ```

5. From another machine, verify IP1's dashboard/SSH are unchanged, IP2:443 opens,
   IP2:80/22 and direct 18443/18444 access on all host addresses are blocked.
   Only after this passes, cancel the rollback timer and enable persistence:

   ```sh
   systemctl stop netbird-ingress-rollback.timer
   systemctl enable netbird-ingress.service netbird-tcp-bridge.service
   systemctl enable --now netbird-ingress-check.timer
   ```

6. Install/update the Cloudron app, explicitly binding `NETBIRD_PORT` and
   `PROXY_PORT=18444`. STUN uses Cloudron's platform service by default; bind
   `STUN_PORT` only if you want NetBird's own STUN server, and never on 3478
   while Cloudron TURN uses it. The proxy ingress forwards TCP only and does not
   affect STUN UDP. Budget at least 1 GiB for initial proxy qualification, then measure your load.
7. Set these app environment variables as **separate arguments**, not a single
   space-containing `KEY=value` argument:

   ```sh
   cloudron env set --app APP_ID \
     NETBIRD_PROXY_DOMAIN=YOUR_PROXY_DOMAIN \
     NETBIRD_PROXY_TRUSTED_CIDR=IP2/32 \
     NETBIRD_SETUP_LOCAL_ONLY=true
   ```

   For unattended fresh installation, pass each variable using its own `--env`
   option at install time. `NETBIRD_SETUP_LOCAL_ONLY=true` must be active before
   the first startup. Initialize the owner through the app-local API/terminal;
   `scripts/initialize-netbird.py` automates this with credentials in gopass.
8. Point the proxy domain and its wildcard A record at IP2. Use DNS-only records,
   not a TLS-terminating CDN. Do not publish proxy AAAA records in this IPv4 mode.
9. The cluster appears in NetBird automatically. Enrol a peer and create an HTTPS
   service targeting its HTTP port. No custom arbitrary TCP/UDP services are
   advertised by this deployment.

Both `PROXY_PORT` and `NETBIRD_PROXY_DOMAIN` must be set for the bundled proxy to
start. Missing configuration disables it without affecting the core services.
Invalid domain/trust configuration exits with code 78 (no restart storm).

## Credentials, health and backup

- `/app/data/proxy/token`: dedicated proxy token, created once, mode 0600.
- `/app/data/proxy/certs`: ACME account/certificate storage; backed up with the app.
- `127.0.0.1:8445/healthz`: private full health; `/healthz/ready` and `/healthz/live`
  are also available. Port 8080 is already used by app nginx.
- Cloudron app backups include PostgreSQL and `/app/data`, **not** the provider's
  Floating IP or host `/etc/netbird-ingress`. Preserve the host config separately
  and reapply it before enabling PROXY_PORT after a server migration.
- Revoke/rotate a compromised proxy token using NetBird's administrative tools;
  remove the old stored token only as part of an explicit rotation procedure.
- The optional SSH session helper uses Cloudron's installed one-use owner-login
  and OIDC/PKCE, without changing the ordinary owner password. It requires root
  authority and replaces any existing support ghost-login configuration. Do not
  use while another support login is pending. Revoke its CLI session afterward.

## Recovery and limitations

The 30-second timer detects changes to this helper's rules and INPUT ordering
and reapplies only its own state while the ingress service is active. It respects
an intentional service stop. A *failed* ingress or bridge unit is not a stop:
the timer queues a restart. nftables state is not persisted across reboot, so
the boot-time `up` re-applies the helper's reviewed ports even though Docker
already publishes `PROXY_PORT`; only first activation insists both ports are
unused. After first activation `up` restores the guard *before* its readiness
checks, so a failed preflight or HAProxy check (for example after an OS upgrade)
leaves the backend port guarded and the unit failed, not exposed. The timer's
repair of a failed unit restores the guard in-process before queueing the
restart; if restoring fails, the check service fails. Docker can publish the
backend port a few seconds before the guard returns at boot. When a timer run
restores the guard, any longer gap ends about 90 seconds after boot; repeated
restore failures (for example a broken `nft`) extend it, so monitor
`netbird-ingress-check.service`. A missing INPUT allowance or NAT rule fails closed
while the separate guard remains intact. No software can promise that isolation
survives an administrator flushing the entire firewall; do not do so.

Stop with `systemctl stop netbird-tcp-bridge.service netbird-ingress.service`.
This removes only the labelled secondary address and tagged INPUT allowance.
The backend guard deliberately remains while the Cloudron app port is exposed.
Disable PROXY_PORT before uninstalling the guard. Changing the app's published
port requires corresponding reviewed host configuration changes.

This ingress bypasses Cloudron's normal HTTP proxy and does not automatically
inherit its HTTP protections or IP blocklist. Apply NetBird service authentication
and access restrictions. Protect the host as usual. Source IP identity relies on
the host firewall: a host-root compromise is outside this isolation boundary.

Live qualification covers native registration, public ACME issuance, remote peer
traffic, header authentication, and forwarded-IP spoof rejection. Run
`test/live-proxy-smoke.py` explicitly with a short-lived API session to repeat it;
the test deletes its own services, setup key, peer and labelled Docker containers.
App update/restart and backups are separate checks. One maintenance run covered
host reboots, a Cloudron upgrade and an Ubuntu 24.04 -> 26.04 release upgrade
with this helper installed (see the execution record in
[test/QUALIFICATION.md](../test/QUALIFICATION.md)). That run did not cover
peer-to-peer tunnel establishment, Docker-only restart, restore, or end-to-end
proxied traffic after a reboot; these remain unexecuted. Do not infer them from
passing app-level tests or from the live qualification above.

### Host OS release upgrades

`/etc/netbird-ingress` is host configuration, so an Ubuntu release upgrade
replaces HAProxy and nftables underneath it (24.04 -> 26.04 moves HAProxy 2.8
to 3.2). Before the post-upgrade reboot, validate both with the new binaries:

```bash
python3 /etc/netbird-ingress/netbird-ingress.py check
nft --check -f /etc/netbird-ingress/rules.nft
```

Fix any failure before rebooting; otherwise the ingress service fails at boot.
After the reboot, run
`python3 /etc/netbird-ingress/netbird-ingress.py report`. The helper adds the
labelled secondary address itself, so it does not depend on the host's
ifupdown or netplan files. If `networking.service` fails after the upgrade
because a legacy cloud-init ifupdown file duplicates netplan's addresses, back
up and remove only the duplicate file. Do not touch the helper's address.
