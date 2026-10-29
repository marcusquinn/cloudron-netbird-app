# Cloudron community publishing

All command and package-file paths below are relative to the repository root.

`CloudronVersions.json` is the public package catalog. Merging a completed
package update to `main` is standing authorization for the managed publication
workflow to build and publish that manifest version. Never hand-write an image
tag or digest into the catalog.

## Release workflow

1. Finish the package release and update `CloudronManifest.json`, `CHANGELOG`,
   and `CHANGELOG.md` together.
2. Confirm `logo.png` is a 256×256 PNG and `media/hero.png` is a
   privacy-reviewed 3:1 image. Verify every `iconUrl` and `mediaLinks` URL
   returns an image over public HTTPS.
3. Merge the completed package update to `main`. The
   `cloudron-catalog-publish.yml` workflow validates the package, builds the
   amd64 image, pushes it to `ghcr.io/marcusquinn/cloudron-netbird-app`, and
   resolves the immutable registry digest. The OCI source label links the
   package to this public repository so Cloudron can pull it anonymously.
4. The workflow runs `scripts/publish-cloudron-catalog.sh`, which adds the new
   manifest version in testing state, verifies the generated entry and digest,
   promotes that exact version to published, and verifies the final catalog.
5. GitHub Actions uses OIDC and Sigstore keyless signing to attest both the
   immutable image digest and the exact generated `CloudronVersions.json`. The
   workflow verifies the catalog attestation bundle against this repository,
   the catalog publication workflow, and `refs/heads/main` before committing.
6. The workflow commits only the generated `CloudronVersions.json`, atomically
   pushes that commit with the matching `v<VERSION>` tag, and creates the GitHub
   release, but only after an anonymous pull probe resolves that exact digest.
   Existing published versions reverify the anonymous image and tagged catalog
   digest, attest and verify the current catalog without a version bump, then
   reconcile a missing GitHub release. Mutable, unpublished, or conflicting
   entries fail closed.
7. For release qualification, test a clean install with
   `cloudron install --versions-url <PUBLIC_VERSIONS_URL> --location netbird-test`.
   Also verify upgrade, restart, health checks, and backup/restore.
8. Optionally sign in to [Cloudron Community Apps](https://ca.cloudron.io), add
   the same versions URL, and verify the imported icon, screenshot/hero,
   description, changelog, and install URL.

The workflow is the only supported catalog writer. A merge that does not bump
`CloudronManifest.json` is a verified no-op and does not create another release.
Cloudron does not currently enforce this keyless provenance; the attestations
provide independently verifiable supply-chain evidence for operators and
future policy enforcement.

## Release credential

The protected `main` branch requires the repository secret
`CLOUDRON_RELEASE_PAT`. Use one reusable fine-grained PAT for catalog
publication across the owner's Cloudron package repositories. The owner must be
a repository administrator. Set **Repository access → Only select
repositories** to those package repositories and grant only `Contents: Read and
write` (metadata read is automatic). Do not grant workflow or user permissions,
and do not reuse it for other purposes such as issue sync (`SYNC_PAT`). The
workflow exposes it only to the final validated catalog commit and atomic tag
push; GHCR, attestations, and GitHub release operations continue to use
`GITHUB_TOKEN`. The generated catalog commit includes `[skip ci]` so its
PAT-authenticated branch and tag push cannot launch duplicate publication
workflows.

Personal GitHub accounts have no account-wide Actions secrets, so each
repository holds its own copy of the same value. Keep the value once in the
aidevops secret store (`aidevops secret set CLOUDRON_RELEASE_PAT`, typed in a
terminal) and set repository secrets from there without displaying it:

```bash
aidevops secret CLOUDRON_RELEASE_PAT -- sh -c \
  'printf %s "$CLOUDRON_RELEASE_PAT" | gh secret set CLOUDRON_RELEASE_PAT --repo OWNER/REPO'
```

To add a new package repository, edit the existing token's repository access
(the value does not change) and set the secret in that repository. Do not
create another token. Regenerating the token revokes every copy: after
regeneration, update the secret store and re-set the secret in every repository
on the token's access list.

If the PAT is absent, expired, or revoked, publication fails before the push
without changing the catalog or tag. Set or refresh the repository secret as
above and rerun the failed workflow run from `main`.

Published entries are append-only. For a critical bad release, run
`cloudron versions revoke`, bump the package version, rebuild, and add a new
entry. Do not mutate the manifest or image of a published version.

Cloudron validates the complete catalog before selecting a compatible version.
Every historical manifest must therefore remain parseable by the oldest
supported Cloudron release. Do not add fields introduced by a newer Cloudron
to any catalog entry while older releases remain supported. The append-only
rule has one narrow exception: incompatible catalog metadata may be corrected
only when it otherwise makes the complete catalog unusable. Published images
and runtime package contents remain immutable.

## Visual assets

- `logo.png`: canonical 256×256 package icon.
- `media/hero.png`: canonical 1188×396 3:1 listing image.
- `CloudronManifest.json` records the current public HTTPS assets. Prefer a
  package-controlled stable URL when replacing either reference.
