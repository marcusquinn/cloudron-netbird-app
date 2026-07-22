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
	jq -e '.manifestVersion == 2 and .version == "2.0.0" and .upstreamVersion == "0.65.3"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	assert_contains Dockerfile 'netbirdio/dashboard:v2.32.4@sha256:10afad121e564f0288cae8fc966dc50d00a92fb067b6f5af642ffa2a91e27ccb AS dashboard' || return 1
	assert_contains Dockerfile 'cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c' || return 1
	assert_contains Dockerfile 'ARG NETBIRD_VERSION=0.65.3' || return 1
	assert_contains Dockerfile 'COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/' || return 1
	if grep -Fq '/releases/latest/' "${ROOT_DIR}/Dockerfile"; then
		fail "Dockerfile contains a moving latest release download" || return 1
	fi
	assert_contains .github/workflows/cloudron-package-release.yml "- 'v*'" || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-package-release-reusable.yml@main' || return 1
	bash -n "${ROOT_DIR}/start.sh"
	shellcheck "${ROOT_DIR}/test/package-test.sh"
	printf 'PASS: deterministic Cloudron package lifecycle contract\n'
	return 0
}

main "$@"
