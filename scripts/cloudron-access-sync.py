#!/usr/bin/env python3
"""Opt-in Cloudron entitlement reconciliation. Defaults to a non-mutating plan.

Only the configured external connector's users are eligible. Embedded owners,
other connectors, service users and existing peer ownership are never changed.
Credentials are injected through CLOUDRON_SYNC_TOKEN and NETBIRD_SYNC_TOKEN.
"""
import argparse
import base64
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import urllib.parse

SPEC = importlib.util.spec_from_file_location('cloudron_sso', Path(__file__).with_name('cloudron-sso.py'))
SSO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SSO)


class API(SSO.API):
    def __init__(self, base, token, scheme='Bearer'):
        super().__init__(base, token)
        self.scheme = scheme

    def call(self, path, method='GET', body=None):
        request = SSO.urllib.request.Request(self.base + path, method=method,
            headers={'Authorization': self.scheme + ' ' + self.token,
                     'Content-Type': 'application/json'},
            data=None if body is None else json.dumps(body).encode())
        with self.opener.open(request, timeout=10) as response:
            data = response.read(4 * 1024 * 1024 + 1)
            if len(data) > 4 * 1024 * 1024:
                raise ValueError('API response exceeds limit')
            return json.loads(data) if data else None


def segment(value):
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise ValueError('Invalid identity')
    return urllib.parse.quote(value, safe='')


def dex_identity(value):
    """Strictly decode the two length-delimited strings in a Dex subject."""
    segment(value)
    data = base64.b64decode(value + '=' * (-len(value) % 4), validate=True)
    fields, position = {}, 0
    while position < len(data):
        tag = data[position]
        position += 1
        if tag not in (10, 18) or tag in fields:
            raise ValueError('Unexpected Dex subject field')
        length, shift = 0, 0
        while True:
            if position >= len(data) or shift > 14:
                raise ValueError('Invalid Dex subject length')
            byte = data[position]
            position += 1
            length |= (byte & 127) << shift
            if byte < 128:
                break
            shift += 7
        if length < 1 or position + length > len(data):
            raise ValueError('Truncated Dex subject')
        fields[tag] = data[position:position + length].decode('utf-8')
        position += length
    if set(fields) != {10, 18}:
        raise ValueError('Incomplete Dex subject')
    return fields[10], fields[18]


def user_list(value):
    if not isinstance(value, list) or len(value) > 10000:
        raise ValueError('Invalid user inventory')
    identities = [segment(user['id']) for user in value]
    if len(identities) != len(set(identities)):
        raise ValueError('Duplicate user identity')
    return value


def cloudron_users(api):
    result = []
    for page in range(1, 102):
        response = api.call('/api/v1/users?per_page=100&page=' + str(page))
        batch = user_list(response['users'])
        if len(batch) > 100:
            raise ValueError('Invalid source page size')
        result.extend(batch)
        if len(batch) < 100:
            return user_list(result)
    raise ValueError('Source pagination exceeds limit')


def entitled(api, user, app_id):
    if type(user.get('active')) is not bool:
        raise ValueError('Source active status missing')
    if not user['active']:
        return False
    apps = api.call('/api/v1/users/' + segment(user['id']) + '/apps')['apps']
    if not isinstance(apps, list) or any(not isinstance(app.get('id'), str) for app in apps):
        raise ValueError('Effective app access unavailable')
    return any(app['id'] == app_id for app in apps)


