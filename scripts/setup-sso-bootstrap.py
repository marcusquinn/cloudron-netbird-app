#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Register Cloudron SSO during a fresh install's first owner setup.

Runs only when the Cloudron OIDC addon supplied complete credentials (the SSO
checkbox was ticked at install). nginx routes only POST /api/setup here, over
loopback. The helper asks NetBird for a one-day setup token (NB_SETUP_PAT_ENABLED),
uses it once to require new-user approval and add Cloudron as an OIDC identity
provider, then deletes the token and removes it from the response.

Nothing runs at startup, no token is stored, an existing Cloudron provider is
never changed, and request bodies, tokens and the client secret are never
logged. A failed registration never fails owner setup: the embedded login keeps
working and docs/SSO-SWITCH.md describes the manual path.
"""
import http.server
import json
import os
import re
import sys
import urllib.error
import urllib.request

LISTEN = ('127.0.0.1', 8081)
UPSTREAM = 'http://127.0.0.1:80'
MAX_BODY = 64 * 1024
SETUP_TOKEN_NAME = 'setup-token'
PROVIDER_NAME = 'Cloudron'
FORWARDED_HEADERS = ('Content-Type', 'User-Agent', 'X-Real-IP', 'X-Forwarded-For',
                     'X-Forwarded-Proto', 'X-Forwarded-Host')
SAFE_ID = re.compile(r'[A-Za-z0-9_-]{1,128}')
OIDC_ENV = ('CLOUDRON_OIDC_ISSUER', 'CLOUDRON_OIDC_CLIENT_ID', 'CLOUDRON_OIDC_CLIENT_SECRET')
EXPECTED_ERRORS = (OSError, KeyError, TypeError, AttributeError, ValueError)


def log(message):
    print('==> Cloudron SSO bootstrap: ' + message, flush=True)


def warn(message):
    print('WARNING: Cloudron SSO bootstrap: ' + message, file=sys.stderr, flush=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('redirects are not permitted')


class APIError(ValueError):
    def __init__(self, step, status):
        super().__init__(step + ' returned HTTP ' + str(status))
        self.status = status


OPENER = urllib.request.build_opener(NoRedirect())


def describe(error):
    """Our own messages are safe to log; anything else is reduced to its type."""
    return str(error) if type(error) in (APIError, ValueError) else type(error).__name__


def request(method, path, body=None, token=None, headers=None, timeout=30):
    """Return (status, headers, raw body). HTTP errors are returned, not raised."""
    all_headers = dict(headers or {})
    if token:
        all_headers['Authorization'] = 'Token ' + token
    if body is not None and 'Content-Type' not in all_headers:
        all_headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(UPSTREAM + path, data=body, method=method, headers=all_headers)
    try:
        with OPENER.open(req, timeout=timeout) as response:
            return response.status, response.headers, response.read(1024 * 1024)
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read(1024 * 1024)


def parse_object(raw):
    try:
        value = json.loads(raw)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def api(step, method, path, token, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    status, _, raw = request(method, path, body=body, token=token)
    if not 200 <= status < 300:
        raise APIError(step, status)
    return json.loads(raw) if raw.strip() else None


def require_user_approval(token):
    accounts = api('account lookup', 'GET', '/api/accounts', token)
    if not isinstance(accounts, list) or len(accounts) != 1:
        raise ValueError('expected exactly one NetBird account')
    account = accounts[0]
    account_id = account.get('id', '')
    if not SAFE_ID.fullmatch(account_id):
        raise ValueError('unexpected account identifier')
    settings = account.get('settings') or {}
    if settings.get('local_auth_disabled'):
        raise ValueError('embedded login is disabled; refusing to add SSO')
    extra = settings.get('extra') or {}
    if extra.get('user_approval_required') is True:
        return
    settings['extra'] = {
        'peer_approval_enabled': extra.get('peer_approval_enabled', False),
        'network_traffic_logs_enabled': extra.get('network_traffic_logs_enabled', False),
        'network_traffic_logs_groups': extra.get('network_traffic_logs_groups') or [],
        'network_traffic_packet_counter_enabled': extra.get('network_traffic_packet_counter_enabled', False),
        'user_approval_required': True,
    }
    update = {'settings': settings}
    if account.get('onboarding') is not None:
        update['onboarding'] = account['onboarding']
    result = api('approval update', 'PUT', '/api/accounts/' + account_id, token, update)
    if ((result or {}).get('settings') or {}).get('extra', {}).get('user_approval_required') is not True:
        raise ValueError('new-user approval was not confirmed')


def register_provider(token, issuer, client_id, client_secret):
    providers = api('provider lookup', 'GET', '/api/identity-providers', token) or []
    for provider in providers:
        if (str(provider.get('issuer', '')).rstrip('/') == issuer.rstrip('/') or
                provider.get('name') in (PROVIDER_NAME, PROVIDER_NAME + ' (disabled)')):
            log('a Cloudron identity provider already exists; left unchanged')
            return
    result = api('provider registration', 'POST', '/api/identity-providers', token, {
        'type': 'oidc', 'name': PROVIDER_NAME, 'issuer': issuer,
        'client_id': client_id, 'client_secret': client_secret,
    })
    if not (result or {}).get('id'):
        raise ValueError('provider registration was not confirmed')
    log('registered Cloudron as a login option. New Cloudron users wait for '
        'approval under Team > Users; the embedded owner login stays available')


def revoke_setup_token(token, user_id):
    if not SAFE_ID.fullmatch(user_id or ''):
        raise ValueError('unexpected user identifier')
    tokens = api('token lookup', 'GET', '/api/users/' + user_id + '/tokens', token) or []
    for entry in tokens:
        token_id = entry.get('id', '')
        if entry.get('name') == SETUP_TOKEN_NAME and SAFE_ID.fullmatch(token_id):
            api('token deletion', 'DELETE', '/api/users/' + user_id + '/tokens/' + token_id, token)
    # A deleted token must no longer work on an endpoint it just used. NetBird
    # 0.80 answers an unknown token with 404 rather than 401.
    status, _, _ = request('GET', '/api/accounts', token=token)
    if status not in (401, 403, 404):
        raise APIError('token revocation check', status)


def bootstrap(token, user_id, revoke):
    issuer, client_id, client_secret = (os.environ[name] for name in OIDC_ENV)
    try:
        require_user_approval(token)
        register_provider(token, issuer, client_id, client_secret)
    except EXPECTED_ERRORS as error:
        warn('automatic registration failed (' + describe(error) + '). Owner setup succeeded and '
             'the embedded login works; add Cloudron manually as described in docs/SSO-SWITCH.md')
    finally:
        if revoke:
            try:
                revoke_setup_token(token, user_id)
                log('setup token deleted')
            except EXPECTED_ERRORS as error:
                warn('could not delete the setup token (' + describe(error) + '). It expires within '
                     'one day; delete it under Team > Users > owner > Access tokens')


def finish_setup(result, caller_wants_token):
    """Bootstrap with the setup token and return the browser-safe response."""
    token = result.get('personal_access_token')
    if not token:
        warn('NetBird returned no setup token; add Cloudron manually as described in docs/SSO-SWITCH.md')
        return result
    bootstrap(token, result.get('user_id'), revoke=not caller_wants_token)
    if not caller_wants_token:
        result.pop('personal_access_token', None)
    return result


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'netbird-setup-sso-bootstrap'
    sys_version = ''

    def log_message(self, format, *args):  # noqa: A002 - silence per-request logs
        return

    def reply(self, status, body, content_type='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def relay(self, response):
        status, headers, body = response
        self.reply(status, body, headers.get('Content-Type', 'application/json'))

    def read_body(self):
        """Return the request body, or None after replying with an error."""
        try:
            length = int(self.headers.get('Content-Length', ''))
        except ValueError:
            self.reply(411, b'{"message":"length required","code":411}')
            return None
        if not 0 <= length <= MAX_BODY:
            self.reply(413, b'{"message":"request too large","code":413}')
            return None
        return self.rfile.read(length)

    def do_GET(self):
        self.reply(405, b'{"message":"method not allowed","code":405}')

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_GET

    def do_POST(self):
        if self.path != '/api/setup':
            self.reply(404, b'{"message":"not found","code":404}')
            return
        raw = self.read_body()
        if raw is None:
            return
        forwarded = {name: self.headers[name] for name in FORWARDED_HEADERS if self.headers.get(name)}
        payload = parse_object(raw)
        if payload is None:
            # Let NetBird produce its normal validation error.
            self.relay(request('POST', '/api/setup', body=raw, headers=forwarded))
            return
        # A caller that asked for its own setup token keeps it; otherwise the
        # helper requests a one-day token for its own use and deletes it.
        caller_wants_token = payload.get('create_pat') is True
        if not caller_wants_token:
            payload['create_pat'] = True
            payload['pat_expire_in'] = 1
        response = request('POST', '/api/setup', body=json.dumps(payload).encode(), headers=forwarded)
        result = parse_object(response[2]) if response[0] == 200 else None
        if result is None:
            self.relay(response)
            return
        self.reply(200, json.dumps(finish_setup(result, caller_wants_token)).encode())


def main():
    if not all(os.environ.get(name) for name in OIDC_ENV):
        # SSO was not selected at install; nginx does not route here.
        return 0
    server = http.server.ThreadingHTTPServer(LISTEN, Handler)
    log('ready for the first owner setup')
    server.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())
