# Multiple NetBird instances on one Cloudron

Start each organisation with a private mesh. Public reverse-proxy ingress is a
separate, optional decision; it is not required for remote access between peers.
Verify the installed package version and assigned ports before provisioning.

## IP and port allocation

| Requirement | Address allocation | Support boundary |
|---|---|---|
| Independent private mesh, dashboard, native clients and relay/STUN | Existing primary IPv4; no additional Floating IP per app | Unique app hostname, native TCP port and STUN UDP port per instance |
| Several public HTTPS services within one NetBird instance | One additional public IPv4 for that proxy ingress | Multiple service subdomains share the proxy's port 443 |
| Public HTTPS proxies for several independent instances | Separate ingress IPv4s are the simpler design | Not supported by repeatedly running the current single-instance host helper |
| Several independent proxies sharing one ingress IPv4 | Possible future TLS-SNI routing design | Not implemented or qualified by this package |

Cloudron shares primary-IP HTTPS port 443 between dashboards by hostname. Each
app still needs distinct selected native TCP and STUN UDP ports; use those exact
ports in clients and firewall configuration. Fixed internal container ports can
repeat across isolated containers. Cloudron TURN is not NetBird's relay/STUN.

On Hetzner Cloud the additional ingress address is a Floating IPv4. Do not buy
another address for a private-only instance, or an address for every published
web service. DNS must follow the chosen topology; the current IPv4 proxy mode
uses DNS-only A records and does not support adding proxy AAAA records blindly.

## The host helper is single-instance

`scripts/netbird-ingress.py` uses fixed host resources: `/etc/netbird-ingress`,
the `netbird_ingress` nftables table, `netbird-ingress-managed` INPUT-rule tag,
the interface's `:nb` address label, a shared lock and fixed systemd unit names.
It intentionally rejects a different existing configuration. Merely obtaining
another IP or changing the two port arguments does not make another deployment
safe. Do not rename only a unit, delete the existing state, or overwrite the
configuration to force reuse.

Multi-instance support would need instance-scoped config, locks, firewall state,
units, address labels, snapshots, port reservation, reconciliation and cleanup.
Each instance must preserve its own dedicated PROXY-v2 source identity/trust and
must not interrupt another instance during install, restart, rollback or removal.
Until that is implemented and tested, keep additional apps private-only or use a
separately reviewed ingress deployment. Do not expand the trusted CIDR to the
shared Docker bridge or disable backend guards to make a second proxy work.

A shared-IP design would need a TLS-passthrough SNI gateway, explicit per-brand
domain routing, certificate/TLS-ALPN-01 challenge compatibility, trustworthy
client-IP forwarding and rejection of unknown names. NetBird proxies would still
terminate TLS independently. It adds a shared ingress failure/trust boundary and
requires isolated verification; it is not an installation recipe today.

## Organisation and endpoint security

- Use groups and least-privilege policies within one trusted organisation. Check
  effective access: a broad all-to-all policy can defeat a narrow intended rule.
- Prefer separate instances for independent clients/brands with different admins,
  identity ownership or handover requirements. Keep setup keys, proxy tokens,
  identity-provider configuration and backup access scoped to each organisation.
- Separate instances do not federate. Shared SSO identities do not join meshes.
  Verify client profile/version support; do not assume simultaneous connections
  to several instances. Plan mesh/LAN address overlap before any gateway or
  subnet routing; a dedicated administration VM per organisation may be simpler.
- Keep SSH, Screen Sharing, SMB and private administration on the mesh. Their OS
  services still need allowed users, authentication, firewalls and mesh policies.
  No home-router port forwarding is needed for ordinary peer access. Test from
  mobile data or another off-LAN connection, not just the same Wi-Fi.
- Account for sleep, FileVault preboot unlock, automatic startup and mobile VPN
  conflicts/background limits. NetBird does not guarantee remote wake or replace
  a desktop/file client. Subnet routing and exit nodes are separate opt-in scopes.
- Publish only deliberately selected web services. The proxy terminates HTTPS,
  can see HTTP contents and does not inherit Cloudron's HTTP protections. Apply
  service authentication and application security; preserve webhook signatures.
- Separate Cloudron apps still share the VPS root administrator, infrastructure
  and failure domain. Use separate hosts when stronger client isolation or
  independent operational ownership is required.

## Verification and operational limits

Record each app's domain, assigned ports, groups, owners and backup/recovery plan
without recording credentials. App backups do not include provider IP allocation
or host ingress configuration; preserve those separately. Have recovery access
before host network changes and avoid concurrent port provisioning.

Use [REVERSE-PROXY.md](REVERSE-PROXY.md) for the current one-proxy topology and
[test/QUALIFICATION.md](test/QUALIFICATION.md) for evidence boundaries. Passing a
single-instance live smoke test is not proof of multi-instance isolation, full
restore, certificate renewal, host reboot or platform-upgrade behaviour. Those
operations require their own bounded tests and maintenance approval. This guide
does not authorise new IP purchases, network changes or shared-service restarts.
