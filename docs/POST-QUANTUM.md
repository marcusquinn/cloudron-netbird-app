# Post-quantum protection

Someone can record encrypted traffic today and keep it until a large quantum
computer can break the key exchange ("harvest now, decrypt later"). This guide
explains which NetBird traffic this package protects against that, which it
can't, and what operators can set.

## What is protected

| Traffic | Where | Post-quantum | Who controls it |
|---------|-------|--------------|-----------------|
| Client management, signal and relay | Native port (`NETBIRD_PORT`, default 33073) | Yes, enforced by default | This package |
| Dashboard, REST API and login | Port 443 | No | Cloudron host nginx |
| Device-to-device WireGuard tunnels | Peer to peer, or via the relay | Only with Rosenpass on both peers | Each device |

The relay forwards WireGuard packets it can't decrypt, so relayed tunnels get
the same protection as direct tunnels. Their transport to the relay also uses
the native port, which is post-quantum.

## Native client port: post-quantum only by default

From package 2.5.0 the native listener accepts only TLS 1.3 with the hybrid
`X25519MLKEM768` key exchange (ML-KEM-768 combined with X25519). The hybrid
stays secure as long as either part is unbroken.

Clients that support it:

- NetBird clients 0.61.0 or later on all platforms. They are built with Go 1.24
  or later, which offers `X25519MLKEM768` by default. NetBird doesn't override
  Go's TLS defaults.
- The bundled reverse proxy is unaffected; it connects over the in-container
  loopback.
- Browsers used for NetBird's in-dashboard browser client: Chrome and Edge 131+,
  Firefox 132+, Safari 26+.

Older clients fail the TLS handshake on the native port. Update them, or opt in
to classic key exchange for every client:

```sh
cloudron env set --app APP_ID NETBIRD_TLS_ALLOW_CLASSIC=true
```

The app restarts with TLS 1.2 and 1.3 and the groups `X25519MLKEM768`,
`X25519`, `prime256v1` and `secp384r1`. Clients that support ML-KEM still
prefer it. Remove the opt-in with `cloudron env unset --app APP_ID
NETBIRD_TLS_ALLOW_CLASSIC`. Any value other than `true` or `false` stops the app
from starting, with an error in the log.

Find clients that are too old before updating (needs a NetBird personal access
token in `NETBIRD_API_TOKEN`):

```sh
curl -fsS -H "Authorization: Token $NETBIRD_API_TOKEN" \
  https://netbird.example.com/api/peers |
  jq -r '.[] | select(.version | split(".") | map(tonumber? // 0) | . < [0, 61, 0])
    | [.name, .version, .os] | @tsv'
```

Verify the policy from any machine with OpenSSL 3.5 or later. Replace the host
and port with yours:

```sh
# Must connect and report the X25519MLKEM768 group
openssl s_client -connect netbird.example.com:33073 -groups X25519MLKEM768 -brief </dev/null
# Must fail with a handshake alert
openssl s_client -connect netbird.example.com:33073 -groups X25519 -brief </dev/null
```

## Dashboard, API and login on port 443

Port 443 is terminated by Cloudron's own nginx on the host, not by this
package. Its key exchange depends on the host's OpenSSL, because Cloudron's
nginx config sets no `ssl_ecdh_curve` and so inherits OpenSSL's default groups.
Measured on Cloudron 10.0.5 and 10.1.5:

| Host OS | OpenSSL | X25519MLKEM768 | SecP256r1MLKEM768 | X25519 / P-256 |
|---|---|---|---|---|
| Ubuntu 24.04 | 3.0 | refused | refused | accepted |
| Ubuntu 26.04 | 3.5.5 (nginx 1.28.3) | accepted, negotiated by default | refused | accepted |

