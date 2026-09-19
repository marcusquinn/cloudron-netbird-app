#!/usr/bin/env python3
"""Explicit opt-in live proxy test using a disposable local Docker peer.

Creates then removes one setup key, peer, proxy service and two labelled local
containers. The HTTP target contains only a random test marker. No host ports
are published. API bearer token comes only from the environment.
"""
import argparse
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

CLIENT = 'netbirdio/netbird:0.79.0@sha256:9d8480d87b7f7c10d67b820eecf332ecca5c2756792d4bdfa532182b4fc3005f'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--management-url', required=True)
    p.add_argument('--api-url', required=True)
    p.add_argument('--service-domain', required=True)
    p.add_argument('--fixture-image', default='cloudron-netbird:single-vps-dev')
    p.add_argument('--budget', type=int, default=120)
    a = p.parse_args()
    owner = secrets.token_hex(8)
    name = 'netbird-live-' + owner
    marker = 'netbird-proxy-verified-' + owner
    deadline = time.monotonic() + a.budget
    resources = []
    containers = []
    auth = {'Authorization': 'Bearer ' + os.environ['NETBIRD_API_TOKEN'],
            'Content-Type': 'application/json'}

    def api(path, method='GET', body=None):
        r = urllib.request.Request(a.api_url + path, method=method, headers=auth,
            data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(r, timeout=15) as response:
            data = response.read()
            return json.loads(data) if data else None

    def docker(*args, env=None, check=True):
        r = subprocess.run(['docker', *args], env=env, capture_output=True, text=True, timeout=25)
        if check and r.returncode:
            raise RuntimeError('Docker operation failed (sensitive output withheld)')
        return r

    def wait(probe, description):
        while time.monotonic() < deadline:
            result = probe()
            if result:
                return result
            time.sleep(2)
        raise RuntimeError('Timed out: ' + description)

    try:
        assert not any(s['domain'] == a.service_domain for s in api('/api/reverse-proxies/services')), 'Test service already exists'
        key = api('/api/setup-keys', 'POST', dict(name=name, type='one-off', expires_in=3600,
            auto_groups=[], usage_limit=1, ephemeral=True))
        resources.append(('/api/setup-keys/' + key['id'], 'key'))
        containers.append(name)
        docker('run', '-d', '--name', name, '--hostname', name, '--label', 'netbird.live-test=' + owner,
            '--memory', '384m', '--cpus', '1', '--cap-add', 'NET_ADMIN', '--device', '/dev/net/tun',
            '--env', 'NB_SETUP_KEY', '--env', 'NB_MANAGEMENT_URL=' + a.management_url,
            '--env', 'NB_LOG_FILE=console', CLIENT, env=dict(os.environ, NB_SETUP_KEY=key['key']))
        del key

        def peer_ready():
            peers = api('/api/peers')
            return next((x for x in peers if x.get('hostname') == name and x.get('connected')), None)

        peer = wait(peer_ready, 'native client registration')
        resources.append(('/api/peers/' + peer['id'], 'peer'))
        print('PASS: native peer registered over dedicated TLS transport', flush=True)
        fixture = name + '-http'
        containers.append(fixture)
        code = ('from http.server import BaseHTTPRequestHandler,HTTPServer\n'
                'class H(BaseHTTPRequestHandler):\n'
                ' def do_GET(self):\n'
                '  self.send_response(200); self.end_headers(); self.wfile.write(' + repr(marker.encode()) + ')\n'
                ' def log_message(self,*args): pass\n'
                'HTTPServer(("0.0.0.0",8088),H).serve_forever()')
        docker('run', '-d', '--name', fixture, '--label', 'netbird.live-test=' + owner,
            '--network', 'container:' + name, '--read-only', '--memory', '64m', '--cpus', '0.25',
            '--entrypoint', 'python3', a.fixture_image, '-c', code)
        service_request = dict(name=name,
            domain=a.service_domain, enabled=True, mode='http', auth={}, targets=[dict(
                target_id=peer['id'], target_type='peer', port=8088, protocol='http', enabled=True, path='/')])
        service = api('/api/reverse-proxies/services', 'POST', service_request)
        resources.append(('/api/reverse-proxies/services/' + service['id'], 'service'))
        print('Created disposable service; waiting for publicly trusted TLS and peer traffic', flush=True)

        def reachable(headers=None):
            try:
                request = urllib.request.Request('https://' + a.service_domain + '/', headers=headers or {})
                with urllib.request.urlopen(request, timeout=8) as r:
                    return r.status == 200 and r.read().decode() == marker
            except (urllib.error.URLError, TimeoutError):
                return False

        wait(reachable, 'public TLS -> proxy -> WireGuard peer -> fixture')
        result = api('/api/reverse-proxies/services/' + service['id'])
        print(json.dumps({'result': 'PASS', 'domain': a.service_domain, 'meta': result.get('meta'),
                          'path': 'public TLS -> host TCP bridge -> app proxy -> remote Docker peer'}), flush=True)
        path = '/api/reverse-proxies/services/' + service['id']
        header_value = secrets.token_urlsafe(24)
        service_request['auth'] = {'header_auths': [{'enabled': True, 'header': 'X-Smoke-Auth', 'value': header_value}]}
        api(path, 'PUT', service_request)
        def denied(headers=None):
            # A network/TLS outage is not proof that access policy denied us.
            try:
                request = urllib.request.Request('https://' + a.service_domain + '/', headers=headers or {})
                with urllib.request.urlopen(request, timeout=8):
                    return False
            except urllib.error.HTTPError as exc:
                return exc.code in (401, 403)
            except (urllib.error.URLError, TimeoutError):
                return False

        wait(denied, 'reject unauthenticated request')
        assert denied({'X-Smoke-Auth': 'wrong'}), 'Wrong auth was not explicitly denied'
        valid_headers = {'X-Smoke-Auth': header_value}
        wait(lambda: reachable(valid_headers), 'accept correct header authentication')
        print('PASS: missing/wrong authentication denied; correct authentication succeeds', flush=True)
        service_request['access_restrictions'] = {'allowed_cidrs': ['198.51.100.254/32']}
        api(path, 'PUT', service_request)
        wait(lambda: denied(valid_headers), 'IP restriction enforced')
        assert denied(dict(valid_headers, **{'X-Forwarded-For': '198.51.100.254', 'X-Real-IP': '198.51.100.254'})), 'Forged client IP was not explicitly denied'
        service_request['access_restrictions'] = {}
        api(path, 'PUT', service_request)
        wait(lambda: reachable(valid_headers), 'traffic recovers after removing test restriction')
        print('PASS: IP restrictions cannot be bypassed by forged forwarding headers', flush=True)
    finally:
        failures = []
        # Recover IDs if a creation response timed out after the server committed.
        for collection, kind in [('/api/setup-keys', 'key'), ('/api/peers', 'peer'),
                                 ('/api/reverse-proxies/services', 'service')]:
            try:
                for item in api(collection):
                    if item.get('name') == name or item.get('hostname') == name:
                        entry = (collection + '/' + item['id'], kind)
                        if entry not in resources:
                            resources.append(entry)
            except Exception:
                failures.append(kind + ':reconciliation')
        # Services go first, then containers and peers, then the spent setup key.
        for path, kind in reversed(resources):
            try:
                api(path, 'DELETE')
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    failures.append(kind + ':HTTP' + str(exc.code))
            except Exception:
                failures.append(kind)
        for container in reversed(containers):
            r = docker('inspect', '--format', '{{index .Config.Labels "netbird.live-test"}}', container, check=False)
            if r.returncode == 0 and r.stdout.strip() == owner:
                if docker('rm', '-f', container, check=False).returncode:
                    failures.append('container:' + container)
        if failures:
            raise RuntimeError('CLEANUP INCOMPLETE: ' + ', '.join(failures))
        else:
            print('PASS: disposable API resources and labelled containers cleaned up', flush=True)


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as exc:
        # These endpoints can return setup keys: never print response bodies.
        print('FAIL: API HTTP ' + str(exc.code) + ' (response withheld)', file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print('FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(1)
