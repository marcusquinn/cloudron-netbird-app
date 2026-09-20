#!/usr/bin/env python3
"""Explicit owner-operated SSO switch using supported Cloudron/NetBird APIs.

Tokens come from CLOUDRON_API_TOKEN and NETBIRD_API_TOKEN. Recovery state, including
the dedicated OIDC client credential, stays in gopass. No startup registration,
Cloudron database editing, app migration or user/peer mutation occurs.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('API redirects are not permitted')


def origin(value):
    value = value.rstrip('/')
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or
            parsed.password or parsed.path or parsed.query or parsed.fragment):
        raise ValueError('Use an HTTPS API origin without credentials, path or query')
    return value


class API:
    def __init__(self, base, token):
        self.base = origin(base)
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, path, method='GET', body=None):
        request = urllib.request.Request(self.base + path, method=method,
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
            data=None if body is None else json.dumps(body).encode())
        with self.opener.open(request, timeout=20) as response:
            data = response.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise ValueError('Unexpected API response size')
            return json.loads(data) if data else None


class Store:
    def __init__(self, key):
        self.key = key

    def command(self, *args, data=None):
        result = subprocess.run(['gopass', *args], input=data, text=True,
                                capture_output=True, timeout=60)
        if result.returncode:
            raise ValueError('Encrypted state operation failed; output withheld')
        return result.stdout

    def load(self):
        # Do not mistake decryption/backend failure for absent state.
        names = self.command('ls', '--flat').splitlines()
        return json.loads(self.command('show', '-o', self.key)) if self.key in names else None

    def save(self, state):
        self.command('insert', '--force', self.key, data=json.dumps(state) + '\n')


class Switch:
    def __init__(self, cloudron, netbird, store):
        self.cloudron, self.netbird, self.store = cloudron, netbird, store
        self.state = store.load()
        self.issuer = cloudron.base + '/openid'
        self.callback = netbird.base + '/oauth2/callback'
        self.disabled_callback = netbird.base + '/oauth2/cloudron-sso-disabled'

    def save(self, **fields):
        self.state.update(fields)
        self.store.save(self.state)

    def inventory(self):
        owner = self.netbird.call('/api/users/current')
        if owner.get('role') != 'owner' or owner.get('is_service_user'):
            raise ValueError('Use an authenticated embedded owner, not a service user')
        if self.netbird.call('/api/instance').get('setup_required'):
            raise ValueError('Complete and test embedded owner setup first')
        if self.state and (self.state.get('cloudron') != self.cloudron.base or
                           self.state.get('netbird') != self.netbird.base or
                           self.state.get('owner_id') != owner['id']):
            raise ValueError('State belongs to a different origin or owner')
        clients = self.cloudron.call('/api/v1/oidc/clients')['clients']
        providers = self.netbird.call('/api/identity-providers')
        return owner, clients, providers

    def owned(self, clients, providers):
        if not self.state:
            return None, None
        matches = [c for c in clients if c.get('name') == self.state['client_name']]
        if len(matches) > 1:
            raise ValueError('Duplicate managed clients; reconcile before continuing')
        client = matches[0] if matches else None
        if self.state.get('client_id') and not client:
            raise ValueError('Managed client was removed; preserve identity and reconcile manually')
        if client and (client.get('appId') or client.get('loginRedirectUri') not in (self.callback, self.disabled_callback)):
            raise ValueError('Managed client configuration changed; refusing mutation')
        if client and self.state.get('client_id') and client['id'] != self.state['client_id']:
            raise ValueError('Managed client identity changed; refusing mutation')
        matches = [p for p in providers if p.get('id') == self.state.get('provider_id')]
        if not matches and not self.state.get('provider_id') and client:
            matches = [p for p in providers if p.get('client_id') == client['id']]
        if len(matches) > 1:
            raise ValueError('Duplicate managed providers; reconcile before continuing')
        provider = matches[0] if matches else None
        if self.state.get('provider_id') and not provider:
            raise ValueError('Managed provider was removed; preserve identity and reconcile manually')
        if provider and (provider.get('issuer') != self.issuer or provider.get('type') != 'oidc' or
                         provider.get('name') not in ('Cloudron', 'Cloudron (disabled)') or
                         provider.get('client_id') not in (self.state.get('client_id'),
                                                          self.state.get('previous_client_id'))):
            raise ValueError('Managed provider configuration changed; refusing mutation')
        return client, provider

    def provider_body(self, name):
        return dict(name=name, type='oidc', issuer=self.issuer,
                    client_id=self.state['client_id'], client_secret=self.state['client_secret'])

    def set_callback(self, client, callback):
        if client.get('loginRedirectUri') != callback:
            self.cloudron.call('/api/v1/oidc/clients/' + client['id'], 'POST', dict(
                name=self.state['client_name'], loginRedirectUri=callback,
                tokenSignatureAlgorithm='RS256'))

    def enable(self, owner, clients, providers):
        accounts = self.netbird.call('/api/accounts')
        if len(accounts) != 1:
            raise ValueError('Expected exactly one NetBird account')
        settings = accounts[0].get('settings', {})
        if settings.get('local_auth_disabled', True):
            raise ValueError('Embedded recovery login must remain enabled')
        if settings.get('extra', {}).get('user_approval_required') is not True:
            raise ValueError('Require new-user approval before enabling Cloudron SSO')
        if not self.state:
            if any(p.get('issuer') == self.issuer or p.get('name') == 'Cloudron' for p in providers):
                raise ValueError('An unmanaged Cloudron provider exists; do not overwrite it')
            self.state = dict(cloudron=self.cloudron.base, netbird=self.netbird.base,
                              owner_id=owner['id'], client_name='netbird-sso-' + secrets.token_hex(12))
            self.save(phase='creating-client')
        client, provider = self.owned(clients, providers)
        if not client:
            self.save(phase='creating-client', previous_client_id=self.state.get('client_id'), client_id=None)
            client = self.cloudron.call('/api/v1/oidc/clients', 'POST', dict(
                name=self.state['client_name'], loginRedirectUri=self.disabled_callback,
                tokenSignatureAlgorithm='RS256'))
        # GET also recovers a client created before a lost POST response.
        client = self.cloudron.call('/api/v1/oidc/clients/' + client['id'])
        self.save(client_id=client['id'], client_secret=client['secret'], phase='configuring-provider')
        if provider:
            result = self.netbird.call('/api/identity-providers/' + provider['id'],
                                       'PUT', self.provider_body('Cloudron'))
        else:
            result = self.netbird.call('/api/identity-providers', 'POST', self.provider_body('Cloudron'))
        self.save(provider_id=result['id'], phase='enabling-client', previous_client_id=None)
        self.set_callback(client, self.callback)
        self.save(phase='enabled')

    def disable(self, clients, providers):
        if not self.state:
            return
        client, provider = self.owned(clients, providers)
        self.save(phase='disabling')
        if client:
            self.set_callback(client, self.disabled_callback)
        if provider:
            # Retain both identities and credentials. Cloudron rejects the real
            # callback while disabled, without relying on Dex cache invalidation.
            self.netbird.call('/api/identity-providers/' + provider['id'], 'PUT',
                              self.provider_body('Cloudron (disabled)'))
        self.save(phase='disabled')

    def execute(self, action):
        owner, clients, providers = self.inventory()
        if action == 'enable':
            self.enable(owner, clients, providers)
        elif action == 'disable':
            self.disable(clients, providers)
        _, clients, providers = self.inventory()
        client, provider = self.owned(clients, providers)
        return dict(enabled=bool(client and provider and client.get('loginRedirectUri') == self.callback
                                 and provider.get('client_id') == client['id']),
                    provider_present=bool(provider), phase=self.state.get('phase') if self.state else 'unconfigured',
                    existing_sessions_revoked=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'enable', 'disable'])
    parser.add_argument('--cloudron-url', required=True)
    parser.add_argument('--netbird-url', required=True)
    parser.add_argument('--confirm-embedded-login', action='store_true',
                        help='Confirm embedded owner login was independently tested before mutation')
    args = parser.parse_args()
    if args.action != 'status' and not args.confirm_embedded_login:
        parser.error('Test embedded owner login first, then pass --confirm-embedded-login')
    cloudron_url, netbird_url = origin(args.cloudron_url), origin(args.netbird_url)
    identity = hashlib.sha256((cloudron_url + '\n' + netbird_url).encode()).hexdigest()
    lockdir = Path.home() / '.cache' / 'netbird-cloudron-sso'
    lockdir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if lockdir.is_symlink():
        raise ValueError('Refusing a symlink lock directory')
    with (lockdir / (identity + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = Switch(API(cloudron_url, os.environ['CLOUDRON_API_TOKEN']),
                        API(netbird_url, os.environ['NETBIRD_API_TOKEN']),
                        Store('aidevops/netbird-sso/' + identity)).execute(args.action)
        print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as exc:
        print('SSO API failed: HTTP ' + str(exc.code) + '; response withheld; retained state permits recovery', file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print('SSO operation failed: ' + type(exc).__name__ + '; details withheld; inspect status before retry', file=sys.stderr)
        sys.exit(1)
