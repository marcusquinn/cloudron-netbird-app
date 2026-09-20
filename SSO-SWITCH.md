# Optional Cloudron SSO: new and existing installations

New installs retain Cloudron's optional SSO checkbox (`optionalSso: true`) and
`--no-sso`. Complete and test embedded owner login first. The install-time addon
is one onboarding path; it is not necessary to rewrite an existing app's SSO
flag, reinstall the app or migrate peers to add Cloudron login later.

## Managed switch for existing or new apps

`scripts/cloudron-sso.py` uses Cloudron's supported **custom OIDC client** API and
NetBird's authenticated identity-provider API. This path was checked on Cloudron
10.0.5 and NetBird 0.79.0. Verify API availability on other platform releases;
unsupported endpoints fail closed. It works independently of the app's original
install-time SSO flag, which remains unchanged in the Cloudron dashboard.

Requirements on the operator's machine:

- Python 3 and an initialized encrypted gopass store.
- Short-lived Cloudron administrator and NetBird owner API credentials, injected
  as `CLOUDRON_API_TOKEN` and `NETBIRD_API_TOKEN`, never pasted into command args.
- Embedded **Continue with Email** login independently tested, local login left
  enabled, and NetBird **new-user approval required** enabled. The switch refuses
  enablement without these safety settings. It does not change user roles.
- One operator at a time. The local lock does not serialize different machines;
  preserve/synchronize encrypted state before handing operations to another admin.

Set `CLOUDRON_URL` and `NETBIRD_URL` to the normal HTTPS dashboard/API origins,
not the native transport URL. From a verified source checkout, use:

```bash
aidevops secret CLOUDRON_API_TOKEN NETBIRD_API_TOKEN -- \
  python3 scripts/cloudron-sso.py status \
  --cloudron-url "$CLOUDRON_URL" --netbird-url "$NETBIRD_URL"
aidevops secret CLOUDRON_API_TOKEN NETBIRD_API_TOKEN -- \
  python3 scripts/cloudron-sso.py enable \
  --cloudron-url "$CLOUDRON_URL" --netbird-url "$NETBIRD_URL" \
  --confirm-embedded-login
aidevops secret CLOUDRON_API_TOKEN NETBIRD_API_TOKEN -- \
  python3 scripts/cloudron-sso.py disable \
  --cloudron-url "$CLOUDRON_URL" --netbird-url "$NETBIRD_URL" \
  --confirm-embedded-login
```

The confirmation asserts a real recovery-login test; it is not a replacement for
one. The state key under `aidevops/netbird-sso/` is derived from both origins and
contains the owned client/connector identity and client credential, encrypted by
gopass. No owner token is persisted by the switch or installed in the app image.
The CLI is an operator tool, not a daemon or automatic startup action.

## Exact on/off semantics

- **On:** register the dedicated client's exact NetBird `/oauth2/callback` and
  show the connector as **Cloudron**. A custom client does not inherit the
  Cloudron app's user/group ACL; NetBird's new-user approval and mesh policies
  remain essential. Other Cloudron users must not receive automatic mesh access.
- **Off:** park that client's allowed redirect at `/oauth2/cloudron-sso-disabled`,
  which is not NetBird's OIDC callback. Cloudron rejects new authorization requests
  to the real callback. The connector is labelled **Cloudron (disabled)** and
  remains visible; this upstream API has no provider-enabled/hidden flag.
- Preserve both client and connector IDs and credentials across normal toggles.
  Deleting/recreating a connector can change external-user identity mapping;
  rotating client credentials can also leave a cached connector using old values.
- Disabling new SSO authorization is **not** forced logout or revocation of
  already-issued sessions, refresh tokens, API credentials or peer access. Use
  separate explicit user/session/peer revocation for an incident. It does not
  sign the user out of Cloudron or unrelated apps.

After enabling, test in a private browser window, then retest embedded login.
The first external login is a distinct identity even if its email matches the
embedded owner. Approve the intended user under **Team > Users** while logged in
as the embedded owner, and grant only the intended role. Do not implicitly merge
identities or promote a new external login to owner.

## Failure and recovery

The switch refuses foreign/differently configured clients, connectors, origins or
owners. It records creation intent before API writes and recovers lost creation
responses without deliberately duplicating resources. It retains encrypted state
on failure: inspect `status`, correct the cause and rerun the same operation.
A missing previously recorded client or connector requires manual reconciliation;
the switch refuses to recreate identity-bearing objects silently.
Do not delete state to bypass an ownership refusal. Normal disable remains
available if new-user-approval settings later change.

If the app already has a manually configured Cloudron connector, continue using
that documented onboarding path; the helper does not silently adopt it. Do not
run both approaches against the same connector. When retiring an integration,
plan external-user/session handling before deleting its identity-bearing objects.

App backups preserve NetBird's provider/user state, but custom Cloudron OIDC
clients and the operator's gopass state have separate backup/ownership lifecycles.
Test restoration and preserve all three; do not claim app backup alone restores
this integration. No Cloudron platform database edits are required or supported.
