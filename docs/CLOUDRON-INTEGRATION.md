# Cloudron identity, entitlement and VPN integration

## Status and scope

Cloudron 10.0.5 and NetBird 0.79.0 are the inspected integration baseline.
Package 2.3.0 adds an [opt-in access reconciler](ACCESS-SYNC.md) alongside optional
Cloudron SSO and a separately configured public proxy. The operator must configure
credentials, state and any schedule explicitly. App updates do not enable it.
Native Cloudron VPN-provider registration remains unsupported. Normal no-change
reconciliation was observed; live revocation scenarios were not run for this
release. The requirements below are not claims of complete production qualification.

## Four independent boundaries

1. Cloudron dashboard visibility and effective app access.
2. Cloudron authentication through the app addon or a custom OIDC client.
3. NetBird account approval, API authorization, peer ownership and mesh policy.
4. Cloudron VPN-protected application ingress.

Configuring one does not automatically enforce the others. In particular, a
custom OIDC client does not inherit the NetBird app's Cloudron access list.
Keep NetBird new-user approval enabled until entitlement enforcement is verified.

## User and group entitlement contract

Cloudron exposes paginated `GET /api/v1/users` and
`GET /api/v1/users/:userId/apps`. The latter delegates to
`apps.listAccessibleWithReason` and reports effective access, including:

- Direct user access and membership of an allowed Cloudron group.
- Unrestricted all-users app access.
- Cloudron administrator/owner and app-operator privileges, including operator
  groups. These can grant access even outside the ordinary app access list.

Use that authoritative endpoint rather than reimplementing selected ACL cases.
Check the user's `active` flag separately. An incomplete page, failed request or
missing field is not an authoritative empty directory or permission grant.
Cloudron administration does not imply a NetBird administrative role.

Cloudron 10.0.5 API-token scope `{"*":"r"}` is read-only across APIs, not scoped
to a particular app or path. Restrict source IPs, expiry, storage and operation
paths; do not describe it as an app-scoped token. Do not persist an interactive
owner token as an unattended synchronization credential.

## Stable identity and username reuse

Cloudron `oidcserver.getClaims` emits the username as `sub`, not the immutable
Cloudron user ID. NetBird's embedded Dex encodes the upstream subject together
with the connector ID into the NetBird user ID; its `idp_id` identifies the
connector, not the Cloudron user.

Bind issuer, connector, upstream subject and immutable Cloudron user ID together.
Preserve ownership records and deletion tombstones. Never join by email, adopt a
foreign connector, silently merge the embedded and external accounts, or reassign
an old identity when someone recreates a username. Bootstrap/adoption must be
explicit; loss of synchronization state requires reconciliation, not blind reset.

## Revocation and existing devices

The intended policy is to revoke both NetBird application access and the
affected user's device access when Cloudron entitlement is removed.

NetBird's user update API accepts `is_blocked`, `role` and `auto_groups`.
Preserve the existing role and groups. In 0.79.0, blocking a user calls
`expireAndUpdatePeers`, expires user-owned peers and disconnects their management
sessions. This path must be verified with actual previously working peer traffic,
not just an HTTP success response or a blocked-user flag.

Important exceptions:

- NetBird explicitly refuses to block the owner user. Keep the embedded owner as
  independent emergency recovery, not as the normal device-enrolment identity.
- Devices enrolled through that owner do not become SSO-owned merely because the
  same person or email signs into Cloudron. The inspected peer-update API has no
  ownership-transfer field. Re-enrol through SSO one device at a time, with an
  approved reconnect window and a verified recovery path.
- Setup-key peers have no user ownership and are skipped by user-expiration
  logic. Require a separately approved service-device policy; never infer their
  owner from a name or group label.
- Polling has measurable latency. State the interval, API-processing time and
  outage/watchdog behavior. Do not promise instantaneous revocation or guaranteed
  removal of offline peer keys while the control plane is unreachable.

Do not delete devices, rewrite database ownership, disable the recovery owner or
change unrelated mesh policies as an undocumented shortcut.

## Native Cloudron VPN protection: upstream blocker

