# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
