# Package documentation

The root README is the user entrypoint. This directory owns detailed human and
operator documentation; `.agents/` owns AI-specific working instructions only.
Do not create duplicate root copies of these guides.

## Start here

- [Cloudron access and VPN integration](CLOUDRON-INTEGRATION.md): verified platform
  contracts, identity boundaries, revocation and migration requirements.
- [Opt-in access reconciliation](ACCESS-SYNC.md): command, credential/state
  ownership, scheduling boundaries and unexecuted qualification scenarios.
- [Packaging architecture and history](PACKAGING-NOTES.md): combined server,
  native transport and historical implementation lessons.
- [SSO switching](SSO-SWITCH.md): optional addon and existing-install custom client,
  stable identities, recovery and exact on/off semantics.
- [Public reverse proxy](REVERSE-PROXY.md) and
  [ingress hardening](INGRESS-HARDENING.md): separately managed host resources.
- [Multiple instances](MULTI-INSTANCE.md): brand isolation and port/IP allocation.
- [Publishing](PUBLISHING.md): immutable images, catalog and provenance.
- [Qualification matrix](../test/QUALIFICATION.md): verified versus unexecuted
  tests and maintenance-window gates.

Keep source availability, published release, installed configuration and actual
runtime evidence distinct. A plan or a passing API probe is not proof of a
completed end-user login, peer revocation or protected-app routing.
