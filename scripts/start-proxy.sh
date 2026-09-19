#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
umask 077

main() {
    if [[ -z "${PROXY_PORT:-}" || -z "${NETBIRD_PROXY_DOMAIN:-}" ]]; then
        printf '%s\n' 'NetBird reverse proxy disabled (requires PROXY_PORT and NETBIRD_PROXY_DOMAIN).'
        return 0
    fi
    if ! [[ "${NETBIRD_PROXY_DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
        [[ "${NETBIRD_PROXY_DOMAIN}" != *.* || "${NETBIRD_PROXY_DOMAIN}" == *..* ]]; then
        printf '%s\n' 'Invalid NETBIRD_PROXY_DOMAIN' >&2
        return 78
    fi
    # Host setup must supply one dedicated SNAT IPv4 /32, not a shared bridge.
    if ! python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); assert n.version==4 and n.prefixlen==32' "${NETBIRD_PROXY_TRUSTED_CIDR:-}"; then
        printf '%s\n' 'NETBIRD_PROXY_TRUSTED_CIDR must be the verified host forwarding IPv4 /32' >&2
        return 78
    fi
    mkdir -p /app/data/proxy/certs /app/data/proxy/geolocation
    chmod 700 /app/data/proxy /app/data/proxy/certs
    export NB_PROXY_MANAGEMENT_ADDRESS=http://127.0.0.1:80
    export NB_PROXY_ALLOW_INSECURE=true
    export NB_PROXY_DOMAIN="${NETBIRD_PROXY_DOMAIN}"
    export NB_PROXY_ADDRESS=:8443
    export NB_PROXY_HEALTH_ADDRESS=127.0.0.1:8445
    export NB_PROXY_DEBUG_ENDPOINT=false
    export NB_PROXY_CERTIFICATE_DIRECTORY=/app/data/proxy/certs
    export NB_PROXY_GEO_DATA_DIR=/app/data/proxy/geolocation
    export NB_PROXY_ACME_CERTIFICATES=true
    export NB_PROXY_ACME_CHALLENGE_TYPE=tls-alpn-01
    export NB_PROXY_PROXY_PROTOCOL=true
    export NB_PROXY_TRUSTED_PROXIES="${NETBIRD_PROXY_TRUSTED_CIDR}"
    export NB_PROXY_SUPPORTS_CUSTOM_PORTS=false
    export NB_PROXY_REQUIRE_SUBDOMAIN=true
    export NB_PROXY_FORWARDED_PROTO=https
    export NB_PROXY_LOG_LEVEL=info
    if [[ -n "${NETBIRD_PROXY_ACME_DIRECTORY:-}" ]]; then
        export NB_PROXY_ACME_DIRECTORY="${NETBIRD_PROXY_ACME_DIRECTORY}"
    fi
    local ready=false
    local attempt
    for ((attempt = 0; attempt < 120; attempt++)); do
        if curl -fsS --max-time 2 http://127.0.0.1:80/api/instance >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 1
    done
    if [[ "${ready}" != true ]]; then
        printf '%s\n' 'Proxy waiting for management failed; core services are unaffected.' >&2
        return 1
    fi
    local token_file=/app/data/proxy/token
    exec 9>/app/data/proxy/token.lock
    flock -x 9
    if [[ ! -s "${token_file}" ]]; then
        local output_file
        output_file="$(mktemp /app/data/proxy/.token-output.XXXXXX)"
        if ! /app/code/bin/netbird-server admin token create --name cloudron-bundled-proxy \
            --config /app/data/config/config.yaml >"${output_file}" 2>&1; then
            rm -f "${output_file}"
            printf '%s\n' 'Proxy token creation failed (sensitive output withheld).' >&2
            return 1
        fi
        local token
        token="$(awk '/^Token: / {print $2}' "${output_file}")"
        rm -f "${output_file}"
        if [[ -z "${token}" || "${token}" == *$'\n'* ]]; then
            printf '%s\n' 'Proxy token output was not recognized.' >&2
            return 1
        fi
        printf '%s' "${token}" >"${token_file}.new"
        mv "${token_file}.new" "${token_file}"
    fi
    chmod 600 "${token_file}"
    NB_PROXY_TOKEN="$(<"${token_file}")"
    export NB_PROXY_TOKEN
    flock -u 9
    exec 9>&-
    printf '%s\n' 'Starting optional NetBird reverse proxy (raw TLS, dedicated host bridge).'
    exec /app/code/bin/netbird-proxy
}

main "$@"
