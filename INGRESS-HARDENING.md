# Public HTTPS ingress protection

The optional proxy has its own protection path; it is not an unfiltered port and
does not copy Cloudron's generated firewall/nginx rules. Keep ordinary SSH,
desktop/file access and administration private on the mesh.

## Default protection profile

The host helper generates a TLS-passthrough HAProxy frontend with:

- 1,024 total connections, 64 concurrent connections per source IPv4 and 60 new
  connections per source IPv4 per 10 seconds. Shared NATs may need a reviewed
  higher per-source limit; these are connection limits, not HTTP request limits.
- Five-second backend connect timeout and one-hour idle timeouts for long-lived
  public connections. Native NetBird TCP and STUN listeners are not rate-limited
  by this frontend.
- A bounded IPv4 denylist in the owned nftables table, evaluated before public
  ingress acceptance and established-connection allowance. It only targets IP2
  on the configured external interface; primary-IP Cloudron traffic is unchanged.
- Existing host-only backend guards and dedicated `/32` PROXY-v2 identity trust.
  Do not widen trust to a shared Docker subnet or bypass the guards.

Upstream NetBird 0.79.0's ACME host policy only issues for registered proxy domains.
Unknown-domain rejection belongs there, after SNI routing; do not insert an
unqualified TLS terminator or turn on a CDN proxy that breaks TLS-ALPN-01.

## Install or update host protection explicitly

An app image update does **not** update host files. Follow `REVERSE-PROXY.md` to
install the matching helper using the existing exact IP/interface/port settings.
Preserve the original host snapshot and current configuration first. Upgrading
the unit requires one dedicated bridge restart to create its private runtime
directory and statistics socket. Subsequent protection changes use graceful
reload; do not restart shared Docker/nginx/Cloudron.

With the managed bridge active, apply only protection fields:

```bash
python3 /etc/netbird-ingress/netbird-ingress.py protect \
  --connections-per-ip 64 --connections-per-10s 60 --max-connections 1024
python3 /etc/netbird-ingress/netbird-ingress.py protect --deny-cidr 203.0.113.0/24
python3 /etc/netbird-ingress/netbird-ingress.py protect --clear-deny-list
python3 /etc/netbird-ingress/netbird-ingress.py report
```

The example CIDR is documentation-only: use an explicitly reviewed real list,
not this example in production. `--deny-cidr` replaces the list (repeat it for
multiple entries); omitting it preserves the list. Validation rejects IPv6,
invalid/oversized lists and entries covering primary/trusted host IPs. No remote
feed is fetched automatically. Keep source ownership, freshness and rollback
policy explicit before automating a feed.

`protect` cannot change network identity. It validates HAProxy/nft syntax before
applying, saves `protection-before.json`, updates only owned files/rules and
reloads only `netbird-tcp-bridge.service`. A synchronous apply failure restores
the previous owned configuration and attempts recovery. An abrupt host/process
failure still needs operator recovery; this is not a cross-service transaction.

## Monitoring and HTTP-layer controls

`report` verifies managed rules/configuration, prints aggregate packet and HAProxy
connection counters and service status, exiting nonzero on unhealthy state.
HAProxy counters use a root-only Unix socket with read-only CLI privileges.
There is no public listener. Counters reset on worker replacement/restart;
monitors must handle resets. Feed the result to an existing monitor.
Logs go to the dedicated systemd journal without HTTP request bodies
or credentials. Early
connection ACL rejections need not produce session logs: use `denied_connections`
for that evidence rather than inferring acceptance from missing rejection logs.
The existing reconciliation timer records failures in systemd; configure actual
notifications in the operator's chosen monitoring system. No email/webhook alert
destination or external telemetry service is silently enabled by this package.

After TLS termination, retain NetBird service authentication/IP restrictions and
the target application's own security. The pinned upstream proxy also exposes
optional `NB_PROXY_CROWDSEC_API_URL` and `NB_PROXY_CROWDSEC_API_KEY` integration;
verify the selected service's enforcement settings and use a trusted private
LAPI plus securely injected credentials before enabling it. This package does
not install CrowdSec, subscribe to a reputation feed or claim a full HTTP WAF.

If an application needs HTTP rate limits, payload inspection or a WAF, implement
them after TLS termination or design a separately verified edge topology. A TCP
firewall cannot inspect encrypted HTTP, and host limits cannot stop a DDoS that
saturates the upstream link. Verify provider-side filtering for the ingress IP.

Test normal HTTPS, authentication negatives, source restrictions, unknown-host
rejection, bounded connection rejection and unchanged native peers after changes.
Retain the separate maintenance gates in `test/QUALIFICATION.md` for disruptive
restore/reboot/platform-upgrade and broader load/isolation qualification.
