#!/usr/bin/env python3
"""Authenticate a local NetBird owner using OIDC/PKCE; keep credentials encrypted."""
import argparse
import base64
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class Form(HTMLParser):
    def __init__(self):
        super().__init__()
        self.action = None
        self.fields = {}

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'form':
            self.action = a.get('action')
        elif tag == 'input' and a.get('name'):
            self.fields[a['name']] = a.get('value', '')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--domain', required=True)
    p.add_argument('--email', required=True)
    p.add_argument('--secret-name', required=True)
    a = p.parse_args()
    assert re.fullmatch(r'[a-z0-9.-]+', a.domain)
    assert re.fullmatch(r'[A-Z0-9_]+', a.secret_name)
    origin = 'https://' + a.domain
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(24)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    redirect = origin + '/nb-auth'
    query = urllib.parse.urlencode(dict(client_id='netbird-dashboard', redirect_uri=redirect,
        response_type='code', scope='openid profile email groups', state=state,
        code_challenge=challenge, code_challenge_method='S256'))
    response = opener.open(origin + '/oauth2/auth?' + query, timeout=20)
    for _ in range(4):
        parsed = urllib.parse.urlsplit(response.url)
        if response.url.startswith(redirect + '?'):
            callback = urllib.parse.parse_qs(parsed.query)
            assert callback.get('state') == [state]
            payload = dict(grant_type='authorization_code', client_id='netbird-dashboard',
                           redirect_uri=redirect, code=callback['code'][0], code_verifier=verifier)
            token = json.load(opener.open(urllib.request.Request(origin + '/oauth2/token',
                data=urllib.parse.urlencode(payload).encode(),
                headers={'Content-Type': 'application/x-www-form-urlencoded'}), timeout=20))
            subprocess.run(['gopass', 'insert', '--force', 'aidevops/' + a.secret_name],
                input=token['access_token'] + '\n', text=True, capture_output=True, check=True, timeout=60)
            print(json.dumps({'authenticated': True, 'secret_name': a.secret_name, 'expires_in': token.get('expires_in')}))
            return
        form = Form()
        form.feed(response.read().decode())
        if not form.action:
            raise RuntimeError('No supported login form')
        url = urllib.parse.urljoin(response.url, form.action)
        if not url.startswith(origin + '/oauth2/'):
            raise RuntimeError('Unexpected form origin')
        if 'login' in form.fields and 'password' in form.fields:
            form.fields.update(login=a.email, password=os.environ['NETBIRD_MARCUSQUINN_ADMIN_PASSWORD'])
        elif 'approval' in form.fields:
            form.fields['approval'] = 'approve'
        else:
            raise RuntimeError('Unexpected login challenge')
        response = opener.open(urllib.request.Request(url,
            data=urllib.parse.urlencode(form.fields).encode(),
            headers={'Content-Type': 'application/x-www-form-urlencoded'}), timeout=20)
    raise RuntimeError('Authorization did not complete')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('NetBird login failed: ' + type(exc).__name__ + ' (details withheld)', file=sys.stderr)
        sys.exit(1)
