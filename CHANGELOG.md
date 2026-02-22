# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
