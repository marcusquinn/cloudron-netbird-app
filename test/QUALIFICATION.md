# Proxy Qualification Matrix

This matrix turns known single-VPS proxy observations into repeatable evidence
without treating them as a production readiness certificate. It applies to the
exact NetBird/Cloudron package candidate and topology recorded with each run;
do not extrapolate an observation to a later image, a different Cloudron
version, or a multi-host topology.

## Safety boundary and evidence record

- **No default production target:** every command below is either a local,
  disposable Docker fixture or a procedure that requires an explicitly named
  maintenance target and separate operator approval.
- `test/runtime-smoke.py` has no remote-target argument. It runs only its local
  Docker fixture and does not pull images, publish ports, discover hosts, issue
  public certificates, create DNS records, or modify a Cloudron installation.
- The smoke harness labels each owned Docker resource with
  `io.netbird.cloudron.smoke=<run-id>`. It removes only resources whose label
  matches that run; after interruption, inspect the reported name and label
  before removal. Never use a broad Docker prune as cleanup.
- Record the package version/image digest, Cloudron version, topology, command,
  timestamp, redacted result, and owned-resource cleanup result with every new
  row result. Keep credentials, tokens, peer keys, DSNs, and raw service logs
  out of the record.
- A failed safety gate is a failed case, not an invitation to retry against a
  shared host. It must not target a production instance without a separately
  approved maintenance procedure.

Use this compact record for a new execution: `case=<matrix row>;
package=<version and image digest>; platform=<Cloudron version/topology>;
command=<redacted invocation>; result=<observable assertion>;
cleanup=<owned-resource result>`. A historical observation must retain its
historical label rather than being rewritten as a current pass.

## Safe local entrypoints

The static package contract is safe on any checkout:

```bash
bash test/package-test.sh
git diff --check
```

`test/package-test.sh` also pins the matrix references and the local-only smoke
boundary so a later documentation edit cannot silently remove those guards.

The opt-in container fixture requires Docker, a locally built candidate, and
the already-local pinned PostgreSQL image. It has a 180-second default runtime
budget and at most 60 seconds of cleanup; it owns only its generated labeled
Docker containers, network, and volumes.

```bash
docker build --platform linux/amd64 -t netbird-smoke:candidate .
docker pull postgres@sha256:33f923b05f64ca54ac4401c01126a6b92afe839a0aa0a52bc5aeb5cc958e5f20
python3 test/runtime-smoke.py --image netbird-smoke:candidate
```

The harness covers fresh setup, generated dashboard configuration, selected
STUN and native TLS listener configuration, HTTP/2 negotiation, unprivileged
services, database initialization, restart persistence, and labeled cleanup.
It cannot qualify the unpublished single-VPS proxy candidate, a real Cloudron
backup, WireGuard peers, public ACME TLS, or an external network path.

## Qualification matrix

