# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
