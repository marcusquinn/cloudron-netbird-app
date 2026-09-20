# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.3.0] - 2026-09-20

- Add an opt-in, one-shot Cloudron access reconciler using the effective
  user/group app-access API, with explicit apply and existing-user adoption.
- Bind external subjects to immutable Cloudron IDs; retain ownership tombstones,
  manual-block safeguards and recoverable pending revocation state.
- Preserve embedded recovery owners, other providers, existing peer ownership,
  user roles and NetBird group settings. No scheduler starts automatically.
- Move six operator guides into `docs/`, add an integration-contract index and
  update AI entrypoints, links and package checks.
- Document Cloudron's OpenVPN-only native VPN-provider gate and device migration
  requirements. Normal reconciliation was observed without authorization or peer
  changes; synthetic and live revocation scenarios were not run for this release.

## [2.2.0] - 2026-09-20

- Include optional new-install Cloudron OIDC onboarding and an explicit managed
  SSO switch for existing installs using supported custom-client/provider APIs.
- Preserve client/connector identity, embedded owner recovery and new-user
  approval. Disabling new SSO authorization does not revoke existing sessions.
- Add per-source/total ingress connection limits, an owned IPv4 denylist,
  validated protection updates with rollback, and status/counter reporting.
- Document HTTP-layer limits, optional reputation integration and host-update
  requirements separately from the Cloudron app image update.

## [2.1.0] - 2026-09-19

- Bundle the pinned NetBird proxy as an optional unprivileged service.
- Add a dedicated-IP host bridge with raw TLS, source identity preservation,
  isolated firewall rules, rollback and drift detection. No platform nginx edits.
- Persist proxy credentials and certificates; require explicit domain and trusted
  forwarding source. Disable arbitrary custom proxy ports.
- Route ProxyService gRPC and optionally restrict initial setup to app-local calls.
- Add live tests for peer registration, public certificate issuance, proxy traffic,
  header authentication and forwarded-IP spoof rejection.

## [2.0.18] - 2026-09-19

- Updated the combined NetBird server from `v0.78.2` to `v0.79.0`.

## [2.0.17] - 2026-09-16

- Updated the combined NetBird server from `v0.78.1` to `v0.78.2`.

## [2.0.16] - 2026-09-12

- Added a dedicated Cloudron TCP port with the `tls` addon so native NetBird
  clients retain end-to-end HTTP/2 for management and signal gRPC.
- Kept dashboard, REST API, and embedded IdP traffic on the normal Cloudron app
  URL while advertising the selected native port for signal and relay traffic.
- Added runtime coverage for the TLS certificate fixture, selected external port,
  fixed container listener, certificate verification, and HTTP/2 negotiation.
- Clarified that Cloudron TURN uses an incompatible shared-secret credential model
  and that NetBird Reverse Proxy clusters still require public TLS passthrough.

## [2.0.15] - 2026-09-11

- Fixed fresh installs falling into an unauthenticated OIDC login by applying the
  current dashboard runtime configuration to its exported assets.
- Fixed custom STUN ports by making NetBird listen on the same UDP port Cloudron
  exposes instead of retaining an incompatible fixed container port.
- Expanded runtime smoke coverage to create the initial owner through the real
  unauthenticated setup API and preserve setup state across restart.

## [2.0.14] - 2026-09-11

