# Contributing

Thanks for your interest in contributing to the NetBird Cloudron app package.

## Getting Started

1. Fork this repository
2. Set up a Cloudron instance for testing (a [demo instance](https://cloudron.io/get.html) works)
3. Install the [Cloudron CLI](https://docs.cloudron.io/packaging/cli/): `npm install -g cloudron`

## Development Workflow

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/cloudron-netbird-app.git
cd cloudron-netbird-app

# Login to your Cloudron
cloudron login my.cloudron.example

# Build and install
cloudron build
cloudron install --location netbird

# After making changes, rebuild and update
cloudron build && cloudron update --app netbird

# View logs
cloudron logs -f --app netbird

# Debug (writable filesystem, pauses app)
cloudron debug --app netbird

# Shell access
cloudron exec --app netbird
```

## Areas of Contribution

### High Priority

- **Real-world testing** -- Install on a Cloudron instance, report issues
- **Cloudron OIDC integration** -- Connect NetBird auth to Cloudron's OIDC addon so users can log in with their Cloudron credentials
- **Logo** -- Create or source a 256x256 `logo.png`

### Medium Priority

- **LDAP addon integration** -- Sync Cloudron users to NetBird groups
- **Health check endpoint** -- Implement a proper `/health` check
- **Memory profiling** -- Verify 512 MB is sufficient under load

### Nice to Have

- **Cloudron backup verification** -- Confirm backup/restore cycle preserves all state
- **Upgrade testing** -- Test upgrading between NetBird versions
- **Documentation improvements**

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```text
feat: add OIDC addon integration
fix: correct nginx gRPC routing for signal service
docs: update README with testing results
chore: bump NetBird to v0.66.0
```

## Pull Requests

1. Create a feature branch from `main`
2. Make your changes
3. Test on a real Cloudron instance
4. Submit a PR with a description of what you changed and how you tested it

## Reporting Issues

When reporting issues, include:

- Cloudron version
- NetBird upstream version (from `CloudronManifest.json`)
- Relevant logs (`cloudron logs --app netbird`)
- Steps to reproduce
