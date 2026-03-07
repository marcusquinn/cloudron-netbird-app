# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

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

This is a Cloudron app packaging project for NetBird. No AI/LLM dependencies. Security considerations are container-focused:

- **Dockerfile**: Follow least-privilege principles, pin base image versions, avoid running as root
- **Network**: NetBird is a networking tool — ensure no credentials are baked into images
- **Cloudron addons**: Use Cloudron's addon system for secrets, not environment variables in manifests

For framework-level security guidance, see the [aidevops framework docs](https://github.com/marcusquinn/aidevops) `tools/security/prompt-injection-defender.md`.
