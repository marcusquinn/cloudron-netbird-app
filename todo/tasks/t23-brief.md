# t23: Fix first-run dashboard setup authentication and STUN port mapping

## Origin

- **Created:** 2026-09-11
- **Session:** batch-2026-09-11
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** none

## What

Make a fresh Cloudron installation open NetBirds initial owner-creation wizard
instead of entering the normal OIDC flow and failing as unauthenticated. Ensure
the embedded STUN listener uses Cloudrons selected container port while still
advertising the user-selected public UDP port.

## Why

A real Cloudron user confirmed that package 2.0.14 still shows `Error: Unauthenticated` with no way to create the first account. Dashboard v2.92.0 requires runtime environment substitution, but the package writes an obsolete standalone `OIDCConfigResponse`. The manifest also fixes `containerPort` at 3478, so changing the public STUN port cannot change the listener safely.

## Tier

**Selected tier:** `tier:standard`

## How (Approach)

### Files to Modify

- EDIT: `start.sh` — prepare runtime dashboard assets/config and separate STUN ports
- EDIT: `CloudronManifest.json` — correct Cloudron STUN port mapping
- EDIT: `test/runtime-smoke.py` — verify the unauthenticated setup lifecycle
- EDIT: `test/package-test.sh` — enforce dashboard and port contracts
- EDIT: docs and changelogs — correct packaging guidance

### Implementation Steps

1. Generate dashboard assets with the runtime values expected by dashboard v2.92.0.
2. Serve generated assets and preserve `/api/instance` and `/api/setup` routing.
3. Bind and advertise Cloudrons selected STUN UDP port correctly.
4. Test the real unauthenticated setup API lifecycle.

### Verification

```bash
bash test/package-test.sh
python3 test/runtime-smoke.py --image <locally-built-image>
```

## Acceptance Criteria

- [ ] Implementation matches the What section
- [ ] Fresh `/api/instance` reports `setup_required: true`
- [ ] Unauthenticated `/api/setup` creates the initial owner
- [ ] Restart preserves completed setup state
- [ ] Dashboard assets contain runtime URLs, not placeholders
- [ ] Non-default STUN port reaches the server config
- [ ] Focused tests pass
- [ ] Lint clean (shellcheck for shell scripts)

## Context

The forum report and screenshot are external evidence only. A `/setup` HTTP 200 is insufficient: static HTML can pass while its browser-side instance-status request fails and falls into OIDC authentication.
