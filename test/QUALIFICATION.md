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
| Native client registration through the single-VPS proxy | Historical observation; executed again on 2.7.3 (2026-11-11 record) | Published candidate image, isolated VPS and disposable NetBird peer; use the candidate's documented registration procedure | Peer appears in management and can authenticate through the advertised native port | Delete only the disposable peer/setup key; do not reuse a production key |
| Public ACME TLS | Historical observation; executed again on 2.7.3 (2026-11-11 record) | Explicit maintenance window, disposable DNS name under operator control, rate-limit budget, and candidate image | Trusted public certificate and hostname match | Remove only the test DNS/app after evidence capture; no issuance loops |
| Remote WireGuard-peer HTTP | Historical observation; executed again on 2.7.3 (2026-11-11 record) | Two disposable peers on the approved fixture topology | Authenticated peer request reaches the expected service path | Remove test peers and redact peer keys |
| Header authentication and forged forwarded-IP denial | Historical observation; executed again on 2.7.3 (2026-11-11 record) | Isolated proxy fixture with known trusted and untrusted forwarding sources | Valid auth succeeds; forged forwarded address is denied | Do not change shared nginx/firewall configuration |
| App recreation and persistence | Historical observation; restore clone executed on 2.6.2 (2026-11-11 record) | Disposable Cloudron app and verified backup policy | Recreated app preserves the expected scoped state | Delete only fixture app data after confirmation |
| Bridge restart and narrow fail-closed drift repair | Historical observation; bridge crash recovery executed (2026-11-11 record); drift repair not rerun | Disposable proxy bridge and a documented, reversible drift fixture | Restart recovers; only approved drift repair is applied | Restore fixture configuration; never auto-repair a shared host |
| Local package and container contract | Reproducible baseline | Run the safe local entrypoints above against a locally built image | Commands exit zero; smoke reports labeled cleanup | Local Docker resources only; no host ports or remote targets |
| Full backup and restore | Executed once into an isolated clone (2.6.2, 2026-11-11 record); in-place restore not executed | Verified backup, restore target, rollback owner, downtime window, and written restore runbook | Restored PostgreSQL and `/app/data` state supports login and peer operation | Restoration is destructive; retain verified backup and rollback evidence |
| Certificate renewal | Deferred: platform renews only inside the CA's ARI window (2026-11-11 record); separate maintenance approval required | Named staging/production certificate policy, DNS ownership, ACME rate-limit budget, rollback procedure | Renewed certificate is served by both web and native TLS paths | One bounded issuance attempt; no retry loop or unrelated DNS changes |
| Host reboot, Docker/platform restart, or Cloudron upgrade | Executed: reboot and upgrades on 2.6.0 (2026-10-16); Docker-only restart and reboot on 2.7.3 (2026-11-11); repeat needs separate maintenance approval | Maintenance window, backup, rollback plan, exact platform versions, and operator consent | App returns healthy; setup state, secrets, native port, and peer connectivity persist | No shared restart or upgrade is performed by this harness |
| IPv6 and direct-container isolation | Executed once on production with external dual-stack probes and a same-host neighbour container (2.7.3, 2026-11-11 record) | Isolated dual-stack test network and explicit firewall/container exposure map | Required public paths work; direct container paths remain inaccessible | Never probe arbitrary public or internal addresses |
| Failure, relay, WebSocket, gRPC, and bounded load cases | Partially executed (2.7.3, 2026-11-11 record); dashboard WebSocket path not separately exercised | Published candidate, isolated peers, fixed request/connection budget, timeout, and cleanup owner | Each route/protocol has an expected success or fail-closed result and resource bound | No default load target, billable provisioning, or unbounded traffic |

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

### Production qualification window (2026-11-11)

