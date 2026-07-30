#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="${TEST_DIR%/*}"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_contains() {
	local relative_path="$1"
	local expected="$2"
	grep -Fq -- "$expected" "${ROOT_DIR}/${relative_path}" || fail "${relative_path} is missing: ${expected}" || return 1
	return 0
}

main() {
	jq -e '.manifestVersion == 2 and .version == "2.0.5" and .upstreamVersion == "0.75.0" and .minBoxVersion == "9.1.0" and .iconUrl != "" and .packagerName != "" and .packagerUrl == "https://github.com/marcusquinn" and (has("packageUrl") | not) and (.mediaLinks | length) > 0 and .changelog == "file://CHANGELOG"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	[[ -f "${ROOT_DIR}/CloudronVersions.json" ]] || fail "CloudronVersions.json is missing" || return 1
	[[ -f "${ROOT_DIR}/PUBLISHING.md" ]] || fail "PUBLISHING.md is missing" || return 1
	[[ -f "${ROOT_DIR}/DESIGN.md" ]] || fail "DESIGN.md is missing" || return 1
	[[ -f "${ROOT_DIR}/media/hero.png" ]] || fail "media/hero.png is missing" || return 1
	jq -e '.stable == true and (.versions | type == "object")' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Version catalog contract failed" || return 1
	jq -e '[.versions[].manifest | has("packageUrl")] | all(. == false)' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Historical catalog entries must not use Cloudron-10-only packageUrl" || return 1
	assert_contains CHANGELOG '[2.0.5]' || return 1
	assert_contains CHANGELOG.md '[2.0.5] - 2026-07-30' || return 1
	assert_contains PUBLISHING.md 'is standing authorization for the managed publication' || return 1
	assert_contains PUBLISHING.md 'ghcr.io/marcusquinn/cloudron-netbird-app' || return 1
	jq -e '.versions["2.0.3"].publishState == "published"' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Published catalog state contract failed" || return 1
	assert_contains Dockerfile 'netbirdio/netbird-server:0.75.0@sha256:9f8dbb2fee412f91acee1a280c6c06fe8a7bea7b615c37530d6a7bba2edcf901 AS server' || return 1
	assert_contains Dockerfile 'netbirdio/dashboard:v2.90.7@sha256:4b9d5eedede5b55737546124162f15ba0c79a32e78ba4c3218549be96ad22fb1 AS dashboard' || return 1
	assert_contains Dockerfile 'cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c' || return 1
	assert_contains Dockerfile 'LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"' || return 1
	assert_contains start.sh 'DASHBOARD_DIR="/app/data/dashboard"' || return 1
	assert_contains start.sh 'root /app/data/dashboard;' || return 1
	assert_contains start.sh 'error_log /run/nginx/error.log;' || return 1
	assert_contains start.sh 'listen 8080;' || return 1
	assert_contains start.sh 'openssl rand -base64 32' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'platforms: linux/amd64' || return 1
	assert_contains Dockerfile 'COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server' || return 1
	assert_contains Dockerfile 'COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/' || return 1
	if grep -Eq '/releases/latest([/?#]|$)' "${ROOT_DIR}/Dockerfile"; then
		fail "Dockerfile contains a moving latest release download" || return 1
	fi
	assert_contains .github/workflows/cloudron-package-release.yml "- 'v*'" || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-package-release-reusable.yml@22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'aidevops_ref: 22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'IMAGE_REPOSITORY: ghcr.io/marcusquinn/cloudron-netbird-app' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'pull_request:' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "github.event_name != 'pull_request'" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Require trusted publication source' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'EXPECTED_REF: refs/heads/main' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'attestations: write' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'scripts/publish-cloudron-catalog.sh' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml ".versions[\$version].manifest.dockerImage" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git push --atomic origin HEAD:main \"v\${RELEASE_VERSION}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Reconcile GitHub release' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git show \"v\${RELEASE_VERSION}:CloudronVersions.json\"" || return 1
	if grep -Fq 'git push origin HEAD:main' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow publishes the catalog and tag non-atomically" || return 1
	fi
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'persist-credentials: false' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify the build source stayed immutable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify anonymous registry visibility' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify existing immutable image is anonymously pullable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${IMMUTABLE_REF}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${EXPECTED_IMAGE_REF}\"" || return 1
	if grep -Fq 'include-hidden-files: true' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow uploads hidden checkout credentials" || return 1
	fi
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git diff --exit-code \"\${before_sha}\" -- CloudronManifest.json CHANGELOG CHANGELOG.md" || return 1
	if grep -Fq -- '--versions-file' "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"; then
		fail "Publisher uses unsupported Cloudron CLI --versions-file option" || return 1
	fi
	bash "${ROOT_DIR}/test/publish-catalog-test.sh" || return 1
	bash -n "${ROOT_DIR}/start.sh"
	shellcheck "${ROOT_DIR}/test/package-test.sh" "${ROOT_DIR}/test/publish-catalog-test.sh" "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"
	printf 'PASS: deterministic Cloudron package and publishing lifecycle contract\n'
	return 0
}

main "$@"