- Updated the combined NetBird server from `v0.77.1` to `v0.78.1` (#99).
- Updated the NetBird dashboard from `v2.90.10` to `v2.92.0` (#98).

## [2.0.13] - 2026-09-11

- Fixed `/setup` and `/setup/` returning 403 by preferring exported dashboard HTML
  over Next.js metadata directories (#105, #106).
- Added a bounded opt-in container smoke check for startup/restart, strict HTTP
  success, child privileges, persistent data, and safe cleanup (#104, #107).

## [2.0.12] - 2026-09-11

- Fixed Supervisor startup by restoring its privileged launcher for container
  log and PID-file access on fresh installs and restarts (#100, #101).
- Preserved unprivileged nginx and NetBird services and corrected the startup
  regression-test expectation.

## [2.0.11] - 2026-08-22

### Changed

- Updated the combined NetBird server from `v0.77.0` to `v0.77.1`.
- Retained the current dashboard at `v2.90.10`.

## [2.0.10] - 2026-08-16

### Changed

- Updated the combined NetBird server from `v0.76.3` to `v0.77.0`.
- Updated the dashboard from `v2.90.8` to `v2.90.10`.

## [2.0.9] - 2026-08-09

### Changed

- Updated the combined NetBird server from `v0.76.2` to `v0.76.3`.
- Retained the current dashboard at `v2.90.8`.

## [2.0.8] - 2026-08-08

### Changed

- Updated the combined NetBird server from `v0.76.1` to `v0.76.2`.
- Retained the current dashboard at `v2.90.8`.
- Updated the final Cloudron base image from `v5.0.0` to `v5.1.0`.

## [2.0.7] - 2026-08-01

### Changed

- Updated the combined NetBird server from `v0.76.0` to `v0.76.1`.
- Retained the current dashboard at `v2.90.8`.

## [2.0.6] - 2026-07-31

### Changed

- Updated the combined NetBird server from `v0.75.0` to `v0.76.0`.
- Updated the dashboard from `v2.90.7` to `v2.90.8`.

## [2.0.5] - 2026-07-30

### Added

- Added fail-closed publication after trusted package updates merge: the
  workflow builds an amd64 image, resolves its immutable GHCR digest, generates
  and verifies the catalog entry, and creates the matching tag and release.

### Changed

- Published the Cloudron 9.1 and 9.2 compatibility repair as a new immutable
  package version through the managed release lifecycle.

## [2.0.4] - 2026-07-24

### Fixed

- Restored Cloudron 9.1 and 9.2 installation and update compatibility by
  temporarily omitting `packageUrl` until Cloudron 10.0.0 is numerically
  available.

## [2.0.3] - 2026-07-24

### Changed

- Updated the combined NetBird server from `v0.74.7` to `v0.75.0`.
- Updated the dashboard from `v2.90.4` to `v2.90.7`.

## [2.0.2] - 2026-07-24

### Added

- Cloudron community catalog metadata, publishing runbook, improved icon, and
  privacy-reviewed 3:1 product hero.

### Changed

- Require Cloudron `9.1.0` for community-package publishing metadata.
- Generate dashboard runtime configuration under writable app data so the
  package starts correctly with Cloudron's read-only application code.
- Keep generated Nginx logs in writable runtime storage and document amd64
  builds so copied NetBird binaries match the Cloudron base image.
- Generate the embedded store encryption key as 32 random base64-encoded
  bytes, matching NetBird's encryption-key contract.
- Accept HTTP/1.1 on the Cloudron-facing Nginx listener so platform health
  checks and proxied dashboard/API requests receive valid HTTP responses.
- Use the embedded identity provider's discovery endpoint for Cloudron health
  checks so readiness requires both Nginx and the NetBird server.

## [2.0.1] - 2026-07-22

### Added

- Managed tag-triggered Cloudron package release validation.

### Changed

- Updated the combined NetBird server from `v0.65.3` to `v0.74.7`.
- Updated the dashboard from `v2.32.4` to `v2.90.4`.
- Pinned the final Cloudron base image and upstream server and dashboard image
  digests.
- Replaced moving or unavailable release downloads with deterministic
  multi-stage image copies.

### Security

- Added nginx security headers: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy` to all responses.
- Changed `X-XSS-Protection` from `1; mode=block` to `0` — the XSS auditor is deprecated and can introduce vulnerabilities in older browsers (PR #10 review).
- Added `Permissions-Policy: interest-cohort=()` header to disable FLoC tracking (PR #10 review).
- nginx now runs as non-root user (`cloudron`) via supervisord, matching the netbird-server process.
- Added explicit `scgi_temp_path` and `uwsgi_temp_path` directives to ensure all nginx temp paths are in the writable `/run/nginx/` directory.

## [2.0.0] - 2026-02-26

### Breaking Changes

- Complete rewrite of server configuration from `management.json` (legacy multi-container format) to `config.yaml` (combined server format). Existing installations will need a fresh install.
- Removed `oidc` and `turn` addons from manifest. NetBird now uses its embedded IdP for authentication (with Cloudron OIDC available as a post-setup addition via the dashboard). TURN is handled by NetBird's built-in relay.
- STUN port moved from `tcpPorts` to `udpPorts` (STUN uses UDP, not TCP).
- Package version bumped to 2.0.0 to reflect the architectural rewrite.

### Fixed

- **Auth Catch-22 (critical)**: The embedded IdP (Dex) was never initialized because the old `management.json` format with `IdpManagerConfig.ManagerType: "none"` explicitly disabled it. The `/setup` page and `/oauth2/token` endpoint returned 401. Now uses `config.yaml` with `server.auth.*` which properly enables the embedded IdP.
- **gRPC routing**: Changed from `grpc_pass grpc://127.0.0.1:8081` to `grpc_pass grpc://netbird_server` with proper upstream, matching the upstream nginx configuration docs. Added `grpc_socket_keepalive on` and `1d` timeouts for long-lived connections.
- **WebSocket routing**: Added `/ws-proxy/` path routing for signal and management WebSocket connections (was missing entirely).
- **Dashboard auth config**: Dashboard now gets full OIDC configuration (`AUTH_AUDIENCE`, `AUTH_CLIENT_ID`, `AUTH_AUTHORITY`, `AUTH_REDIRECT_URI`, `AUTH_SILENT_REDIRECT_URI`) instead of just the API endpoint. Also generates `OIDCConfigResponse` file that the dashboard JS reads at load time.
- **Server command**: Changed from `--management-config management.json` to `--config config.yaml` (correct flag for combined server binary).
- **Health check**: Uses `/api/accounts` which the management API serves (the combined server's `/health` on port 9000 is not routed through nginx).
- **nginx timeouts**: Added `client_header_timeout 1d` and `client_body_timeout 1d` required for long-lived gRPC connections.
- **supervisord**: Removed `--nodaemon` from start.sh `exec` (was using `&` background which broke process supervision). Now uses `exec supervisord --nodaemon` correctly as PID 1.

### Changed

- Removed the post-start OIDC registration hack (PAT-based API calls). Cloudron OIDC is now a post-setup manual addition via the dashboard UI, which is the correct flow.
- Removed unused `config.template.yaml` and `nginx-netbird.conf` default files from the image (config is generated at runtime).
- Simplified Dockerfile by removing unnecessary COPY of template files.
- Updated architecture diagram in README to reflect correct port mappings.
- Updated README to document the new first-run flow (setup page, not OIDC auto-registration).

## [1.1.0] - 2026-02-22

### Added

- Cloudron OIDC addon integration for single sign-on (users log in with Cloudron credentials)
- Automatic OIDC provider registration on startup (when admin PAT is configured)
- Manual OIDC setup instructions printed to logs when PAT is not available
- Cloudron TURN addon integration for NAT traversal relay
- TURN server configuration alongside existing STUN for maximum connectivity

### Changed

- Manifest version bumped to 1.1.0
- start.sh restructured into clearer phases (4a-4d) for STUN/TURN, management, dashboard, and nginx config
- Updated description and post-install message to mention SSO support

## [1.0.0] - 2026-02-22

### Added

- Initial Cloudron app package for NetBird v0.65.3
- Combined `netbird-server` binary (management + signal + relay + STUN)
- PostgreSQL addon integration for production database
- nginx reverse proxy with gRPC, WebSocket, and HTTP routing
- supervisord multi-process management
- Auto-generated encryption key on first run
- Embedded IdP (Dex) for initial setup
- STUN port (UDP 3478) exposed via `tcpPorts` manifest option
- Dashboard static file serving
- Cloudron backup-compatible persistent data layout
- Logo from upstream NetBird dashboard assets
