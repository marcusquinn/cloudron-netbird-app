# Security Policy

## Supported Versions

| App Version | Upstream NetBird | Supported |
|-------------|------------------|-----------:|
| 2.0.0       | 0.65.3           | Yes        |
| < 2.0.0     | N/A              | No         |

## Reporting a Vulnerability

If you discover a security vulnerability in this Cloudron app package,
please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email: **security@marcusquinn.com**

Include:

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Any potential impact assessment

You should receive an acknowledgement within 48 hours. We will work with
you to understand the issue and coordinate a fix before any public
disclosure.

## Scope

This security policy covers the **Cloudron app packaging** (Dockerfile,
start.sh, nginx config, supervisord config, manifest). For vulnerabilities
in NetBird itself, please report to the
[upstream project](https://github.com/netbirdio/netbird/security).

## Security Measures

This package implements the following security measures:

- **Branch protection**: PRs require at least 1 approving review before
  merge to `main`
- **Automated dependency updates**: Dependabot monitors Docker base images
  and GitHub Actions
- **Secret patterns in .gitignore**: `.env`, `*.pem`, `*.key`, and
  `credentials.json` are excluded from version control
- **Runtime secrets**: Encryption keys and auth secrets are generated at
  first run and persisted in `/app/data/config/` (not in the image)
- **nginx hardening**: Security headers (X-Frame-Options,
  X-Content-Type-Options, etc.) are set in the nginx config
- **Non-root nginx**: nginx worker processes run as the `cloudron` user
- **PostgreSQL connection encryption**: Database connections use
  `sslmode=prefer` (opportunistic TLS), encrypting the connection when the
  server supports it. The Cloudron PostgreSQL addon runs on the same host
  within Cloudron's internal Docker network and does not export CA
  certificates or SSL-related environment variables
  ([Cloudron addon docs](https://docs.cloudron.io/packaging/addons/#postgresql)),
  so `verify-full` is not feasible. `prefer` is the safe upgrade from
  `disable` — it uses encryption when available without requiring a trusted
  CA cert on the client.
