# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

Read the [root package contract](../AGENTS.md), then the task-relevant guides in
the [documentation index](../docs/README.md). This directory is AI-only; do not
duplicate operator procedures here or add standalone operator guides at root.
For identity, permission or VPN changes, load
[Cloudron integration boundaries](../docs/CLOUDRON-INTEGRATION.md) first.

## Purpose

Files in `.agents/` provide project-specific instructions that AI assistants
read when working in this repository. Use this for:

- Domain-specific conventions not covered by the framework
- Project architecture decisions and patterns
- API design rules, data models, naming conventions
- Integration details (third-party services, deployment targets)

## Adding Agents

Create `.md` files in this directory for domain-specific context:

```text
.agents/
  AGENTS.md              # This file - overview and index
  api-patterns.md        # API design conventions
  deployment.md          # Deployment procedures
  data-model.md          # Database schema and relationships
```

Each file is read on demand by AI assistants when relevant to the task.

## Security

This package has container, identity and optional host-network security boundaries:

- **Dockerfile**: Pin base images. Supervisor retains required startup privileges;
  managed nginx, NetBird server and proxy processes run unprivileged.
- **Network**: NetBird is a networking tool — ensure no credentials are baked into images
- **Cloudron addons**: Use Cloudron's addon system for secrets, not environment variables in manifests

For framework-level security guidance, see the [aidevops framework docs](https://github.com/marcusquinn/aidevops) `tools/security/prompt-injection-defender.md`.
