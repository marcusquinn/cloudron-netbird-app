# NetBird MCP server

NetBird 0.83.0 and later can serve its management API as a
[Model Context Protocol](https://modelcontextprotocol.io) (MCP) server. An AI
agent such as Claude Code, Codex, Cursor or VS Code can then list peers, edit
groups and policies, set up networks and DNS, and read the audit log. This guide
covers enabling it on this Cloudron package and setting it up safely.

The MCP server ships with package 2.7.4 and later, and it is **off** until you
turn it on. Package 2.7.5 routes the OAuth discovery documents that MCP clients
fetch first. The upstream dashboard answers them with `404`, but this package's
dashboard fallback answered them with `200` and an HTML page on 2.7.4, which
stops some clients from signing in. Upstream references:
[overview](https://docs.netbird.io/manage/mcp-server),
[connect AI clients](https://docs.netbird.io/manage/mcp-server/connect-clients)
and [self-hosted setup](https://docs.netbird.io/selfhosted/maintenance/mcp-server).

## How it works

- Endpoint: `https://netbird.example.com/api/mcp`, on the app's normal HTTPS
  domain. Do not use the native client port (`NETBIRD_PORT`): sign-ins are bound
  to the embedded identity provider's host on port 443.
- Each tool is one REST API operation. A tool call runs the same handler and
  permission checks as the REST call, with the role of the user the agent signs
  in as. An `Auditor` can read everything and change nothing.
- Clients sign in with OAuth through the usual NetBird login: the embedded owner
  account, or Cloudron if [SSO](SSO-SWITCH.md) is set up. A
  [personal access token](https://docs.netbird.io/manage/public-api) works too.
- On the consent page, **Make changes** is unticked by default, so a new OAuth
  connection is read-only unless the user ticks it.
- There are no tools for account deletion, personal access tokens, identity
  providers, instance setup or reverse-proxy services. Device settings such as
  `netbird up` flags can't be changed through MCP.

## Before you turn it on

- **Every user of the account can connect.** NetBird has no per-account switch or
  per-user MCP setting. Each user acts with their own role. A first sign-in
  through MCP creates the NetBird user, as a first dashboard login does. Users
  pending approval and blocked users can't sign in. Keep new-user approval on.
- **Tool output goes to the model provider.** Peer IPs, user emails, new setup
  keys and the initial password of a user created in the embedded identity
  provider are sent to whichever provider the client uses.
- **Tool output is untrusted.** Peer, group and user names and audit event details
  can be set by other people and can try to steer the agent. Review every change
  the agent proposes.
- **Changes are not marked as MCP in the audit log.** They appear as normal actions
  of the signed-in user. Only sign-in, sign-out and token-reuse events are
  MCP-specific.

## Enable

```sh
cloudron env set --app APP_ID NB_MCP_ENABLED=true
```

Cloudron restarts the app. The log shows:

```text
==> MCP server: enabled at https://netbird.example.com/api/mcp
```

Nothing else is needed. The package already meets the upstream conditions for
OAuth sign-in:

- The embedded identity provider's issuer is `https://<app domain>/oauth2`, with
  no trailing slash. NetBird adds its MCP callback to the embedded identity
  provider when it starts, and a Cloudron SSO connector logs in through it.
- The datastore encryption key is persisted in
  `/app/data/config/.encryption_key`, so MCP client registrations survive
  restarts.
- The root discovery documents (`/.well-known/oauth-protected-resource/api/mcp`,
  `/.well-known/oauth-authorization-server/api/mcp/auth` and
  `/.well-known/openid-configuration/api/mcp/auth`) reach management (package
  2.7.5 and later).

To turn it off again:

```sh
cloudron env unset --app APP_ID NB_MCP_ENABLED
```

NetBird reads the value as a Go boolean (`true`, `1`, `TRUE` and so on). Any
other value leaves the server off. Startup then logs a warning.

## Recommended: limit the tools

`NB_MCP_TOOLS` is a comma-separated allowlist. Tools outside it are neither
listed nor callable, whatever the user's role, credential or consent choice. This
read-only list contains every read tool in NetBird 0.83.1. It is the safest
starting point:

```sh
cloudron env set --app APP_ID NB_MCP_ENABLED=true NB_MCP_TOOLS=get_account,list_users,get_current_user,list_peers,get_peer,list_accessible_peers,list_setup_keys,get_setup_key,list_groups,get_group,list_policies,get_policy,list_posture_checks,get_posture_check,list_countries,list_country_cities,list_networks,get_network,list_network_resources,get_network_resource,list_network_routers,get_network_router,list_all_network_routers,list_routes,get_route,list_nameserver_groups,get_nameserver_group,get_dns_settings,list_dns_zones,get_dns_zone,list_dns_records,get_dns_record,list_audit_events
```

The startup log then adds `(NB_MCP_TOOLS allowlist set)`. Add write tools only
for the tasks that need them, such as `update_group` or `create_setup_key`. The
full list is in the upstream
[tool table](https://docs.netbird.io/manage/mcp-server#what-agents-can-do).

An unknown tool name stops `netbird-server` from starting, and the app becomes
unhealthy. Check `cloudron logs --app APP_ID` for
`failed to register MCP endpoints: NB_MCP_TOOLS names unknown tool`, then fix
or unset the variable. Recheck the list after NetBird updates that rename tools.

## Verify

Without a credential, the endpoint must ask for OAuth:

```sh
curl -si -X POST https://netbird.example.com/api/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep -i '^www-authenticate'
```

| Result | Meaning |
|--------|---------|
| `401` with `WWW-Authenticate: Bearer resource_metadata="https://netbird.example.com/api/mcp/.well-known/oauth-protected-resource"` | MCP and OAuth sign-in are running |
| `401` without `WWW-Authenticate` | MCP runs, but OAuth didn't start. Look for `MCP OAuth disabled` in the log. Clients can still use a personal access token |
| `404` | MCP is off. Check the `==> MCP server:` log line |

The root discovery document must return JSON naming your domain, not HTML:

```sh
curl -s https://netbird.example.com/.well-known/oauth-protected-resource/api/mcp
```

## Connect a client

Use the app URL with `/api/mcp`. Start every client with OAuth and the default
read-only consent. Exact commands for each client are in the upstream
[client guide](https://docs.netbird.io/manage/mcp-server/connect-clients).

Claude Code:

```sh
claude mcp add --transport http netbird "https://netbird.example.com/api/mcp"
claude mcp login netbird
```

To ask only for read access, so the consent page doesn't offer **Make changes**,
use this entry in `.mcp.json`:

```json
{
  "mcpServers": {
    "netbird": {
      "type": "http",
      "url": "https://netbird.example.com/api/mcp",
      "oauth": { "scopes": "mcp:read" }
    }
  }
}
```

Client notes:

- **Codex:** `codex mcp add netbird --url "https://netbird.example.com/api/mcp"`.
  Add `--scopes mcp:read` to `codex mcp login netbird` for read-only access.
- **Claude Desktop and claude.ai:** add a custom connector with the same URL and
  leave the OAuth client ID empty. These clients connect from Anthropic's cloud,
  so the app must be reachable from the internet. A normal Cloudron install is.
- **Cursor:** some versions return the sign-in to a `cursor://` address, which
  NetBird refuses (`invalid_redirect_uri`). Use a personal access token instead.
- **Gemini CLI:** refuses OAuth endpoints on private addresses. That only matters
  if the app's domain resolves to a private address for you.
- Choose the streamable HTTP transport. The older SSE transport gets `405`.

## Choose the identity and credential

- Sign in as a user whose role fits the task: `Auditor` for read-only work, an
  admin only for changes. Don't use the embedded owner for daily agent work.
  Keep it as the [recovery login](SSO-SWITCH.md).
- Prefer OAuth. Sessions last at most 30 days, the user picks the access level,
  and a session can be revoked.
- A personal access token always has the full rights of its user, with no
  read-only option. A service user's token reads everything in the account
  whatever its role; the role only limits changes. Users with the `User`,
  `Agent Network Admin` or `Usage Viewer` role can't create tokens and must use
  OAuth. Use a token only
  for clients without browser sign-in or for unattended scripts. Keep it in a
  secret manager or environment variable (for example
  `"Authorization": "Token ${NETBIRD_TOKEN}"` in `.mcp.json`), and never commit
  it. Tokens start with `nbp_`; OAuth tokens start with `nbmcp_` and
  `nbmcpr_`, so secret scanners can find them.
- Keep approval prompts on for tools that change data. `update_` tools replace
  the whole object: for example, `update_group` without `peers` empties the
  group. `create_` tools and `approve_user` are not marked destructive, so a
  client that asks only before destructive tools runs them without asking. Do
  not auto-approve tool calls on a connection that can make changes.

## Sessions and restarts on Cloudron

The package keeps NetBird's MCP sign-ins in memory. It does not configure Redis
(`NB_CACHE_REDIS_ADDRESS`), which would move all of management's caches to Redis
and stop the app from starting whenever Redis is unreachable.

- **Every app restart signs every OAuth client out.** That includes Cloudron app
  updates, restarts, configuration and environment changes, backup restores, and
  is expected for the restart after a certificate renewal (not yet observed;
  see the [qualification matrix](../test/QUALIFICATION.md)). Users sign in again from their
  client. Their client registrations stay valid, and personal access tokens are
  not affected.
- An access token lasts 1 hour and is refreshed without asking the user. A
  session ends 30 days after sign-in at the latest.
- `NB_MCP_OAUTH_KEY` is not needed on this single-instance package, because a
  restart already ends every session. If you set it, use at least 32 bytes
  (`openssl rand -base64 32`), and change it rather than removing it. Removing
  it falls back to the datastore key.

## Revoke access

| To cut off | Do this | Takes effect |
|------------|---------|--------------|
| One OAuth connection | Sign out in a client that revokes its tokens, for example `claude mcp logout netbird` before `claude mcp remove netbird` | Next call |
| One personal access token | Delete it in the NetBird **Users** page | Next call |
| Every connection of one user | Remove the user, or block them and keep them blocked | Next call |
| Every OAuth connection of every user | `cloudron restart --app APP_ID` (no audit entry) | When the app restarts |
| MCP entirely | `cloudron env unset --app APP_ID NB_MCP_ENABLED` | When the app restarts |

Removing or deactivating a Cloudron user, or removing their app access, does
**not** end an open MCP session. It applies at the next sign-in, up to 30 days
later. Block the NetBird user as well, by hand or with the opt-in
[access reconciler](ACCESS-SYNC.md). Blocking also logs out the user's peers.

Blocking pauses sessions only while the user stays blocked. Unblocking can let a
session younger than 30 days work again, unless an app restart has signed it out
since. Removing the user ends their sessions for good. `claude mcp remove` alone
and `codex mcp logout` delete the tokens locally without ending the session at
NetBird.

## Audit log

Sign-ins record **MCP client signed in** (`mcp.session.start`), sign-outs
`mcp.session.revoke`, and sessions ended for token reuse `mcp.session.replay`.
Each entry includes `access` (`read` or `read and write`), the client's
self-chosen `client_name` and the `redirect_host`. Check the redirect host. The
client name proves nothing. Failed sign-ins and personal access token use record
no MCP entry.

## Cloudron limits

- **Sign-in callback rate limit is shared.** NetBird limits its OAuth callback to
  30 requests per minute for each client address. Requests reach NetBird through
  Cloudron's proxy and the in-container nginx. By design, the package sets no
  `trustedHTTPProxies` (a different setting from the `trustedPeers` used by the
  bundled reverse proxy), so NetBird doesn't read client addresses from
  `X-Forwarded-For` for this limit. Trusting them would mean trusting the Docker
  gateway, which other containers' traffic also appears from. Expect all users
  to share one budget. A burst of
  sign-ins, or someone flooding the callback, can delay new OAuth sign-ins for
  up to a minute. Open sessions and personal access tokens keep working.
- **API rate limiting** is off unless you set `NB_API_RATE_LIMITING_ENABLED=true`.
  When it is on, it applies per personal access token and per OAuth user.
- **No tenant switching.** `?account=` works only with the account's own ID.
- **Several app instances** are independent management servers. Connect each
  with its own server entry and URL. See [multiple instances](MULTI-INSTANCE.md).
- **Anonymous metrics:** when NetBird's anonymous usage metrics are on (the
  package doesn't turn them off), management also reports whether MCP is
  enabled and daily tool-call and user counts. It doesn't report user IDs.
  Upstream's off switch, `server.disableAnonymousMetrics`, isn't
  operator-settable here: `start.sh` regenerates `config.yaml` on every start.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `404` from `/api/mcp` | `NB_MCP_ENABLED` is unset or not a boolean, or the app hasn't restarted since you set it |
| App unhealthy after setting `NB_MCP_TOOLS` | Unknown tool name; see [limit the tools](#recommended-limit-the-tools) |
| `the login could not be verified` | The user is blocked or still waiting for approval. Approve them in **Users** |
| `changes data, but this connection was authorized to read only` | Sign in again from the client and tick **Make changes**, or keep the connection read-only |
| `failed with HTTP 403` | The user's NetBird role doesn't allow the operation |
| `This application is not registered with NetBird` | The datastore key changed, for example after restoring `/app/data` without its `config/` files. Remove the server from the client and add it again |
| Clients sign out after every app update | Expected; see [sessions and restarts](#sessions-and-restarts-on-cloudron) |
| `429` during sign-in | The shared callback budget is used up; wait a minute |

## Verification status

For package 2.7.5, a local container with the published images and pinned
PostgreSQL showed:

- MCP off: `/api/mcp` and all three root discovery documents return `404`.
- `NB_MCP_ENABLED=true`: an unauthenticated call returns `401` with the
  `resource_metadata` challenge. The three root documents and the `/api` copy
  return JSON naming `https://<domain>/api/mcp` and `https://<domain>/api/mcp/auth`.
  `tools/list` with a personal access token returns 75 tools.
- With the read-only allowlist above, `netbird-server` starts and `tools/list`
  returns exactly the 33 read tools.
- Package 2.7.4 with the same setting returned the dashboard's HTML page with
  `200` for the root documents.

A full browser OAuth sign-in from a real MCP client on a public Cloudron install
has not been run yet. It is listed in the
[qualification matrix](../test/QUALIFICATION.md).
