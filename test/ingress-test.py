#!/usr/bin/env python3
"""Narrow, non-root regression checks for host ingress scope and recovery."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ingress', Path(__file__).resolve().parents[1] / 'scripts/netbird-ingress.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class IngressTest(unittest.TestCase):
    def setUp(self):
        self.config = dict(primary_ip='1.1.1.1', floating_ip='9.9.9.9', interface='eth0',
                           frontend_port=18443, backend_port=18444)

    def test_invalid_inputs(self):
        for update in [dict(floating_ip='1.1.1.1'), dict(floating_ip='127.0.0.1'),
                       dict(primary_ip='::1'), dict(interface='eth0; reboot'),
                       dict(frontend_port=443), dict(backend_port=18443)]:
            with self.subTest(update=update), self.assertRaises(ValueError):
                M.validate(self.config | update)

    def test_scope_and_nat_order(self):
        text = M.rules(M.validate(self.config))
        self.assertIn('priority -150', text)
        self.assertIn('priority -110', text)
        self.assertIn('priority 90', text)
        self.assertIn('fib daddr type local tcp dport { 18443, 18444 }', text)
        self.assertIn('ip daddr 9.9.9.9 tcp dport 443 counter dnat ip to 9.9.9.9:18443', text)
        self.assertNotIn('ip daddr 1.1.1.1 tcp dport 443', text)
        self.assertNotIn('flush ruleset', text)
        self.assertNotIn('127.0.0.1', text)
        self.assertIn('ip saddr 9.9.9.9 counter drop', text)

    def test_tcp_bridge_preserves_tls_and_source(self):
        text = M.haproxy(self.config)
        self.assertIn('mode tcp', text)
        self.assertIn('source 9.9.9.9', text)
        self.assertIn('send-proxy-v2', text)
        self.assertNotIn(' ssl', text)

    def test_protection_defaults_and_limits(self):
        config = M.validate(dict(self.config))
        self.assertEqual(config['connections_per_ip'], 64)
        self.assertEqual(config['connections_per_10s'], 60)
        for update in (dict(connections_per_ip=0), dict(connections_per_10s=-1),
                       dict(max_connections=True), dict(max_connections=1, connections_per_ip=2),
                       dict(deny_cidrs=['0.0.0.0/0']), dict(deny_cidrs=['::/0'])):
            with self.subTest(update=update), self.assertRaises(ValueError):
                M.validate(dict(self.config, **update))

    def test_denylist_precedes_established_and_only_targets_public_ingress(self):
        text = M.rules(dict(self.config, deny_cidrs=['203.0.113.0/24']))
        self.assertIn('elements = { 203.0.113.0/24 }', text)
        self.assertIn('iifname "eth0" ip daddr 9.9.9.9 ip saddr @blocked_sources', text)
        self.assertLess(text.index('ip saddr @blocked_sources'), text.index('ct state established,related'))

    def test_limits_apply_to_tls_bridge_not_native_transport(self):
        text = M.haproxy(self.config)
        self.assertIn('conn_rate(10s)', text)
        self.assertIn('sc0_conn_cur gt 64', text)
        self.assertIn('sc0_conn_rate gt 60', text)
        self.assertNotIn('33073', text)
        self.assertNotIn('3479', text)

    def test_protection_cannot_change_network_identity(self):
        with self.assertRaises(ValueError):
            M.protect(self.config, dict(primary_ip='8.8.8.8'))

    def test_proxy_statistics_are_private_and_aggregate(self):
        self.assertIn('stats socket /run/netbird-ingress/stats.sock mode 600 level user', M.haproxy(self.config))
        with patch.object(M.socket, 'socket') as factory:
            connection = factory.return_value.__enter__.return_value
            connection.recv.side_effect = [b'# pxname,svname,scur,stot,dcon,dses\n'
                                           b'netbird_tls,FRONTEND,1,80,20,0\n', b'']
            self.assertEqual(M.proxy_counters()['denied_connections'], 20)
            connection.sendall.assert_called_once_with(b'show stat\n')

    def test_missing_rejection_counter_fails_closed(self):
        with patch.object(M.socket, 'socket') as factory:
            factory.return_value.__enter__.return_value.recv.side_effect = [
                b'# pxname,svname,scur,stot\nnetbird_tls,FRONTEND,1,80\n', b'']
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                M.proxy_counters()

    def test_protection_reload_failure_restores_owned_files(self):
        config = M.validate(dict(self.config))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            originals = {'config.json': json.dumps(config), 'haproxy.cfg': M.haproxy(config), 'rules.nft': M.rules(config)}
            for name, text in originals.items():
                (root / name).write_text(text)
            failed = False

            def run(*args, **kwargs):
                nonlocal failed
                if args[:2] == ('systemctl', 'reload') and not failed:
                    failed = True
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0, stdout='')

            with patch.object(M, 'ROOT', root), patch.object(M, 'preflight'), \
                 patch.object(M, 'run', side_effect=run), patch.object(M, 'up') as up:
                with self.assertRaises(subprocess.CalledProcessError):
                    M.protect(config, dict(connections_per_ip=32))
                self.assertEqual(up.call_count, 2)
                self.assertEqual(up.call_args_list[-1].args[0], config)
            for name, text in originals.items():
                self.assertEqual((root / name).read_text(), text)

    def test_stopped_service_never_reactivated(self):
        with patch.object(M, 'run', return_value=subprocess.CompletedProcess([], 3)), patch.object(M, 'up') as up:
            M.reconcile(self.config)
            up.assert_not_called()

    def test_drift_repaired_only_when_service_active(self):
        with patch.object(M, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(M, 'check', side_effect=[ValueError('drift'), None]), patch.object(M, 'up') as up:
            M.reconcile(self.config)
            up.assert_called_once_with(self.config)

    def test_first_activation_rejects_host_listener_before_mutation(self):
        for address in ('0.0.0.0:18443', '[::]:18444', '127.0.0.1:18444'):
            def fake_run(*args, **kwargs):
                if args[0] == 'nft':
                    return subprocess.CompletedProcess(args, 1, stdout='')
                return subprocess.CompletedProcess(args, 0, stdout=f'LISTEN 0 128 {address} *:*\n')
            with self.subTest(address=address), patch.object(M, 'preflight'), \
                 patch.object(M, 'run', side_effect=fake_run) as run:
                with self.assertRaisesRegex(ValueError, 'already occupied'):
                    M.up(self.config)
                self.assertEqual([call.args[0] for call in run.call_args_list], ['nft', 'ss'])

    def test_docker_bindings_detected_without_listeners(self):
        results = [subprocess.CompletedProcess([], 0, stdout=''),
                   subprocess.CompletedProcess([], 0, stdout='fixture-id\n'),
                   subprocess.CompletedProcess([], 0, stdout='{"8443/tcp":[{"HostIp":"::","HostPort":"18444"}]}')]
        with patch.object(M, 'run', side_effect=results), self.assertRaisesRegex(ValueError, 'reserved by a Docker'):
            M.require_unused_ports(self.config)

    def test_unused_ports_can_be_reserved(self):
        with patch.object(M, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')) as run:
            M.require_unused_ports(self.config)
            self.assertEqual([call.args[0] for call in run.call_args_list], ['ss', 'docker'])

    def test_unavailable_port_inventory_fails_closed(self):
        with patch.object(M, 'run', side_effect=subprocess.CalledProcessError(1, 'ss')), \
             self.assertRaises(subprocess.CalledProcessError):
            M.require_unused_ports(self.config)

    def test_down_drops_address_first_and_retains_guard(self):
        result = subprocess.CompletedProcess([], 1)
        with patch.object(M, 'addresses', return_value=[dict(local='9.9.9.9', label='eth0:nb')]), \
             patch.object(M, 'run', return_value=result) as run:
            M.down(self.config)
            self.assertEqual(run.call_args_list[0].args[:4], ('ip', 'address', 'del', '9.9.9.9/32'))
            self.assertFalse(any(c.args[0] == 'nft' for c in run.call_args_list))


if __name__ == '__main__':
    unittest.main()
