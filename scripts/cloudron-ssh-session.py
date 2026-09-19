#!/usr/bin/env python3
"""Obtain a CLI session through Cloudron's supported one-use SSH owner login.

Explicit administrative operation: creates/consumes an owner impersonation login.
Does not reset the owner's normal password. Credentials stay in memory and the
encrypted gopass store; raw HTTP/SSH output is never printed. Revoke the resulting
session via DELETE /api/v1/profile/sessions/current after deployment.
"""
import argparse
import base64
import hashlib
import http.cookiejar
import json
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class Callback(Exception):
    def __init__(self, url):
        self.url = url


class Redirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, origin):
        self.origin = origin

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if newurl.startswith('http://localhost:1312/callback?'):
            raise Callback(newurl)
        if not newurl.startswith(self.origin + '/'):
            raise RuntimeError('Unexpected authentication redirect origin')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True)
    parser.add_argument('--secret-name', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+', args.server):
        raise RuntimeError('Invalid server name')
    if not re.fullmatch(r'[A-Z][A-Z0-9_]+', args.secret_name):
        raise RuntimeError('Invalid secret name')
    origin = 'https://' + args.server
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), Redirect(origin))

    def request(url, payload=None, form=False):
        body = None if payload is None else (
            urllib.parse.urlencode(payload).encode() if form else json.dumps(payload).encode())
        headers = {'User-Agent': 'NetBird-Cloudron-deployment'}
        if body is not None:
            headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
        return opener.open(urllib.request.Request(url, data=body, headers=headers), timeout=30)

    # Verify the expected protocol before generating a one-use support password.
    discovery = json.load(request(origin + '/openid/.well-known/openid-configuration'))
    for key in ('authorization_endpoint', 'token_endpoint'):
        if not discovery[key].startswith(origin + '/'):
            raise RuntimeError('OIDC endpoint origin mismatch')
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    state = secrets.token_urlsafe(24)
    redirect = 'http://localhost:1312/callback'
    query = urllib.parse.urlencode(dict(client_id='cid-cli', response_type='code',
        redirect_uri=redirect, scope='openid', state=state, code_challenge=challenge,
        code_challenge_method='S256'))
    response = request(discovery['authorization_endpoint'] + '?' + query)
    page = response.read().decode()
    match = re.search(r'(/openid/interaction/[^"\s<>]+/login)', page)
    if not match:
        raise RuntimeError('Expected Cloudron password interaction not found')
    support = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=10', 'root@' + args.server, 'cloudron-support --owner-login'],
        capture_output=True, text=True, timeout=30, check=True)
    login = re.search(r'Login at https://\S+ as (\S+) / (\S+) \. This password may only be used once\.', support.stdout)
    if not login:
        raise RuntimeError('Unsupported owner-login output (withheld)')
    result = json.load(request(origin + match.group(1),
        {'username': login.group(1), 'password': login.group(2)}))
    del login, support
    url = result['redirectTo']
    callback = None
    for _ in range(5):
        if url.startswith('/'):
            url = origin + url
        if not url.startswith(origin + '/'):
            raise RuntimeError('Unexpected interaction redirect')
        try:
            response = request(url)
            page = response.read().decode()
        except Callback as found:
            callback = urllib.parse.parse_qs(urllib.parse.urlsplit(found.url).query)
            break
        confirm = re.search(r'(/openid/interaction/[^"\s<>]+/confirm)', page)
        if not confirm:
            raise RuntimeError('Unexpected authorization interaction (output withheld)')
        try:
            response = request(origin + confirm.group(1), {})
            result = json.load(response)
            url = result['redirectTo']
        except Callback as found:
            callback = urllib.parse.parse_qs(urllib.parse.urlsplit(found.url).query)
            break
    if not callback or callback.get('state') != [state] or 'code' not in callback:
        raise RuntimeError('Authorization code/state validation failed')
    token = json.load(request(discovery['token_endpoint'], dict(grant_type='authorization_code',
        client_id='cid-cli', redirect_uri=redirect, code=callback['code'][0], code_verifier=verifier), form=True))
    # Store without echo, temporary plaintext files, shell expansion, or argv secrets.
    subprocess.run(['gopass', 'insert', '--force', 'aidevops/' + args.secret_name],
        input=token['access_token'] + '\n', text=True, capture_output=True, timeout=60, check=True)
    print(json.dumps({'authenticated': True, 'stored_secret_name': args.secret_name,
        'expires_in_seconds': token.get('expires_in'), 'token_type': token.get('token_type')}))


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as exc:
        print('Authentication HTTP status: ' + str(exc.code) + ' (response withheld)', file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print('Authentication failed: ' + type(exc).__name__ + ' (credential-bearing details withheld)', file=sys.stderr)
        sys.exit(1)
