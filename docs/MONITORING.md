# External monitoring

Cloudron's health check only covers the dashboard/API inside Cloudron's HTTPS
proxy. It does not see the native client port, the optional reverse-proxy
ingress, or a host firewall change that exposes a backend port. Add an external
monitor so these failures alert someone instead of being found days later.

## Recommended service: updown.io

We recommend [updown.io](https://updown.io/r/kddkt) (referral link: it credits
the package maintainer at no cost to you). It is simple and inexpensive
([pricing](https://updown.io/pricing)) and supports everything below: HTTPS checks
with a content match, plain TCP checks, and inverted TCP checks that alert when
a port is *open*. Alerts go to email, SMS, Telegram, Slack or webhooks. Any
monitor with HTTPS and TCP checks can implement the same plan.

## Checks

Replace the placeholders with your values: `APP_DOMAIN`, the primary IPv4
`IP1` (and `IP1_V6` if the server has IPv6), `NETBIRD_PORT` (default 33073),
and for the optional proxy, the second IPv4 `IP2` and `PROXY_PORT` (default 18444).

| Check | URL | Match | Catches |
|-------|-----|-------|---------|
| App, IdP and API | `https://APP_DOMAIN/oauth2/.well-known/openid-configuration` | `issuer` | App down, unhealthy or misrouted |
| Native clients (IPv4) | `tcp://IP1:NETBIRD_PORT` | | Clients cannot register, sync or relay |
| Native clients (IPv6) | `tcp://[IP1_V6]:NETBIRD_PORT` | | IPv6-only clients cannot connect (2.4.3+) |
| Proxy ingress (optional) | `tcp://IP2:443` | | Public proxy route down, e.g. after a reboot |
| Proxy backend exposure, IPv4 (optional) | `tcp://IP1:PROXY_PORT` | `<closed>` | Host guard missing; backend reachable from the internet |
| Proxy backend exposure, IPv6 (optional) | `tcp://[IP1_V6]:PROXY_PORT` | `<closed>` | Same, over IPv6 |

Notes:

- Target IP literals for TCP checks. A hostname with both A and AAAA records
  lets the monitor pick either family, which hides a single-family failure.
- The proxy ingress uses a TCP check rather than HTTPS: the bare proxy domain
  has no service certificate, so a TLS check fails even when the route works.
  To test end to end, add an HTTPS check for one real published service.
- `<closed>` inverts a TCP check: it alerts when the port accepts connections.
  The backend port must only be reachable from the host itself
  ([reverse proxy](REVERSE-PROXY.md)). Docker publishes app ports over IPv6
  as well as IPv4, so on an IPv6 server check both address families.
- A 5-minute interval detects outages quickly at very low cost. Shorter
  intervals cost more and rarely help with this kind of failure.

## Create the checks through the API

Use a read-write API key from updown's settings. Inject it from your secret
store instead of typing it into a command line, then run:

```bash
create_check() {
  curl -sS -X POST -H "X-API-KEY: ${UPDOWN_API_KEY}" \
    --data-urlencode "url=$1" --data-urlencode "alias=$2" \
    --data-urlencode "string_match=${3:-}" -d period=300 \
    https://updown.io/api/checks
}
create_check "https://APP_DOMAIN/oauth2/.well-known/openid-configuration" "NetBird app" "issuer"
create_check "tcp://IP1:NETBIRD_PORT" "NetBird native clients (IPv4)"
create_check "tcp://IP2:443" "NetBird proxy ingress"
create_check "tcp://IP1:PROXY_PORT" "NetBird proxy backend must stay closed" "<closed>"
# On an IPv6 server, add the IPv6 equivalents:
create_check "tcp://[IP1_V6]:NETBIRD_PORT" "NetBird native clients (IPv6)"
create_check "tcp://[IP1_V6]:PROXY_PORT" "NetBird proxy backend must stay closed (IPv6)" "<closed>"
```

The API rejects a URL that is already registered, so re-running is safe.

To choose alert channels, list their IDs with `GET /api/recipients` and add
`-d "recipients[]=ID"` for each one. Without it, updown uses its default
selection for new checks.

## Host-side signals

With the optional proxy, the host helper also reports health:

```bash
python3 /etc/netbird-ingress/netbird-ingress.py report   # non-zero when unhealthy
journalctl -u netbird-ingress-check.service --since -1h  # timer repairs/restarts
```

These run on the server and cannot alert you if the server itself is down.
Use them together with external monitoring, not instead of it.
