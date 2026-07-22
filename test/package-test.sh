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
	jq -e '.manifestVersion == 2 and .version == "2.0.1" and .upstreamVersion == "0.74.7"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	assert_contains Dockerfile 'netbirdio/netbird-server:0.74.7@sha256:ec97e2fcdf9666af849c293eeaaf0f4ff742f4f6e886d8873f129de8f4f6b7ef AS server' || return 1
	assert_contains Dockerfile 'netbirdio/dashboard:v2.90.4@sha256:789c274741fdd78b870480dc700b8e6a5a67a4c4016abd2b6b0a1f34bd0fdd41 AS dashboard' || return 1
	assert_contains Dockerfile 'cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c' || return 1
	assert_contains Dockerfile 'COPY --from=server /go/bin/netbird-server /app/code/bin/netbird-server' || return 1
	assert_contains Dockerfile 'COPY --from=dashboard /usr/share/nginx/html/ /app/code/dashboard/' || return 1
	if grep -Eq '/releases/latest([/?#]|$)' "${ROOT_DIR}/Dockerfile"; then
		fail "Dockerfile contains a moving latest release download" || return 1
	fi
	assert_contains .github/workflows/cloudron-package-release.yml "- 'v*'" || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-package-release-reusable.yml@22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'aidevops_ref: 22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	bash -n "${ROOT_DIR}/start.sh"
	shellcheck "${ROOT_DIR}/test/package-test.sh"
	printf 'PASS: deterministic Cloudron package lifecycle contract\n'
	return 0
}

main "$@"
