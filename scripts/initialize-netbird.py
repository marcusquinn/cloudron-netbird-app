#!/usr/bin/env python3
"""Initialize a local-only NetBird owner over SSH; store password in gopass."""
import argparse
import json
import re
import secrets
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--app', required=True)
    parser.add_argument('--email', required=True)
    parser.add_argument('--secret-name', required=True)
    args = parser.parse_args()
    assert re.fullmatch(r'[a-z0-9.-]+', args.host)
    assert re.fullmatch(r'[a-f0-9-]{36}', args.app)
    assert re.fullmatch(r'[A-Z0-9_]+', args.secret_name)
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', 'root@' + args.host]

    def request(path, data=None):
        code = ('import sys,json,urllib.request; data=json.load(sys.stdin); '
                'r=urllib.request.Request("http://127.0.0.1:8080"+data["path"],'
                'data=None if data["body"] is None else json.dumps(data["body"]).encode(),'
                'headers={"Content-Type":"application/json"}); '
                'print(urllib.request.urlopen(r,timeout=15).read().decode())')
        command = shlex.join(['docker', 'exec', '-i', args.app, 'python3', '-c', code])
        r = subprocess.run(ssh + [command], input=json.dumps({'path': path, 'body': data}),
                           text=True, capture_output=True, timeout=25)
        if r.returncode:
            raise RuntimeError('App-local request failed (response withheld)')
        return json.loads(r.stdout)

    if not request('/api/instance').get('setup_required'):
        print('Owner already initialized; no changes made')
        return
    store = 'aidevops/' + args.secret_name
    saved = subprocess.run(['gopass', 'show', '-o', store], capture_output=True, text=True, timeout=60)
    password = saved.stdout.strip() if saved.returncode == 0 else secrets.token_urlsafe(36)
    if not password:
        raise RuntimeError('Empty stored credential')
    if saved.returncode:
        subprocess.run(['gopass', 'insert', '--force', store], input=password + '\n',
                       capture_output=True, text=True, timeout=60, check=True)
    result = request('/api/setup', {'email': args.email, 'name': 'NetBird Administrator', 'password': password})
    assert result.get('user_id') and result.get('email') == args.email
    print(json.dumps({'initialized': True, 'email': args.email, 'secret_name': args.secret_name}))


if __name__ == '__main__':
    main()