Inspected in Cloudron 10.0.5, 10.1.6 and `platform/box` `master` at `c36346e`
(2026-11-13). `src/network.js:setVpnAccessConfig` rejects any app whose manifest
ID differs from `constants.OPENVPN_APP_APPSTORE_ID`, with the diagnostic
`vpnAppId must be an OpenVPN app`. The dashboard (`VpnAccess.vue`, `Access.vue`)
filters on the same ID. There is no generic VPN-provider API or manifest
capability; manifest capabilities are limited to `net_admin`, `mlock`, `ping` and
`vaapi`.

The rest of the contract is provider-neutral:

- `src/reverseproxy.js:getVpnAccessIngressData` emits nginx `allow` rules for the
  selected VPN container's IPv4/IPv6 addresses (plus the protected app's own
  container) on apps marked `requiresVpn`, then `deny all`.
- The app bridge's `GET /vpn-access-config` returns protected FQDNs, their DNS
  domains and the tunnel-routing mode, but only to the selected VPN container.
- Uninstalling the selected app clears the policy.

So the selection check is the only OpenVPN-specific part. A NetBird management
server alone is still not a routing peer and does not originate users' mesh
traffic from its container. Relabelling the package cannot satisfy the contract.

### Proposed upstream change

A small Cloudron patch would accept any app with the `net_admin` capability as
the VPN app. The admin still selects it explicitly. It would also block only the
selected VPN app, rather than every OpenVPN app, from requiring VPN access.
Progress and the forum proposal are tracked in issue #149. This repository does
not carry a copy of Cloudron's source.

If that lands, the NetBird side needs a **separate routing-peer app**, not a
mode of this package. This container hosts public services such as the bundled
reverse proxy, and its egress must never be trusted as VPN ingress. The routing
peer would run a NetBird client with `net_admin`, masquerade peer traffic to the
Cloudron host and expose only the protected FQDNs as NetBird network resources.
NetBird access policies would then grant per-group access, which is finer than
Cloudron's single VPN.

### Interim option: allowlisted external routing peer

`master` also adds a system-wide VPN-protection allowlist of IPs/CIDRs (not in
10.1.6). Once it ships, a NetBird routing peer **outside** the Cloudron host with
a dedicated static egress address can reach protected apps without the upstream
patch: allowlist that /32 (and its IPv6 /128), and route the Cloudron addresses
through it. Constraints:

- Everything that egresses from that address is trusted, so dedicate it to the
  routing peer.
- Cloudron rejects Docker-network entries (`172.18.0.0/16`,
  `fd00:c107:d509::/64`), so a routing peer in a Cloudron app container cannot
  use the allowlist.
- Route both address families or remove the unrouted record; otherwise clients
  bypass the peer and get the VPN-required page.

### Verification before any support claim

A supported integration needs a qualified routing-peer path, source identity,
DNS, IPv4/IPv6 and custom/full tunnel routing behavior. Both VPN-app entitlement
and target-app authentication/ACLs remain relevant. Test public denial, entitled
peer access, removed user/group access, provider failure and isolation before
enabling it.

Never impersonate OpenVPN, edit live platform code/database, widen trusted source
subnets or replace Cloudron-generated nginx rules. Keep this requirement open
until the platform supports it and the actual protected-app path passes tests.

## Evidence sources

- Installed Cloudron: `src/apps.js` (`canAccess`, `getAccessInfo`),
  `src/routes/users.js`, `src/api-tokens.js`, `src/oidcserver.js`,
  `src/network.js`, `src/reverseproxy.js`.
- Cloudron `platform/box` `v10.1.6` and `master` `c36346e`: `src/network.js`,
  `src/apps.js` (`setVpnAccess`), `src/app-bridge.js` (`vpnAccessConfig`),
  `src/reverseproxy.js`, `src/nginxconfig.ejs`, `src/docker.js` (capabilities),
  `dashboard/src/components/network/VpnAccess.vue` and
  `dashboard/src/components/app/Access.vue`; `@cloudron/manifest-format` 6.8.0.
- NetBird tag `v0.79.0`: `idp/dex/provider.go`, `management/server/user.go`,
  `management/server/http/handlers/users/users_handler.go` and
  `shared/management/http/api/openapi.yml`.

Reverify these contracts on version changes; do not treat internal source
inspection as authorization to mutate platform internals.