| Case | Evidence status | Preconditions and procedure | Observable assertion | Cleanup / boundary |
|---|---|---|---|---|
| Native client registration through the single-VPS proxy | Historical observation; candidate-only and not rerun here | Published candidate image, isolated VPS and disposable NetBird peer; use the candidate's documented registration procedure | Peer appears in management and can authenticate through the advertised native port | Delete only the disposable peer/setup key; do not reuse a production key |
| Public ACME TLS | Historical observation; not rerun | Explicit maintenance window, disposable DNS name under operator control, rate-limit budget, and candidate image | Trusted public certificate and hostname match | Remove only the test DNS/app after evidence capture; no issuance loops |
| Remote WireGuard-peer HTTP | Historical observation; not rerun | Two disposable peers on the approved fixture topology | Authenticated peer request reaches the expected service path | Remove test peers and redact peer keys |
| Header authentication and forged forwarded-IP denial | Historical observation; not rerun | Isolated proxy fixture with known trusted and untrusted forwarding sources | Valid auth succeeds; forged forwarded address is denied | Do not change shared nginx/firewall configuration |
| App recreation and persistence | Historical observation; not rerun | Disposable Cloudron app and verified backup policy | Recreated app preserves the expected scoped state | Delete only fixture app data after confirmation |
| Bridge restart and narrow fail-closed drift repair | Historical observation; not rerun | Disposable proxy bridge and a documented, reversible drift fixture | Restart recovers; only approved drift repair is applied | Restore fixture configuration; never auto-repair a shared host |
| Local package and container contract | Reproducible baseline | Run the safe local entrypoints above against a locally built image | Commands exit zero; smoke reports labeled cleanup | Local Docker resources only; no host ports or remote targets |
| Full backup and restore | Unexecuted; separate maintenance approval required | Verified backup, restore target, rollback owner, downtime window, and written restore runbook | Restored PostgreSQL and `/app/data` state supports login and peer operation | Restoration is destructive; retain verified backup and rollback evidence |
| Certificate renewal | Unexecuted; separate maintenance approval required | Named staging/production certificate policy, DNS ownership, ACME rate-limit budget, rollback procedure | Renewed certificate is served by both web and native TLS paths | One bounded issuance attempt; no retry loop or unrelated DNS changes |
| Host reboot, Docker/platform restart, or Cloudron upgrade | Partially executed once (2.6.0, 2026-10-16; see execution records); repeat needs separate maintenance approval | Maintenance window, backup, rollback plan, exact platform versions, and operator consent | App returns healthy; setup state, secrets, native port, and peer connectivity persist | No shared restart or upgrade is performed by this harness |
| IPv6 and direct-container isolation | Unexecuted; dedicated network fixture required | Isolated dual-stack test network and explicit firewall/container exposure map | Required public paths work; direct container paths remain inaccessible | Never probe arbitrary public or internal addresses |
| Failure, relay, WebSocket, gRPC, and bounded load cases | Unexecuted; candidate publication and dedicated fixture required | Published candidate, isolated peers, fixed request/connection budget, timeout, and cleanup owner | Each route/protocol has an expected success or fail-closed result and resource bound | No default load target, billable provisioning, or unbounded traffic |

## Maintenance-only execution contract

The unexecuted rows are plans, not authorization. Before running one, record:

1. exact package/image provenance and fixture topology;
2. named target, owner, approved maintenance window, backup and rollback owner;
3. fixed timeout, connection/request or certificate budget, and success/failure
   observations; and
4. scoped cleanup evidence proving that only owned test resources changed.

## Execution records

### Host reboot, Cloudron upgrade and Ubuntu release upgrade (2026-10-16)

An operator-approved maintenance window on one production single-VPS Cloudron
with the optional second-IP ingress helper. It ran as one sequence: Cloudron
update, Ubuntu package update and reboot, Ubuntu release upgrade and reboot. A
full Cloudron backup and a provider snapshot were taken first.

`case=Host reboot, Docker/platform restart, or Cloudron upgrade;
package=2.6.0 (ghcr.io/marcusquinn/cloudron-netbird-app@sha256:c53bc84cab0f9fcf2f8084cb22706278490bfe3caa3201ee17aa3fe8366d6878);
platform=Cloudron 10.0.5 -> 10.1.5, then Ubuntu 24.04 -> 26.04.1 (kernel 7.0,
Docker 29.6.2, OpenSSL 3.5.5), single VPS, Hetzner Cloud, ingress helper with
HAProxy 2.8.16 -> 3.2.9 and nftables 1.1.6; command=Cloudron dashboard update,
then the official Cloudron Ubuntu 26.04 guide (two host reboots);
result=see below; cleanup=temporary operator API token removed, provider
snapshots deleted after verification`

Observed after each reboot and again about 12 hours later:

- Cloudron recreated its database addons after its own update. The app went
  through `pending_restart` and returned to `installed`, `running`, `healthy`.
- The existing app container was restarted, not recreated. An existing peer
  reconnected to Management and Signal through the native TLS port without
  re-enrolment, and 2/2 relays were available, which needs the persisted relay
  secret. The dashboard returned 200. No setup key or token decryption was
  exercised, so `.encryption_key` persistence was not separately tested.
- `netbird-ingress.py report` passed after both reboots. The labelled secondary
  address returned at boot, and the ingress IP accepted TCP on 443.
- `netbird-ingress.py check` and `nft --check -f rules.nft` both exited 0 under
  the new HAProxy and nftables versions before the second reboot.

Not covered by this record: peer-to-peer tunnel establishment (peers showed
0/2 connected both before and after, so the result was unchanged rather than
verified), an end-to-end proxied HTTP request through the ingress, a Docker-only
restart, and rollback or restore. Treat these as still unexecuted.

Candidate-specific ingress scripts are intentionally not referenced by the
baseline harness until their source is published. Their absence leaves proxy
qualification open; it does not weaken these fail-closed entrypoints.
