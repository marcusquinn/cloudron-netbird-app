# NetBird for Cloudron visual assets

This package preserves NetBird's upstream orange bird mark and dark dashboard
visual language. It does not rebrand NetBird or imply an official distribution.

## Publishing assets

- `logo.png` is the 256×256 Cloudron icon derived from NetBird's official web
  application icon.
- `media/hero.png` is a 1188×396 crop of the official centralized network
  management product image and shows no account, peer, or credential data.
- Keep future screenshots free of peer names, IP addresses, setup keys, user
  identities, domains, and private network topology.
- Cloudron listing media should remain public over HTTPS and use a 3:1 aspect
  ratio. Re-review asset provenance and privacy when upstream branding changes.

These assets are package metadata only. The dashboard copied from the pinned
upstream image remains visually unmodified.

## Navigation and authentication entry points

- The canonical browser entry point is the app's normal HTTPS URL. Dashboard
  navigation through the native client port redirects there while preserving
  the requested route and query.
- Native client transport stays on the selected TCP port. The redirect is not a
  substitute for a client `--management-url` and does not change gRPC, relay,
  WebSocket, REST API, or OAuth routing.
- First-run authentication shows `/setup` before any external-provider choice.
  After the owner adds Cloudron OIDC, the login screen keeps **Continue with
  Email** as the recovery path and adds a clearly named **Cloudron** button.
- Do not visually imply that matching Cloudron and embedded email addresses are
  one identity. Role assignment and approval remain explicit in **Team > Users**.
- The managed switch labels an inactive connector **Cloudron (disabled)** rather
  than deleting it: the upstream API has no provider-enabled/hidden field, and
  connector identity must remain stable. Its allowed Cloudron callback is parked,
  so new SSO authorization is rejected. **Continue with Email** stays available;
  existing sessions are not presented as revoked. See `docs/SSO-SWITCH.md`.
