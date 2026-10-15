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
	assert_contains start.sh "envsubst '\${NETBIRD_DOMAIN} \${NETBIRD_TLS_PROTOCOLS} \${NETBIRD_TLS_GROUPS}' </app/data/config/nginx.conf.template >/app/data/config/nginx.conf" || return 1
	return 0
}

assert_post_quantum_tls_contract() {
	assert_client_rosenpass_contract || return 1
	# Default: TLS 1.3 with hybrid ML-KEM only; classic groups are an opt-in.
	assert_contains start.sh 'export NETBIRD_TLS_PROTOCOLS="TLSv1.3"' || return 1
	assert_contains start.sh 'export NETBIRD_TLS_GROUPS="X25519MLKEM768"' || return 1
	# shellcheck disable=SC2016 # Assert the opt-in condition literally.
	assert_contains start.sh 'if [[ "${NETBIRD_TLS_ALLOW_CLASSIC:-false}" == true ]]; then' || return 1
	assert_contains start.sh 'export NETBIRD_TLS_GROUPS="X25519MLKEM768:X25519:prime256v1:secp384r1"' || return 1
	# shellcheck disable=SC2016 # Assert generated nginx placeholders literally.
	assert_contains start.sh 'ssl_protocols ${NETBIRD_TLS_PROTOCOLS};' || return 1
	# shellcheck disable=SC2016 # Assert generated nginx placeholders literally.
	assert_contains start.sh 'ssl_ecdh_curve ${NETBIRD_TLS_GROUPS};' || return 1
	assert_contains start.sh "NETBIRD_TLS_ALLOW_CLASSIC must be 'true' or 'false'" || return 1
	if grep -Fq 'ssl_protocols TLSv1.2' "${ROOT_DIR}/start.sh"; then
		fail "start.sh must not hard-code classic TLS protocols" || return 1
	fi
	assert_contains docs/POST-QUANTUM.md 'NETBIRD_TLS_ALLOW_CLASSIC=true' || return 1
	assert_contains docs/POST-QUANTUM.md '--enable-rosenpass' || return 1
	return 0
}

assert_native_listener_contract() {
	assert_contains start.sh 'listen 33074 ssl http2;' || return 1
	# Docker publishes NETBIRD_PORT over IPv6 too; bind it only when available.
	assert_contains start.sh "echo 'listen [::]:33074 ssl http2;' >/run/nginx/listen-ipv6.conf" || return 1
	assert_contains start.sh 'include /run/nginx/listen-ipv6.conf;' || return 1
	# procfs files report size 0, so [[ -s ]] is always false there.
	assert_contains start.sh 'if grep -qs . /proc/net/if_inet6; then' || return 1
	if grep -Fq -- '-s /proc/' "${ROOT_DIR}/start.sh"; then
		fail "start.sh must not size-test procfs files" || return 1
	fi
	assert_native_dashboard_redirect_contract || return 1
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
	assert_contains docs/PACKAGING-NOTES.md 'test/QUALIFICATION.md' || return 1
	assert_contains test/QUALIFICATION.md 'Historical observation' || return 1
	assert_contains test/QUALIFICATION.md 'must not target a production instance' || return 1
	assert_contains test/QUALIFICATION.md 'No default production target' || return 1
	assert_contains test/runtime-smoke.py 'never publishes images or host ports' || return 1
	assert_contains docs/REVERSE-PROXY.md 'INGRESS-HARDENING.md' || return 1
	return 0
}

assert_optional_sso_contract() {
	jq -e '.optionalSso == true and .addons.oidc.loginRedirectUri == "/oauth2/callback" and .addons.oidc.logoutRedirectUri == "/oauth2/logout/callback" and .addons.oidc.tokenSignatureAlgorithm == "RS256"' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Optional Cloudron OIDC addon contract failed" || return 1
	assert_contains start.sh 'Cloudron SSO credentials are available; first owner setup adds Cloudron as a login option' || return 1
	assert_contains start.sh 'incomplete optional OIDC environment; embedded authentication remains available' || return 1
	assert_contains README.md 'SSO-SWITCH.md' || return 1
	if grep -Fq 'api/identity-providers' "${ROOT_DIR}/start.sh"; then
		fail "Startup must not register an identity provider" || return 1
	fi
	assert_setup_sso_bootstrap_contract || return 1
	return 0
}

