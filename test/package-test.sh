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

assert_precedes() {
	local relative_path="$1"
	local first="$2"
	local second="$3"
	local first_line=""
	local second_line=""
	first_line="$(grep -nF -- "$first" "${ROOT_DIR}/${relative_path}" | cut -d: -f1)"
	second_line="$(grep -nF -- "$second" "${ROOT_DIR}/${relative_path}" | cut -d: -f1)"
	[[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || fail "${relative_path} must place ${first} before ${second}" || return 1
	return 0
}

assert_native_dashboard_redirect_contract() {
	# shellcheck disable=SC2016 # Assert generated nginx variables literally.
	assert_contains start.sh 'map "$server_port:$request_method" $native_dashboard_redirect {' || return 1
	# shellcheck disable=SC2016 # Assert generated nginx variables literally.
	assert_contains start.sh '~^33074:(GET|HEAD)$ "https://${NETBIRD_DOMAIN}";' || return 1
	# shellcheck disable=SC2016 # Assert generated nginx variables literally.
	assert_contains start.sh 'return 308 $native_dashboard_redirect$request_uri;' || return 1
	assert_contains start.sh "envsubst '\${NETBIRD_DOMAIN}' </app/data/config/nginx.conf.template >/app/data/config/nginx.conf" || return 1
	return 0
}

assert_catalog_publisher_contract() {
	if grep -Fq 'include-hidden-files: true' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow uploads hidden checkout credentials" || return 1
	fi
	[[ "$(grep -Fc 'secrets.CLOUDRON_RELEASE_PAT' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml")" -eq 1 ]] || fail "Release PAT must be exposed to exactly one publication step" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git diff --exit-code \"\${before_sha}\" -- CloudronManifest.json CHANGELOG CHANGELOG.md" || return 1
	if grep -Fq -- '--versions-file' "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"; then
		fail "Publisher uses unsupported Cloudron CLI --versions-file option" || return 1
	fi
 	return 0
}

qualification_contract() {
	assert_contains README.md 'test/QUALIFICATION.md' || return 1
	assert_contains PACKAGING-NOTES.md 'test/QUALIFICATION.md' || return 1
	assert_contains test/QUALIFICATION.md 'Historical observation' || return 1
	assert_contains test/QUALIFICATION.md 'must not target a production instance' || return 1
	assert_contains test/QUALIFICATION.md 'No default production target' || return 1
	assert_contains test/runtime-smoke.py 'never publishes images or host ports' || return 1
	assert_contains REVERSE-PROXY.md 'INGRESS-HARDENING.md' || return 1
	return 0
}

assert_optional_sso_contract() {
	jq -e '.optionalSso == true and .addons.oidc.loginRedirectUri == "/oauth2/callback" and .addons.oidc.logoutRedirectUri == "/oauth2/logout/callback" and .addons.oidc.tokenSignatureAlgorithm == "RS256"' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Optional Cloudron OIDC addon contract failed" || return 1
	assert_contains start.sh 'Cloudron SSO credentials are available for owner-managed onboarding' || return 1
	assert_contains start.sh 'incomplete optional OIDC environment; embedded authentication remains available' || return 1
	assert_contains README.md 'SSO-SWITCH.md' || return 1
	if grep -Fq 'api/identity-providers' "${ROOT_DIR}/start.sh"; then
		fail "Startup must not register an identity provider" || return 1
	fi
	return 0
}

main() {
	jq -e '.manifestVersion == 2 and .version == "2.2.0" and .upstreamVersion == "0.79.0" and .minBoxVersion == "9.1.0" and .iconUrl != "" and .packagerName != "" and .packagerUrl == "https://github.com/marcusquinn" and (has("packageUrl") | not) and (.mediaLinks | length) > 0 and .changelog == "file://CHANGELOG"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	[[ -f "${ROOT_DIR}/CloudronVersions.json" ]] || fail "CloudronVersions.json is missing" || return 1
	[[ -f "${ROOT_DIR}/PUBLISHING.md" ]] || fail "PUBLISHING.md is missing" || return 1
	[[ -f "${ROOT_DIR}/DESIGN.md" ]] || fail "DESIGN.md is missing" || return 1
	[[ -f "${ROOT_DIR}/media/hero.png" ]] || fail "media/hero.png is missing" || return 1
	jq -e '.stable == true and (.versions | type == "object")' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Version catalog contract failed" || return 1
	jq -e '[.versions[].manifest | has("packageUrl")] | all(. == false)' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Historical catalog entries must not use Cloudron-10-only packageUrl" || return 1
	assert_contains CHANGELOG '[2.0.18]' || return 1
	assert_contains CHANGELOG.md '[2.0.18] - 2026-09-19' || return 1
	assert_contains SECURITY.md '| 2.0.18      | 0.79.0           | Yes        |' || return 1
	assert_contains README.md '| Cloudron | v9.1.0+ |' || return 1
	qualification_contract || return 1
	assert_contains PUBLISHING.md 'is standing authorization for the managed publication' || return 1
	assert_contains PUBLISHING.md 'ghcr.io/marcusquinn/cloudron-netbird-app' || return 1
	jq -e '.versions["2.0.3"].publishState == "published"' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Published catalog state contract failed" || return 1
	assert_contains Dockerfile 'netbirdio/netbird-server:0.79.0@sha256:d1da0c0179c9e6f2ab7b48be54d06341b11037855a9426b9f2536aa79f13360b AS server' || return 1
	assert_contains Dockerfile 'netbirdio/dashboard:v2.92.0@sha256:fa2d8b02a81761e4d2a22df4041d13316b7635f1e93273eafeb53d4991e55b5a AS dashboard' || return 1
	assert_contains Dockerfile 'cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e' || return 1
	assert_contains Dockerfile 'LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"' || return 1
	assert_contains Dockerfile 'gettext-base' || return 1
	jq -e '.udpPorts.STUN_PORT.containerPort == null' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "STUN must use the selected external port inside the container" || return 1
	jq -e '.addons.tls == {} and .tcpPorts.NETBIRD_PORT.defaultValue == 33073 and .tcpPorts.NETBIRD_PORT.containerPort == 33074 and .tcpPorts.NETBIRD_PORT.enabledByDefault == true' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Native client transport must use the Cloudron TLS addon and dedicated container port" || return 1
	assert_optional_sso_contract || return 1
	assert_contains start.sh 'cp -a /app/code/dashboard/. /run/dashboard/' || return 1
	assert_contains start.sh 'envsubst "' || return 1
	assert_contains start.sh 'grep -RIlZ -- "AUTH_SUPPORTED_SCOPES" /run/dashboard' || return 1
	# Keep the parent privileged for log/PID access; only its services drop privileges.
	assert_contains start.sh 'exec /usr/bin/supervisord --configuration /app/code/supervisord.conf --nodaemon' || return 1
	[[ "$(grep -Fc 'user=cloudron' "${ROOT_DIR}/supervisord.conf")" -eq 3 ]] || fail "All managed services must run as cloudron" || return 1
	jq -e '.tcpPorts.PROXY_PORT.containerPort == 8443 and .tcpPorts.PROXY_PORT.enabledByDefault == false' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Proxy port must be opt-in" || return 1
	assert_contains start.sh 'management\.(ManagementService|ProxyService)' || return 1
	assert_contains scripts/start-proxy.sh 'NB_PROXY_HEALTH_ADDRESS=127.0.0.1:8445' || return 1
	assert_contains scripts/start-proxy.sh 'NB_PROXY_SUPPORTS_CUSTOM_PORTS=false' || return 1
	assert_contains start.sh 'root /run/dashboard;' || return 1
	assert_contains start.sh 'error_log /run/nginx/error.log;' || return 1
	assert_contains start.sh "try_files \$uri.html \$uri \$uri/ /index.html;" || return 1
	assert_contains start.sh "rewrite ^(.+)/\$ \$1 last;" || return 1
	assert_contains start.sh 'listen 8080;' || return 1
	assert_contains start.sh 'listen 33074 ssl http2;' || return 1
	assert_native_dashboard_redirect_contract || return 1
	assert_contains start.sh 'ssl_certificate /etc/certs/tls_cert.pem;' || return 1
	# shellcheck disable=SC2016 # Assert the generated-script placeholders literally.
	assert_contains start.sh 'exposedAddress: "https://${NETBIRD_DOMAIN}:${NETBIRD_NATIVE_PORT}"' || return 1
	assert_contains Dockerfile 'EXPOSE 8080 33074' || return 1
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
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'CLOUDRON_CLI_INTEGRITY: sha512-LHd+4u6pJxDtHX1JuVuWqrUuTbkDu+iH4jjNWW6JgB4+iDLusp08rpt6gifTFPbQjbCZHhnD8LbAGzM1NzDCXw==' || return 1
	assert_precedes .github/workflows/cloudron-catalog-publish.yml 'registry_integrity=' 'npm install --global --ignore-scripts' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'IMAGE_REPOSITORY: ghcr.io/marcusquinn/cloudron-netbird-app' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'pull_request:' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "github.event_name != 'pull_request'" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Require trusted publication source' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'EXPECTED_REF: refs/heads/main' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'attestations: write' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'subject-path: CloudronVersions.json' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'gh attestation verify CloudronVersions.json' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "--bundle \"\${{ steps.attest-catalog.outputs.bundle-path }}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "--signer-workflow \"\${GITHUB_REPOSITORY}/.github/workflows/cloudron-catalog-publish.yml\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml '--source-ref refs/heads/main' || return 1
	[[ "$(grep -Fc 'subject-path: CloudronVersions.json' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml")" -eq 2 ]] || fail "Both catalog publication paths must attest CloudronVersions.json" || return 1
	[[ "$(grep -Fc 'gh attestation verify CloudronVersions.json' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml")" -eq 2 ]] || fail "Both catalog publication paths must verify catalog provenance" || return 1
	[[ "$(grep -Fc -- '--source-ref refs/heads/main' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml")" -eq 2 ]] || fail "Both catalog provenance checks must require main as the source ref" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'scripts/publish-cloudron-catalog.sh' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml ".versions[\$version].manifest.dockerImage" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git push --atomic origin HEAD:main \"v\${RELEASE_VERSION}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Reconcile GitHub release' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git show \"v\${RELEASE_VERSION}:CloudronVersions.json\"" || return 1
	if grep -Fq 'git push origin HEAD:main' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow publishes the catalog and tag non-atomically" || return 1
	fi
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'persist-credentials: false' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "GH_TOKEN: \${{ secrets.CLOUDRON_RELEASE_PAT }}" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'CLOUDRON_RELEASE_PAT is not configured for this repository' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'gh auth setup-git' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "chore: publish Cloudron package \${RELEASE_VERSION} [skip ci]" || return 1
	assert_precedes .github/workflows/cloudron-catalog-publish.yml 'git diff --exit-code' 'gh auth setup-git' || return 1
	assert_precedes .github/workflows/cloudron-catalog-publish.yml 'gh auth setup-git' 'git push --atomic' || return 1
	assert_precedes .github/workflows/cloudron-catalog-publish.yml 'Publish and verify catalog entry' 'Attest catalog provenance' || return 1
	assert_precedes .github/workflows/cloudron-catalog-publish.yml 'Verify catalog provenance' 'Commit generated catalog' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify the build source stayed immutable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify anonymous registry visibility' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify existing immutable image is anonymously pullable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${IMMUTABLE_REF}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${EXPECTED_IMAGE_REF}\"" || return 1
	assert_catalog_publisher_contract || return 1
	bash "${ROOT_DIR}/test/publish-catalog-test.sh" || return 1
	bash -n "${ROOT_DIR}/start.sh"
	shellcheck "${ROOT_DIR}/test/package-test.sh" "${ROOT_DIR}/test/publish-catalog-test.sh" "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"
	printf 'PASS: deterministic Cloudron package and publishing lifecycle contract\n'
	return 0
}

main "$@"
