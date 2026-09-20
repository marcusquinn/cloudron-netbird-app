"""Opt-in, bounded host-protection checks for an explicitly supplied SSH host."""
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import re
import shlex
import socket
import ssl
import subprocess
import time

REMOTE = '''import fcntl,importlib.util,json,os
spec=importlib.util.spec_from_file_location('ingress','/etc/netbird-ingress/netbird-ingress.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import sys
data=json.load(sys.stdin)
with open('/run/lock/netbird-ingress.lock','a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    c=m.config()
    if data['action']=='change':
        if c['deny_cidrs']!=data['desired']:
            if c['deny_cidrs']!=data['expected']:
                raise ValueError('Concurrent denylist change; refusing overwrite')
            m.protect(c,{'deny_cidrs':data['desired']})
    elif data['action']=='snapshot':
        print(json.dumps({'deny':c['deny_cidrs'],'ip':c['floating_ip'],'source':os.environ['SSH_CONNECTION'].split()[0],
                          'rate':c['connections_per_10s'],'concurrent':c['connections_per_ip']}))
    elif data['action']=='counters':
        nft=json.loads(m.run('nft','-j','list','table','inet',m.TABLE).stdout)
        packets=sum(e['counter']['packets'] for item in nft.get('nftables',[]) for r in [item.get('rule',{})]
                    if r.get('comment')=='managed public-ingress denylist' for e in r.get('expr',[]) if 'counter' in e)
        print(json.dumps({'deny_packets':packets,'proxy_rejections':m.proxy_counters()['denied_connections']}))
    else:
        raise ValueError('Unsupported test action')
'''


def remote(host, payload):
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+', host):
        raise ValueError('Invalid ingress SSH host')
    result = subprocess.run(['ssh', '-4', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                             '-o', 'ConnectTimeout=10', 'root@' + host, 'python3 -c ' + shlex.quote(REMOTE)],
                            input=json.dumps(payload), text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError('Ingress test SSH operation failed; details withheld; inspect managed protection state')
    return json.loads(result.stdout) if payload['action'] != 'change' else None


def tls(address, hostname, context=None):
    with socket.create_connection((address, 443), timeout=3) as connection:
        with (context or ssl.create_default_context()).wrap_socket(connection, server_hostname=hostname):
            return True


def check(host, domain, run_id):
    before = remote(host, dict(action='snapshot'))
    addresses = {r[4][0] for r in socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)}
    if addresses != {before['ip']}:
        raise ValueError('Service DNS does not exclusively match the supplied host ingress IP')
    if before['rate'] != 60 or before['concurrent'] < 16:
        raise ValueError('Bounded live test requires the default 60/10s rate and at least 16 concurrent connections')
    address = before['ip']
    tls(address, domain)
    unknown = 'unconfigured-' + run_id + '.' + domain.split('.', 1)[1]
    try:
        tls(address, unknown)
    except ssl.SSLCertVerificationError as exc:
        raise RuntimeError('Unknown name received a certificate instead of server rejection') from exc
    except (ssl.SSLError, ConnectionResetError):
        pass
    else:
        raise RuntimeError('Unknown SNI was accepted')
    tls(address, domain)
    print('PASS: unknown SNI rejected between successful verified TLS handshakes', flush=True)

    source = ipaddress.ip_address(before['source'])
    if source.version != 4:
        raise ValueError('Expected the explicit IPv4 SSH source')
    augmented = [str(n) for n in ipaddress.collapse_addresses(
        [ipaddress.ip_network(c) for c in before['deny']] + [ipaddress.ip_network(str(source) + '/32')])]
    try:
        remote(host, dict(action='change', expected=before['deny'], desired=augmented))
        try:
            tls(address, domain)
        except (TimeoutError, ConnectionError):
            pass
        else:
            raise RuntimeError('Denylisted source still reached TLS')
        if remote(host, dict(action='counters'))['deny_packets'] < 1:
            raise RuntimeError('No explicit denylist drop-counter evidence')
    finally:
        remote(host, dict(action='change', expected=augmented, desired=before['deny']))
    tls(address, domain)
    print('PASS: source denylist dropped traffic; original list restored and TLS recovered', flush=True)

    time.sleep(11)  # Start a new bounded rate window, not a CI polling interval.
    rejections_before = remote(host, dict(action='counters'))['proxy_rejections']
    # Loading the system trust store per connection can spread a supposed burst
    # over several rate windows. Share this read-only context across eight clients.
    context = ssl.create_default_context()

    def attempt(_):
        try:
            return tls(address, domain, context)
        except (OSError, TimeoutError):
            return False

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(attempt, range(80)))
    rejections_after = remote(host, dict(action='counters'))['proxy_rejections']
    if not any(results) or all(results) or rejections_after <= rejections_before:
        raise RuntimeError('Connection-limit evidence incomplete: successes=' + str(sum(results)) +
                           ', denied_connection_delta=' + str(rejections_after - rejections_before))
    time.sleep(11)
    tls(address, domain)
    print(json.dumps({'result': 'PASS', 'bounded_attempts': 80, 'successful_tls': sum(results),
                      'rejected_tls': len(results) - sum(results),
                      'denied_connection_delta': rejections_after - rejections_before}), flush=True)