assert_setup_sso_bootstrap_contract() {
	# Setup-time token only when the OIDC addon is complete; routed over loopback.
	assert_contains start.sh 'export NB_SETUP_PAT_ENABLED=true' || return 1
	[[ "$(grep -Fc 'NB_SETUP_PAT_ENABLED' "${ROOT_DIR}/start.sh")" -eq 1 ]] || fail "NB_SETUP_PAT_ENABLED must be set only in the complete-OIDC branch" || return 1
	assert_contains start.sh "echo 'location = /api/setup {'" || return 1
	assert_contains start.sh "echo '    proxy_pass http://127.0.0.1:8081;'" || return 1
	assert_contains supervisord.conf 'command=/app/code/setup-sso-bootstrap.py' || return 1
	assert_contains Dockerfile 'COPY scripts/setup-sso-bootstrap.py /app/code/setup-sso-bootstrap.py' || return 1
	assert_contains scripts/setup-sso-bootstrap.py "LISTEN = ('127.0.0.1', 8081)" || return 1
	assert_contains scripts/setup-sso-bootstrap.py "payload['pat_expire_in'] = 1" || return 1
	assert_contains scripts/setup-sso-bootstrap.py "result.pop('personal_access_token', None)" || return 1
	assert_contains scripts/setup-sso-bootstrap.py "'user_approval_required': True" || return 1
	assert_contains scripts/setup-sso-bootstrap.py 'a Cloudron identity provider already exists; left unchanged' || return 1
	if grep -En "(log|warn|print)\(.*\+ *(client_secret|token|raw|body|payload|result)\b" "${ROOT_DIR}/scripts/setup-sso-bootstrap.py"; then
		fail "SSO setup helper must not log secrets, tokens or bodies" || return 1
	fi
	python3 -m py_compile "${ROOT_DIR}/scripts/setup-sso-bootstrap.py" || return 1
	return 0
}

assert_client_rosenpass_contract() {
	# Default connect command: Rosenpass permissive; never touch grpcApiOrigin.
	# shellcheck disable=SC2016 # Assert the shell expression literally.
	assert_contains start.sh 'case "${NETBIRD_CLIENT_ROSENPASS:-permissive}" in' || return 1
	assert_contains start.sh 'permissive) client_rosenpass_flags=" --enable-rosenpass --rosenpass-permissive" ;;' || return 1
	assert_contains start.sh "NETBIRD_CLIENT_ROSENPASS must be 'permissive', 'strict' or 'off'" || return 1
	# shellcheck disable=SC2016 # Assert the dashboard placeholder literally.
	assert_contains start.sh 'export NETBIRD_MGMT_GRPC_API_ENDPOINT="https://${NETBIRD_DOMAIN}:${NETBIRD_NATIVE_PORT}"' || return 1
	assert_contains docs/POST-QUANTUM.md 'NETBIRD_CLIENT_ROSENPASS' || return 1
	return 0
}

assert_stun_and_trust_contract() {
	jq -e '.udpPorts.STUN_PORT.containerPort == null' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "STUN must use the selected external port inside the container" || return 1
	jq -e '.addons.turn == {} and .udpPorts.STUN_PORT.enabledByDefault == false and .udpPorts.STUN_PORT.defaultValue != 3478' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Cloudron STUN must be the default with an opt-in dedicated STUN port" || return 1
	# shellcheck disable=SC2016 # Assert the generated-config placeholders literally.
	assert_contains start.sh '- uri: \"stun:${CLOUDRON_TURN_SERVER}:${CLOUDRON_TURN_PORT}\"' || return 1
	if grep -Fq 'CLOUDRON_TURN_SECRET}' "${ROOT_DIR}/start.sh"; then
		fail "STUN-only Cloudron integration must not read the TURN secret" || return 1
	fi
	assert_contains start.sh '      - "127.0.0.1/32"' || return 1
	assert_contains start.sh '      - "::1/128"' || return 1
	return 0
}

