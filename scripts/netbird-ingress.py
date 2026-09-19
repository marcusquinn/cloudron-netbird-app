#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Opt-in host bridge for Cloudron NetBird. Never edits global nginx or routes.

Requires root, nftables, iptables-nft, HAProxy and systemd. Changes only its own
table, exact tagged INPUT rule, secondary /32 address and dedicated systemd units.
Install the source as /etc/netbird-ingress/netbird-ingress.py before enablement.
"""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/etc/netbird-ingress')
TABLE = 'netbird_ingress'
TAG = 'netbird-ingress-managed'


def run(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True, check=check, timeout=30)


def validate(c):
    for key in ('primary_ip', 'floating_ip'):
        ip = ipaddress.ip_address(c[key])
        if ip.version != 4 or not ip.is_global:
            raise ValueError(key + ' must be a public IPv4 address')
    if c['primary_ip'] == c['floating_ip']:
        raise ValueError('Floating IP must differ from primary IP')
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,12}', c['interface']):
        raise ValueError('Invalid interface name')
    for key in ('frontend_port', 'backend_port'):
        if type(c[key]) is not int or not 1024 <= c[key] <= 65535:
            raise ValueError('Use unprivileged TCP ports')
    if c['frontend_port'] == c['backend_port']:
        raise ValueError('Frontend and backend must be different ports')
    return c


def rules(c):
    ip, primary = c['floating_ip'], c['primary_ip']
    front, back, iface = c['frontend_port'], c['backend_port'], c['interface']
    return f'''table inet {TABLE} {{
    chain ingress_guard {{
        type filter hook prerouting priority -150; policy accept;
        iifname != "lo" ip saddr {ip} counter drop comment "reject forged host identity"
        iifname != "lo" fib daddr type local tcp dport {{ {front}, {back} }} counter drop comment "backend is host-only including IPv6"
        ip daddr {ip} ct state established,related accept
        ip daddr {ip} iifname "{iface}" tcp dport 443 accept
        ip daddr {ip} counter drop comment "IP2 serves only HTTPS"
    }}
    chain destination_nat {{
        type nat hook prerouting priority -110; policy accept;
        iifname "{iface}" ip daddr {ip} tcp dport 443 counter dnat ip to {ip}:{front}
    }}
    chain input_guard {{
        type filter hook input priority -10; policy accept;
        ip daddr {ip} tcp dport 443 counter drop comment "fail closed without DNAT"
        ip daddr {ip} tcp dport {front} ct original ip daddr {ip} ct original proto-dst 443 accept
        ip daddr {ip} ct state established,related accept
        ip daddr {ip} counter drop
    }}
    chain preserve_host_source {{
        type nat hook postrouting priority 90; policy accept;
        ip saddr {ip} ct original ip daddr {primary} ct original proto-dst {back} counter snat ip to {ip}
    }}
}}
'''


def haproxy(c):
    return f'''global
    maxconn 1024
    user nobody
    group nogroup
    log stdout format raw local0
defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h
frontend netbird_tls
    bind {c['floating_ip']}:{c['frontend_port']}
    default_backend netbird_proxy
backend netbird_proxy
    source {c['floating_ip']}
    server app {c['primary_ip']}:{c['backend_port']} send-proxy-v2
'''


def allowance(c):
    return ['-i', c['interface'], '-d', c['floating_ip'], '-p', 'tcp', '--dport', str(c['frontend_port']),
            '-m', 'conntrack', '--ctorigdst', c['floating_ip'], '--ctorigdstport', '443',
            '-m', 'comment', '--comment', TAG, '-j', 'ACCEPT']


def addresses(c):
    d = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', c['interface']).stdout)
    return d[0].get('addr_info', [])


def config():
    return validate(json.loads((ROOT / 'config.json').read_text()))


def rule_signature():
    def normalize(value):
        if isinstance(value, dict):
            return {k: normalize(v) for k, v in value.items() if k not in ('handle', 'packets', 'bytes')}
        if isinstance(value, list):
            return [normalize(v) for v in value if not (isinstance(v, dict) and 'metainfo' in v)]
        return value
    return normalize(json.loads(run('nft', '-j', 'list', 'table', 'inet', TABLE).stdout))


def allowance_precedes_cloudron():
    lines = run('iptables', '-S', 'INPUT').stdout.splitlines()
    ours = next((i for i, line in enumerate(lines) if TAG in line), len(lines))
    cloudron = next((i for i, line in enumerate(lines) if line.endswith('-j CLOUDRON')), len(lines))
    return ours < cloudron


def preflight(c):
    if os.geteuid() != 0:
        raise ValueError('Host operations require root')
    for executable in ('nft', 'iptables', 'ip', 'haproxy', 'systemctl'):
        if not shutil.which(executable):
            raise ValueError('Missing dependency: ' + executable)
    if 'nf_tables' not in run('iptables', '--version').stdout:
        raise ValueError('Only verified iptables-nft hosts are supported')
    if not any(a['local'] == c['primary_ip'] for a in addresses(c)):
        raise ValueError('Primary IP does not match the selected interface')
    # Detect accidental reuse of an address owned by some other configuration.
    for a in addresses(c):
        if a['local'] == c['floating_ip'] and a.get('label') != c['interface'] + ':nb':
            raise ValueError('Floating IP already exists outside this helper')


def require_unused_ports(c):
    """Check listeners and Docker bindings before reserving host-wide ports."""
    ports = {c['frontend_port'], c['backend_port']}
    for line in run('ss', '-H', '-lnt').stdout.splitlines():
        fields = line.split()
        if len(fields) < 4:
            raise ValueError('Unrecognized TCP listener output; cannot reserve ports')
        port = fields[3].rsplit(':', 1)[-1]
        if port.isdigit() and int(port) in ports:
            raise ValueError('Ingress port is already occupied by a TCP listener: ' + port)
    # Include stopped containers and bindings with no userspace proxy listener.
    # Inspect only port metadata, never log complete container configuration.
    for container in run('docker', 'ps', '-aq').stdout.split():
        bindings = json.loads(run('docker', 'inspect', '--format',
                                 '{{json .HostConfig.PortBindings}}', container).stdout)
        for target, entries in (bindings or {}).items():
            if not target.endswith('/tcp'):
                continue
            for binding in entries or []:
                port = binding.get('HostPort', '')
                if not port.isdigit():
                    raise ValueError('Unresolved Docker TCP binding; cannot reserve ports')
                if int(port) in ports:
                    raise ValueError('Ingress port is already reserved by a Docker container: ' + port)


def up(c):
    preflight(c)
    exists = run('nft', 'list', 'table', 'inet', TABLE, check=False).returncode == 0
    if not exists:
        require_unused_ports(c)
    text = ('delete table inet ' + TABLE + '\n' if exists else '') + rules(c)
    run('nft', '--check', '-f', '-', data=text)
    run('haproxy', '-c', '-f', str(ROOT / 'haproxy.cfg'))
    # The batch replacement is atomic. Never flush Cloudron's/Docker's tables.
    run('nft', '-f', '-', data=text)
    (ROOT / 'installed-rules.json').write_text(json.dumps(rule_signature(), sort_keys=True))
    args = allowance(c)
    if not allowance_precedes_cloudron():
        while run('iptables', '-w', '5', '-C', 'INPUT', *args, check=False).returncode == 0:
            run('iptables', '-w', '5', '-D', 'INPUT', *args)
    if run('iptables', '-w', '5', '-C', 'INPUT', *args, check=False).returncode:
        run('iptables', '-w', '5', '-I', 'INPUT', '1', *args)
    if not any(a['local'] == c['floating_ip'] for a in addresses(c)):
        run('ip', 'address', 'add', c['floating_ip'] + '/32', 'dev', c['interface'],
            'label', c['interface'] + ':nb')
    print('Ingress rules and secondary address active; primary address/routes unchanged')


def down(c):
    # Remove only our labelled address first so nginx cannot inherit its ingress.
    for a in addresses(c):
        if a['local'] == c['floating_ip'] and a.get('label') == c['interface'] + ':nb':
            run('ip', 'address', 'del', c['floating_ip'] + '/32', 'dev', c['interface'])
    args = allowance(c)
    while run('iptables', '-w', '5', '-C', 'INPUT', *args, check=False).returncode == 0:
        run('iptables', '-w', '5', '-D', 'INPUT', *args)
    # Retain the guard table: published app ports must stay protected even if
    # the bridge is stopped. Remove only after disabling the app's PROXY_PORT.
    print('Secondary address and exact INPUT allowance removed; backend guard retained')


def check(c):
    preflight(c)
    if rule_signature() != json.loads((ROOT / 'installed-rules.json').read_text()):
        raise ValueError('Managed firewall rules have drifted')
    run('iptables', '-w', '5', '-C', 'INPUT', *allowance(c))
    if not allowance_precedes_cloudron():
        raise ValueError('INPUT allowance no longer precedes Cloudron policy')
    if not any(a['local'] == c['floating_ip'] for a in addresses(c)):
        raise ValueError('Secondary address is absent')
    run('haproxy', '-c', '-f', str(ROOT / 'haproxy.cfg'))
    print('Ingress guard, INPUT allowance, address and HAProxy configuration verified')


def reconcile(c):
    # Respect an intentional stop/rollback. Never reactivate a stopped ingress.
    if run('systemctl', 'is-active', '--quiet', 'netbird-ingress.service', check=False).returncode:
        return
    try:
        check(c)
    except (ValueError, OSError, subprocess.SubprocessError):
        up(c)
        check(c)
        print('Repaired managed ingress drift')


def install(c):
    preflight(c)
    if ROOT.exists():
        if not (ROOT / 'config.json').exists() or config() != c:
            raise ValueError('Refusing to overwrite unknown/different host configuration')
    else:
        if run('nft', 'list', 'table', 'inet', TABLE, check=False).returncode == 0:
            raise ValueError('Refusing to adopt an existing foreign nftables table')
        require_unused_ports(c)
        ROOT.mkdir(mode=0o700)
    snapshot = ROOT / 'before.json'
    if not snapshot.exists():
        snapshot.write_text(json.dumps({
            'addresses': json.loads(run('ip', '-j', 'address').stdout),
            'routes': json.loads(run('ip', '-j', 'route').stdout),
            'iptables': run('iptables-save').stdout,
            'nftables': run('nft', 'list', 'ruleset').stdout,
        }, indent=2))
        snapshot.chmod(0o600)
    source = Path(__file__).resolve()
    dest = ROOT / 'netbird-ingress.py'
    if source != dest:
        staging = dest.with_suffix('.py.new')
        shutil.copyfile(source, staging)
        os.replace(staging, dest)
    for name, text in [('config.json', json.dumps(c, indent=2) + '\n'),
                       ('haproxy.cfg', haproxy(c)), ('rules.nft', rules(c))]:
        path = ROOT / name
        staging = path.with_suffix(path.suffix + '.new')
        staging.write_text(text)
        staging.chmod(0o600)
        os.replace(staging, path)
    # Start guard before adding address, and before starting HAProxy. This unit
    # does not restart Docker/Cloudron or change their configurations.
    units = {
        'netbird-ingress.service': '''[Unit]
Description=NetBird secondary-IP ingress guard
After=network-online.target docker.service cloudron-firewall.service nftables.service
Wants=network-online.target
Before=netbird-tcp-bridge.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /etc/netbird-ingress/netbird-ingress.py up
ExecStop=/usr/bin/python3 /etc/netbird-ingress/netbird-ingress.py down
[Install]
WantedBy=multi-user.target
''',
        'netbird-tcp-bridge.service': '''[Unit]
Description=NetBird transparent TLS bridge
Requires=netbird-ingress.service
After=netbird-ingress.service
[Service]
Type=simple
ExecStartPre=/usr/bin/python3 /etc/netbird-ingress/netbird-ingress.py check
ExecStart=/usr/sbin/haproxy -W -db -f /etc/netbird-ingress/haproxy.cfg
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/run/lock/netbird-ingress.lock
ProtectHome=true
PrivateTmp=true
MemoryMax=256M
[Install]
WantedBy=multi-user.target
''',
        'netbird-ingress-check.service': '''[Unit]
Description=NetBird managed ingress reconciliation
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /etc/netbird-ingress/netbird-ingress.py reconcile
''',
        'netbird-ingress-check.timer': '''[Unit]
Description=NetBird managed ingress drift check
[Timer]
OnBootSec=60s
OnUnitActiveSec=30s
AccuracySec=2s
[Install]
WantedBy=timers.target
'''}
    for name, text in units.items():
        path = Path('/etc/systemd/system') / name
        if path.exists() and 'NetBird' not in path.read_text():
            raise ValueError('Refusing to overwrite foreign unit: ' + name)
        path.write_text(text)
    run('systemctl', 'daemon-reload')
    run('haproxy', '-c', '-f', str(ROOT / 'haproxy.cfg'))
    print('Installed, not activated. Start netbird-ingress then netbird-tcp-bridge; enable only after verification.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['render', 'install', 'up', 'down', 'check', 'reconcile'])
    parser.add_argument('--primary-ip')
    parser.add_argument('--floating-ip')
    parser.add_argument('--interface', default='eth0')
    parser.add_argument('--frontend-port', type=int, default=18443)
    parser.add_argument('--backend-port', type=int, default=18444)
    args = parser.parse_args()
    if args.action in ('render', 'install'):
        c = validate(dict(primary_ip=args.primary_ip, floating_ip=args.floating_ip,
                          interface=args.interface, frontend_port=args.frontend_port, backend_port=args.backend_port))
    else:
        c = config()
    if args.action == 'render':
        print(rules(c) + '\n# HAProxy\n' + haproxy(c))
    else:
        if os.geteuid() != 0:
            raise ValueError('Host operations require root')
        with open('/run/lock/netbird-ingress.lock', 'a', encoding='utf-8') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            {'install': install, 'up': up, 'down': down, 'check': check, 'reconcile': reconcile}[args.action](c)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('Ingress operation failed: ' + str(exc), file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError):
            print(exc.stderr, file=sys.stderr)
        sys.exit(1)