class State:
    def __init__(self, path, identity):
        self.path = path
        self.data = {'version': 1, 'identity': identity, 'users': {}}
        if path.exists() or path.is_symlink():
            stat = path.lstat()
            if path.is_symlink() or stat.st_uid != os.geteuid() or stat.st_mode & 0o077:
                raise ValueError('State must be private, owned and not a symlink')
            self.data = json.loads(path.read_text())
            if self.data.get('version') != 1 or self.data.get('identity') != identity:
                raise ValueError('State belongs to another integration')
            if not isinstance(self.data.get('users'), dict):
                raise ValueError('Invalid ownership state')
            for user_id, record in self.data['users'].items():
                subject, connector = dex_identity(user_id)
                if connector != identity['provider_id'] or record.get('subject') != subject:
                    raise ValueError('Stored binding differs from managed connector')
                segment(record['source_id'])
                if type(record.get('blocked_by_sync')) is not bool or type(record.get('revocation_pending')) is not bool:
                    raise ValueError('Stored authorization state is incomplete')

    def save(self):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=self.path.parent,
                                             prefix='.sync-', delete=False) as output:
                temporary = Path(output.name)
                json.dump(self.data, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def inventory(api, identity):
    users = user_list(api.call('/api/users'))
    owner = next((u for u in users if u['id'] == identity['recovery_owner_id']), None)
    if not owner or owner.get('role') != 'owner' or owner.get('is_service_user'):
        raise ValueError('Configured recovery owner is absent')
    if dex_identity(owner['id'])[1] != 'local':
        raise ValueError('Recovery owner must use the embedded connector')
    accounts = api.call('/api/accounts')
    if len(accounts) != 1:
        raise ValueError('Expected exactly one account')
    settings = accounts[0]['settings']
    if settings.get('local_auth_disabled', True) or settings.get('extra', {}).get('user_approval_required') is not True:
        raise ValueError('Embedded recovery and new-user approval must remain enabled')
    providers = api.call('/api/identity-providers')
    provider = next((p for p in providers if p['id'] == identity['provider_id']), None)
    if not provider or provider.get('issuer') != identity['cloudron'] + '/openid' or provider.get('type') != 'oidc':
        raise ValueError('Managed provider identity differs')
    if provider.get('client_id') != identity['client_id']:
        raise ValueError('Managed client identity differs')
    candidates = []
    for user in users:
        if user.get('idp_id') != identity['provider_id']:
            continue
        if user.get('role') == 'owner' or user.get('is_service_user'):
            raise ValueError('Managed connector contains an unsupported owner/service identity')
        subject, connector = dex_identity(user['id'])
        if connector != identity['provider_id']:
            raise ValueError('User connector metadata differs from subject')
        if type(user.get('pending_approval')) is not bool or type(user.get('is_blocked')) is not bool:
            raise ValueError('User authorization state missing')
        if not isinstance(user.get('auto_groups'), list) or user.get('role') not in ('user', 'admin', 'billing_admin', 'auditor', 'network_admin'):
            raise ValueError('Unsupported user update shape')
        candidates.append((user, subject))
    return candidates


def decisions(cloudron, candidates, state, adopt):
    app = cloudron.call('/api/v1/apps/' + segment(state['identity']['app_id']))
    app = app.get('app', app)
    target = urllib.parse.urlsplit(state['identity']['netbird'])
    if app.get('fqdn') != target.hostname or target.port not in (None, 443):
        raise RuntimeError('Cloudron app and canonical NetBird origin differ')
    if app.get('manifest', {}).get('id') != 'io.netbird.cloudronapp':
        raise RuntimeError('Source app is not the NetBird package')
    users = cloudron_users(cloudron)
    by_subject = {}
    for user in users:
        username = user.get('username')
        if username is None:
            continue
        if not isinstance(username, str) or not username or username in by_subject:
            raise ValueError('Source subject is missing or duplicated')
        by_subject[username] = user
    result = []
    for user, subject in candidates:
        source = by_subject.get(subject)
        record = state['users'].get(user['id'])
        if record is None:
            if source is None or (not user['pending_approval'] and not adopt):
                continue
            record = {'source_id': source['id'], 'subject': subject,
                      'blocked_by_sync': False, 'revocation_pending': False}
            state['users'][user['id']] = record
        allowed = bool(source and source['id'] == record['source_id'] and subject == record['subject'])
        if allowed:
            allowed = entitled(cloudron, source, state['identity']['app_id'])
        result.append((user, record, allowed))
    return result


def verify_revocations(netbird, store):
    pending = {identity for identity, record in store.data['users'].items() if record['revocation_pending']}
    if not pending:
        return
    users = {user['id']: user for user in user_list(netbird.call('/api/users'))}
    for identity in pending:
        user = users.get(identity)
        if not user or user.get('role') == 'owner' or user.get('is_service_user'):
            raise ValueError('Pending revocation target is absent or protected')
        if user.get('idp_id') != store.data['identity']['provider_id']:
            raise ValueError('Pending revocation target connector differs')
        if type(user.get('is_blocked')) is not bool or not isinstance(user.get('auto_groups'), list):
            raise ValueError('Pending revocation target state is incomplete')
        if not user['is_blocked']:
            result = netbird.call('/api/users/' + segment(identity), 'PUT',
                {'role': user['role'], 'auto_groups': user['auto_groups'], 'is_blocked': True})
            if result.get('is_blocked') is not True:
                raise ValueError('Retried user revocation was not confirmed')
    peers = netbird.call('/api/peers')
    if not isinstance(peers, list):
        raise ValueError('Peer revocation status unavailable')
    for identity in pending:
        if any(peer.get('user_id') == identity and peer.get('login_expired') is not True for peer in peers):
            raise ValueError('Peer expiration remains incomplete; operator reconciliation required')
        store.data['users'][identity]['revocation_pending'] = False
    store.save()


def reconcile(cloudron, netbird, store, apply=False, adopt=False):
    candidates = inventory(netbird, store.data['identity'])
    if apply and any(record['revocation_pending'] for record in store.data['users'].values()):
        verify_revocations(netbird, store)
        candidates = inventory(netbird, store.data['identity'])
    working = copy.deepcopy(store.data)
    degraded = False
    try:
        changes = decisions(cloudron, candidates, working, adopt)
    except (ValueError, KeyError, TypeError, OSError):
        # Do not adopt identities or grant access from a partial source snapshot.
        degraded = True
        working = copy.deepcopy(store.data)
        changes = [(u, working['users'][u['id']], False) for u, _ in candidates if u['id'] in working['users']]
    counts = {'approve': 0, 'block': 0, 'unblock': 0, 'manual_hold': 0}
    store.data = working
    if apply:
        store.save()  # Persist immutable binding before any authorization write.
    for user, record, allowed in sorted(changes, key=lambda change: change[2]):
        action = None
        if not allowed and not user['is_blocked']:
            action = 'block'
        elif allowed and user['is_blocked'] and not record['blocked_by_sync']:
            counts['manual_hold'] += 1
        elif allowed and user['pending_approval']:
            action = 'approve'
        elif allowed and user['is_blocked']:
            action = 'unblock'
        if action is None:
            continue
        counts[action] += 1
        if not apply:
            continue
        # Avoid overwriting role/group edits observed after the source snapshot.
        current = next(u for u in user_list(netbird.call('/api/users')) if u['id'] == user['id'])
        if any(current.get(k) != user.get(k) for k in ('role', 'auto_groups', 'idp_id', 'is_blocked', 'pending_approval')):
            raise ValueError('Concurrent target change; rerun from a fresh inventory')
        if action == 'block':
            record['blocked_by_sync'] = True
            record['revocation_pending'] = True
            store.save()
        path = '/api/users/' + segment(user['id'])
        if action == 'approve':
            netbird.call(path + '/approve', 'POST', {})
        else:
            netbird.call(path, 'PUT', {'role': current['role'], 'auto_groups': current['auto_groups'],
                                     'is_blocked': action == 'block'})
        if action in ('approve', 'unblock'):
            record['blocked_by_sync'] = False
            store.save()
    if apply:
        verify_revocations(netbird, store)
    return dict(mode='apply' if apply else 'plan', source_unavailable=degraded,
                managed_users=len(changes), unadopted_users=len(candidates) - len(changes), **counts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('cloudron-url', 'netbird-url', 'app-id', 'provider-id', 'client-id', 'recovery-owner-id', 'state'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--initialize', action='store_true', help='Explicitly create first ownership state; never use for recovery')
    parser.add_argument('--adopt-existing', action='store_true', help='Explicitly bind existing active connector users on bootstrap')
    parser.add_argument('--netbird-auth', choices=('Bearer', 'Token'), default='Token')
    args = parser.parse_args()
    identity = dict(cloudron=SSO.origin(args.cloudron_url), netbird=SSO.origin(args.netbird_url),
                    app_id=args.app_id, provider_id=args.provider_id, client_id=args.client_id,
                    recovery_owner_id=args.recovery_owner_id)
    for key in ('app_id', 'provider_id', 'client_id', 'recovery_owner_id'):
        segment(identity[key])
    path = Path(args.state).absolute()
    if path.parent.resolve() != path.parent or not path.parent.is_dir():
        raise ValueError('Create a private, non-symlink state directory first')
    parent = path.parent.stat()
    if parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
        raise ValueError('State directory must be owned by this user with mode 0700')
    cloudron = API(identity['cloudron'], os.environ['CLOUDRON_SYNC_TOKEN'])
    netbird = API(identity['netbird'], os.environ['NETBIRD_SYNC_TOKEN'], args.netbird_auth)
    descriptor = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.initialize and (not args.apply or path.exists()):
            raise ValueError('Initialization requires apply and an absent state file')
        if args.apply and not path.exists() and not args.initialize:
            raise ValueError('Ownership state missing; initialize explicitly or restore its protected backup')
        result = reconcile(cloudron, netbird, State(path, identity), args.apply, args.adopt_existing)
        print(json.dumps(result))
        return 1 if result['source_unavailable'] else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print('Access synchronization failed: ' + type(error).__name__ + '; details withheld; inspect retained state')
        raise SystemExit(1)