An operator-approved maintenance window (GH#136) on the same production
single-VPS Cloudron, 01:13-02:10 UTC. A fresh app backup and a provider snapshot
were verified before any disruptive step. All 47 Cloudron apps were recorded
before the window and compared after every disruptive step; every comparison
was identical (`installationState`, `runState`, `health`, including the
pre-existing unhealthy and stopped apps).

`case=Full backup and restore; Host reboot, Docker/platform restart, or Cloudron
upgrade; IPv6 and direct-container isolation; Failure, relay, WebSocket, gRPC,
and bounded load cases; and repeats of the proxy rows;
package=2.6.2 (ghcr.io/marcusquinn/cloudron-netbird-app@sha256:be0880a9af6f384f4dcb121c3076983c538e379318bd75e01d869479068d6847)
updated in place to the published catalog entry 2.7.3
(ghcr.io/marcusquinn/cloudron-netbird-app@sha256:a30eb7b278bc77ae774ade93a1dbb4dd4655257d85e5c2ce2193b7c15b2756f6);
platform=Cloudron 10.1.6, Ubuntu 26.04.1, Docker 29.6.2 (live-restore off),
single VPS on Hetzner Cloud, ingress helper with HAProxy and nftables;
disposable peer netbirdio/netbird:0.79.0 with a persisted state volume;
command=Cloudron REST backup/clone/update/uninstall, `systemctl restart docker`,
one host reboot, `test/live-proxy-smoke.py` (three runs, two with
`--ingress-host`), and bounded operator scripts described below;
result=see below; cleanup=see below`

Observed:

- **Restore into an isolated clone (2.6.2).** A fresh app backup was cloned to
  a separate location with a different native port. `.encryption_key`,
  `.auth_secret`, the proxy token and proxy certificates hashed identically to
  production. The owner logged in through the embedded IdP and both users and
  every peer were present. The disposable peer, enrolled on production, was
  pointed at the clone without a setup key: it reconnected under the same peer
  ID and NetBird IP with 2/2 relays, the clone's native TLS port negotiated
  TLS 1.3 `X25519MLKEM768` with ALPN `h2`, and the spent setup key was
  restored as used. The peer was then returned to production and the clone
  uninstalled (container, port listener and database confirmed gone). An
  in-place restore of the production app was not executed.
- **App update 2.6.2 -> 2.7.3.** Cloudron took its pre-update backup and the
  app returned `healthy` with unchanged secret hashes. Both connected peers
  reconnected; the peer-to-peer tunnel worked. A full `test/live-proxy-smoke.py
  --ingress-host` run passed: native registration, public ACME issuance,
  remote-peer HTTP, header authentication, forged forwarding-header denial,
  unknown-SNI rejection, denylist drop with restoration, and the 60/10s
  connection limit (80 bounded attempts: 60 accepted, 20 refused).
- **Docker-only restart.** `systemctl restart docker` took 17 s. All apps
  matched the baseline, the NetBird container restarted (not recreated) with
  identical secrets, the ingress `check` passed, the disposable peer kept a P2P
  tunnel, and a smoke run passed end to end (registration, ACME, peer HTTP,
  authentication, forged-header denial).
- **Host reboot.** The host was rebooted once. All apps matched the baseline,
  `systemctl --failed` was empty, the ingress `report` and `check` passed, and
  the managed nftables table and IPv4 iptables rules were identical (order- and
  counter-insensitive) to the post-Docker-restart capture. IPv6 Docker rules
  differed only by reassigned container addresses. Both peers reconnected and
  the tunnel re-established P2P. The full `--ingress-host` smoke run passed
  again, covering end-to-end proxied traffic after reboot. An external probe
  sampling the backend-only ports during boot saw no acceptance, but it sampled
  every few seconds and missed the short down window, so it is not proof of
  the boot gap. The journal measured that gap: Docker restored the app
  (publishing the proxy backend port) about 6 s before the ingress guard
  loaded, matching the limitation documented in `docs/REVERSE-PROXY.md`.
- **Exposure probes.** From outside, on the primary IPv4 address only 443 and
  the native port accepted TCP; the proxy backend and internal ports were
  closed. The secondary ingress address accepted only 443. Over IPv6, from a
  second host, 443 and the native port accepted, the native port negotiated
  TLS 1.3 `X25519MLKEM768` with a verified certificate, and the proxy backend
  and internal ports were closed.
- **Same-host neighbour.** A labelled disposable container on the Cloudron
  bridge reached the bundled proxy's container port directly, bypassing the
  host ingress (its SNI filter, denylist and rate limit). With no restriction
  it received the test service. The proxy saw the masqueraded bridge address,
  not the neighbour's own: an allowlist of the neighbour's /32 or 10.0.0.0/8
  was denied, while 172.18.0.0/16 or 0.0.0.0/0 succeeded. With the allowlist set
  to a documentation address, forged `X-Forwarded-For`/`X-Real-IP`, a forged
  PROXY v1 header, and both together were all denied (403).
- **Bounded load.** 300 requests over 10 persistent connections (below the
  per-source connection limit) through public TLS, the ingress, the proxy and
  a WireGuard peer: 300 x 200 in 6.2 s, p50 176 ms, p95 253 ms. App memory went
  from 214 MiB to 220 MiB of the 1 GiB limit.
- **Upstream peer loss.** With the target peer's tunnel down, requests got no
  response within a 15 s client timeout (no fast 502). Nothing was served from
  a stale target. Requests succeeded again 31 s after `netbird up`.
- **Process failures.** SIGKILL of `netbird-proxy` recovered in 1.8 s under
  supervisord. After SIGKILL, supervisord respawned `netbird-server`, the API
  answered within 2 s, peers logged back in and the proxy finished its mapping
  sync within 4 s of the respawn, without
  restarting the container. SIGKILL of the bridge HAProxy recovered through
  systemd `Restart=on-failure` in 6.4 s, with the ingress `check` passing and
  rules unchanged.
- **Certificate renewal (deferred).** Cloudron 10.1.6 ignores `forceRenewal`
  when the CA supports ACME Renewal Information (ARI), and renews the wildcard
  certificate only inside the CA's suggested window (2026-12-05 to 2026-12-07).
  Forcing issuance would mean bypassing the platform, so it was not attempted.
  Web and native TLS served the same certificate. Cloudron's code rewrites the
  TLS addon files and restarts the app container when they change, so the
  native listener should pick up a renewal. That is from code inspection;
  verify the renewal after the window.

Cleanup: the restore clone was uninstalled; the disposable peer, setup keys,
proxy services and labelled containers/volumes were deleted (smoke runs
reported their own cleanup); host-side capture files were removed; the
provider snapshot was deleted after verification; the temporary Cloudron CLI
session was revoked; and the stored session tokens were removed. The firewall
rule sets matched the earlier capture.

Not covered: in-place destructive restore, a Cloudron platform upgrade, failed
renewal recovery, the dashboard WebSocket path, and a gapless boot-time
exposure measurement.

Candidate-specific ingress scripts are intentionally not referenced by the
baseline harness until their source is published. Their absence leaves proxy
qualification open; it does not weaken these fail-closed entrypoints.
