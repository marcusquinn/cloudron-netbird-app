# Opt-in Cloudron access reconciliation

`scripts/cloudron-access-sync.py` is a one-shot **operator tool**, shipped in the
source release alongside `scripts/cloudron-sso.py`. It is not an automatically
started app service. Installing/updating the Cloudron image does not install a
schedule, supply credentials or move existing devices to SSO ownership.

## Scope

- Use Cloudron's effective app-access API, including direct users, allowed groups,
  all-users access and administrator/operator privileges. Check active status.
- Only manage users of the configured external OIDC connector. New users first
  sign in through Cloudron, then the next successful apply can approve them.
  This is just-in-time approval, not pre-creation of every directory user.
- Preserve NetBird roles and `auto_groups`. Cloudron groups govern entitlement;
  the tool does not create matching NetBird groups or grant administrative roles.
- Keep the embedded owner, its existing devices, other IdPs and service identities
  outside reconciliation. No peer ownership transfer or deletion is performed.
- Bind the external subject to immutable Cloudron user ID before authorization
  writes. Retain bindings after removal; a reused username must not inherit them.

Read [integration boundaries](CLOUDRON-INTEGRATION.md) and
[SSO switching](SSO-SWITCH.md) before enabling this tool.

## Credentials and configuration

Use an explicitly approved Cloudron read-only API token with scope `{"*":"r"}`,
source-IP restrictions and expiry. This scope is global read-only, not per-app.
Use a dedicated NetBird administrative service-user PAT for unattended operation.
Inject them as `CLOUDRON_SYNC_TOKEN` and `NETBIRD_SYNC_TOKEN` through a trusted
secret manager. Never put values in command arguments, Git or logs. The default
NetBird authorization scheme is `Token`; `--netbird-auth Bearer` is available for
a temporary interactive session. Do not persist an interactive owner session as
an unattended credential.

Obtain the app, connector, client and embedded-owner IDs from reviewed API
metadata and the existing managed SSO configuration. Do not dump the encrypted
SSO state: it also contains the client secret. The configured issuer/client and
embedded recovery owner are checked before authorization writes. Embedded login
and NetBird new-user approval must remain enabled.

Create an owner-only state directory (mode 0700), outside Git. The state file is
written atomically with mode 0600. Preserve it in a protected backup alongside
Cloudron and NetBird identity state; do not discard it to clear a refusal.
State is private JSON, not encrypted by this tool. Use encrypted storage/backups
where required. Credential values are never stored in it.

## Plan, then explicitly apply

Run from a reviewed source checkout. Set the following non-secret variables for
the intended integration; never reuse another instance's IDs or state file.

```bash
aidevops secret CLOUDRON_SYNC_TOKEN NETBIRD_SYNC_TOKEN -- \
  python3 scripts/cloudron-access-sync.py \
  --cloudron-url "$CLOUDRON_URL" --netbird-url "$NETBIRD_URL" \
  --app-id "$APP_ID" --provider-id "$PROVIDER_ID" \
  --client-id "$CLIENT_ID" --recovery-owner-id "$RECOVERY_OWNER_ID" \
  --state "$PRIVATE_STATE_FILE"
```

The default prints aggregate planned actions and does not write API or binding
state. It may create the local lock file. Add `--apply` to the same command only
after reviewing its scope. A one-pass local lock prevents overlapping invocations
on the same state file; it does not coordinate different operator machines.

Previously active connector users are not silently adopted. Inspect them and use
`--adopt-existing` explicitly for bootstrap when identity provenance is known.
Review all such accounts before adoption: prior username reuse cannot be proven
safe from email alone. Later pending users can be bound automatically. A nonzero
`unadopted_users` count means those existing accounts remain outside enforcement.

## Removal, failure and recovery

Loss of entitlement blocks the managed NetBird user. NetBird's own user-block
operation expires that user's enrolled peers; the helper checks returned user
state and peer `login_expired` flags before clearing pending revocation state.
It does not simulate traffic or certify offline WireGuard-key removal.

Pending block intents survive interruption. An observed-unblocked target is
revalidated and retried; a still-unexpired peer after blocking requires operator
reconciliation. Never toggle an account open merely to force a retry.

If Cloudron's complete source snapshot cannot be obtained, apply blocks already
bound users and exits nonzero. No users are adopted or granted access from a
partial snapshot. If NetBird itself is unreachable, immediate revocation cannot
be guaranteed: retain the pending state and alert an operator.

The helper only automatically unblocks users it previously blocked. An unrelated
pre-existing block is held for manual review. For managed users, administer
entitlement in Cloudron; the tool cannot distinguish a later manual re-block of
an already sync-blocked account from its own block. Pause reconciliation before
an out-of-band NetBird security intervention.

## Scheduling and qualification

For recurring synchronization, use an approved continuously available automation
host and secure credential injection. Run one-shot apply on a bounded interval
and alert on nonzero exit, missed runs and credential expiry. No timer or daemon
is installed by this release. A sleeping operator laptop is not continuous
enforcement. Revocation latency includes the chosen interval and API duration;
there is no claim of instantaneous or outage-proof revocation.

The release was requested without new test scenarios. A normal plan/apply pass
observed one eligible SSO user with no approval/block/unblock needed and unchanged
embedded-owner/peer ownership. Static review and mandatory release checks are
separate from operational qualification. Live group-removal, disabled-user,
peer-traffic revocation and outage scenarios were **not run** for this release.
Qualify those before relying on this tool for unattended security enforcement.