main() {
	jq -e '.manifestVersion == 2 and .version == "2.6.0" and .upstreamVersion == "0.80.0" and .minBoxVersion == "9.1.0" and .iconUrl != "" and .packagerName != "" and .packagerUrl == "https://github.com/marcusquinn" and (has("packageUrl") | not) and (.mediaLinks | length) > 0 and .changelog == "file://CHANGELOG"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	[[ -f "${ROOT_DIR}/CloudronVersions.json" ]] || fail "CloudronVersions.json is missing" || return 1
	[[ -f "${ROOT_DIR}/docs/PUBLISHING.md" ]] || fail "Publishing guide is missing" || return 1
	[[ -f "${ROOT_DIR}/DESIGN.md" ]] || fail "DESIGN.md is missing" || return 1
	[[ -f "${ROOT_DIR}/media/hero.png" ]] || fail "media/hero.png is missing" || return 1
	jq -e '.stable == true and (.versions | type == "object")' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Version catalog contract failed" || return 1
	jq -e '[.versions[].manifest | has("packageUrl")] | all(. == false)' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Historical catalog entries must not use Cloudron-10-only packageUrl" || return 1
	assert_contains CHANGELOG '[2.0.18]' || return 1
	assert_contains CHANGELOG.md '[2.0.18] - 2026-09-19' || return 1
	assert_contains SECURITY.md '| 2.0.18      | 0.79.0           | Yes        |' || return 1
	assert_contains README.md '| Cloudron | v9.1.0+ |' || return 1
	qualification_contract || return 1
	assert_contains docs/PUBLISHING.md 'is standing authorization for the managed publication' || return 1
	assert_contains docs/PUBLISHING.md 'ghcr.io/marcusquinn/cloudron-netbird-app' || return 1
	jq -e '.versions["2.0.3"].publishState == "published"' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Published catalog state contract failed" || return 1
	assert_contains Dockerfile 'netbirdio/netbird-server:0.80.0@sha256:05b3d8d6d056e5062a2965d4d6e5d6d83f09f2bf9133947a8e5972e0e0e7a261 AS server' || return 1
	assert_contains Dockerfile 'netbirdio/dashboard:v2.94.0@sha256:70e0fc6dd3b7758148d182fb55ecd8d4f9ce01e9bba56c9389224e0b8354009d AS dashboard' || return 1
	assert_contains Dockerfile 'cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b' || return 1
	assert_contains Dockerfile 'LABEL org.opencontainers.image.source="https://github.com/marcusquinn/cloudron-netbird-app"' || return 1
	assert_contains Dockerfile 'gettext-base' || return 1
	assert_stun_and_trust_contract || return 1
	jq -e '.addons.tls == {} and .tcpPorts.NETBIRD_PORT.defaultValue == 33073 and .tcpPorts.NETBIRD_PORT.containerPort == 33074 and .tcpPorts.NETBIRD_PORT.enabledByDefault == true' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Native client transport must use the Cloudron TLS addon and dedicated container port" || return 1
	assert_optional_sso_contract || return 1
	assert_contains start.sh 'cp -a /app/code/dashboard/. /run/dashboard/' || return 1
	assert_contains start.sh 'envsubst "' || return 1
	assert_contains start.sh 'grep -RIlZ -- "AUTH_SUPPORTED_SCOPES" /run/dashboard' || return 1
	# Keep the parent privileged for log/PID access; only its services drop privileges.
	assert_contains start.sh 'exec /usr/bin/supervisord --configuration /app/code/supervisord.conf --nodaemon' || return 1
	[[ "$(grep -Fc 'user=cloudron' "${ROOT_DIR}/supervisord.conf")" -eq 4 ]] || fail "All managed services must run as cloudron" || return 1
	jq -e '.tcpPorts.PROXY_PORT.containerPort == 8443 and .tcpPorts.PROXY_PORT.enabledByDefault == false' "${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Proxy port must be opt-in" || return 1
	assert_contains start.sh 'management\.(ManagementService|ProxyService)' || return 1
	assert_contains scripts/start-proxy.sh 'NB_PROXY_HEALTH_ADDRESS=127.0.0.1:8445' || return 1
	assert_contains scripts/start-proxy.sh 'NB_PROXY_SUPPORTS_CUSTOM_PORTS=false' || return 1
	assert_contains start.sh 'root /run/dashboard;' || return 1
	assert_contains start.sh 'error_log /run/nginx/error.log;' || return 1
	assert_contains start.sh "try_files \$uri.html \$uri \$uri/ /index.html;" || return 1
	assert_contains start.sh "rewrite ^(.+)/\$ \$1 last;" || return 1
	assert_contains start.sh 'listen 8080;' || return 1
	assert_native_listener_contract || return 1
	assert_post_quantum_tls_contract || return 1
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
