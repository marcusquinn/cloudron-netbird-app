#!/usr/bin/env python3
"""Narrow, non-root regression checks for host ingress scope and recovery."""
import importlib.util
from pathlib import Path
import subprocess
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