So upgrading the host to Ubuntu 26.04 with Cloudron's
[upgrade guide](https://docs.cloudron.io/guides/upgrade-ubuntu-26) gives port 443
hybrid post-quantum key exchange without any package change. Classic clients
still connect. Check a host with the same `openssl s_client -groups` commands
as above, using port 443 and your dashboard hostname.

On a 24.04 host, exposure if this traffic is recorded and later decrypted:
dashboard sessions, login tokens (short-lived), API calls, and the setup-key
value when you create or copy a key in the dashboard. Device enrolment itself,
network maps, and signalling all use the native port.

To reduce the exposure on a host still running Ubuntu 24.04:

- Create setup keys as one-off or short-expiry keys, so a key decrypted later
  is already used or expired.
- Revoke personal access tokens you no longer need.

## Device tunnels: Rosenpass

WireGuard's own handshake is classic. NetBird can add
[Rosenpass](https://rosenpass.eu), which mixes a post-quantum key into each
tunnel. NetBird 0.80 has no server setting to require it, so each device has to
enable it. NetBird's CLI still labels Rosenpass experimental.

The modes:

- **Strict** (`--enable-rosenpass`): the device only builds tunnels with
  Rosenpass peers. A peer without Rosenpass can't connect to it.
- **Permissive** (`--enable-rosenpass --rosenpass-permissive`): post-quantum
  with Rosenpass peers, classic with the rest. Nothing breaks when a device
  without Rosenpass joins, so this package uses it by default.
- **Off** (the client default): classic WireGuard only.

The default setup command for a new device. With the default
`NETBIRD_CLIENT_ROSENPASS=permissive`, the dashboard's **Add Peer** dialog
shows the same flags; if you changed that setting, use the command the dialog
shows instead:

```sh
sudo netbird up \
  --setup-key YOUR_SETUP_KEY \
  --management-url https://netbird.example.com:33073 \
  --enable-rosenpass --rosenpass-permissive
```

For an already-connected device, run `sudo netbird down`, then
`sudo netbird up --enable-rosenpass --rosenpass-permissive`. The setting
persists. In the desktop app, turn on **Enable Quantum-Resistance** and
**Enable Permissive Mode** under the security settings' Encryption section.

### Dashboard command default

`NETBIRD_CLIENT_ROSENPASS` sets the flags in the dashboard's copyable
`netbird up` command:

| Value | Flags |
|-------|-------|
| `permissive` (default) | `--enable-rosenpass --rosenpass-permissive` |
| `strict` | `--enable-rosenpass` |
| `off` | none |

```sh
cloudron env set --app APP_ID NETBIRD_CLIENT_ROSENPASS=strict
```

Any other value stops the app from starting, with an error in the log. This
changes only the displayed command; it can't change devices that are already
connected, or install-commands outside the dashboard.

### Moving to strict mode

Switch to strict mode in this order, or devices lose their tunnels:

1. Enable permissive mode on every device.
2. Confirm with the audit below that every device reports Rosenpass enabled.
3. Remove `--rosenpass-permissive` device by device.

The bundled reverse proxy runs Rosenpass in permissive mode by default, so it
can reach both strict and classic peers.

### Managed devices

Rosenpass can be locked on through device management, so users can't turn it
off. Use the keys `rosenpassEnabled` and `rosenpassPermissive`:

- macOS: the `io.netbird.client` managed preferences payload (NetBird's
  `docs/netbird-macos.sh` generates one).
- Windows: `HKLM\Software\Policies\NetBird`, or NetBird's ADMX template.
- iOS and Android: managed app configuration.
- Linux has no device-management channel; use the `netbird up` flags.

### Audit

List devices that are not in strict mode:

```sh
curl -fsS -H "Authorization: Token $NETBIRD_API_TOKEN" \
  https://netbird.example.com/api/peers |
  jq -r '.[] | select(.local_flags.rosenpass_enabled != true
      or .local_flags.rosenpass_permissive == true)
    | [.name, .version, (.local_flags.rosenpass_enabled // false),
       (.local_flags.rosenpass_permissive // false)] | @tsv'
```

Devices report these flags themselves, so the list reflects their last
connection. It doesn't prove what a compromised device does.

## What an observer can still see

Post-quantum key exchange protects content, not metadata. An observer still
sees your server addresses and hostname, when devices connect and roughly how
much data moves, and that the traffic is WireGuard. STUN requests are
unencrypted by design and reveal only a device's public address and port.
