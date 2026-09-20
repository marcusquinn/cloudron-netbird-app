#!/usr/bin/env python3
"""Synthetic API/state fixtures; no network, credentials or user mutation."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('sso', Path(__file__).resolve().parents[1] / 'scripts/cloudron-sso.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class Store:
    def __init__(self):
        self.value = None

    def load(self):
        return copy.deepcopy(self.value)

    def save(self, value):
        self.value = copy.deepcopy(value)


class Cloudron:
    base = 'https://cloudron.example.invalid'

    def __init__(self):
        self.clients = {}
        self.count = 0
        self.lose_create_response = False

    def call(self, path, method='GET', body=None):
        if method == 'POST' and path != '/api/v1/oidc/clients':
            identity = path.rsplit('/', 1)[-1]
            self.clients[identity].update(body)
            return {}
        if method == 'POST':
            self.count += 1
            client = dict(body, id='client-' + str(self.count), secret='synthetic-value', appId='')
            self.clients[client['id']] = client
            if self.lose_create_response:
                self.lose_create_response = False
                raise TimeoutError('synthetic response lost')
            return copy.deepcopy(client)
        if path == '/api/v1/oidc/clients':
            return {'clients': copy.deepcopy(list(self.clients.values()))}
        identity = path.rsplit('/', 1)[-1]
        if method == 'DELETE':
            del self.clients[identity]
            return None
        return copy.deepcopy(self.clients[identity])


class NetBird:
    base = 'https://netbird.example.invalid'

    def __init__(self):
        self.providers = {}
        self.count = 0
        self.role = 'owner'
        self.settings = dict(local_auth_disabled=False, extra=dict(user_approval_required=True))
        self.fail_update = False
        self.lose_create_response = False

    def call(self, path, method='GET', body=None):
        if path == '/api/users/current':
            return {'id': 'embedded-owner', 'role': self.role, 'is_service_user': False}
        if path == '/api/instance':
            return {'setup_required': False}
        if path == '/api/accounts':
            return [dict(settings=copy.deepcopy(self.settings))]
        if path == '/api/identity-providers' and method == 'GET':
            return copy.deepcopy(list(self.providers.values()))
        if method == 'POST':
            self.count += 1
            identity = 'provider-' + str(self.count)
        elif method == 'PUT':
            if self.fail_update:
                self.fail_update = False
                raise TimeoutError('synthetic PUT interruption')
            identity = path.rsplit('/', 1)[-1]
        else:
            raise AssertionError('No user/peer or provider deletion is permitted')
        result = {key: value for key, value in body.items() if key != 'client_secret'}
        self.providers[identity] = dict(result, id=identity)
        if self.lose_create_response and method == 'POST':
            self.lose_create_response = False
            raise TimeoutError('synthetic response lost')
        return copy.deepcopy(self.providers[identity])


class SwitchTest(unittest.TestCase):
    def setUp(self):
        self.cloudron, self.netbird, self.store = Cloudron(), NetBird(), Store()

    def run_action(self, action):
        return M.Switch(self.cloudron, self.netbird, self.store).execute(action)

    def test_enable_disable_reenable_preserves_connector(self):
        self.assertTrue(self.run_action('enable')['enabled'])
        original_provider = self.store.value['provider_id']
        original_client = self.store.value['client_id']
        self.assertTrue(self.run_action('enable')['enabled'])
        self.assertEqual(self.cloudron.count, 1)
        self.assertFalse(self.run_action('disable')['enabled'])
        self.assertEqual(len(self.cloudron.clients), 1)
        self.assertTrue(self.cloudron.clients[original_client]['loginRedirectUri'].endswith('/cloudron-sso-disabled'))
        self.assertFalse(self.run_action('disable')['enabled'])
        self.assertTrue(self.run_action('enable')['enabled'])
        self.assertEqual(self.store.value['provider_id'], original_provider)
        self.assertEqual(self.store.value['client_id'], original_client)
        self.assertEqual(self.netbird.count, 1)

    def test_enable_requires_approval_and_recovery_login(self):
        for settings in (dict(local_auth_disabled=True, extra=dict(user_approval_required=True)),
                         dict(local_auth_disabled=False, extra=dict(user_approval_required=False))):
            self.netbird.settings = settings
            with self.assertRaises(ValueError):
                self.run_action('enable')
            self.assertIsNone(self.store.value)
            self.assertFalse(self.cloudron.clients)

    def test_disabling_remains_possible_after_policy_changes(self):
        self.run_action('enable')
        self.netbird.settings['extra']['user_approval_required'] = False
        self.assertFalse(self.run_action('disable')['enabled'])

    def test_status_and_disable_unconfigured_do_not_write(self):
        self.assertFalse(self.run_action('status')['enabled'])
        self.assertFalse(self.run_action('disable')['enabled'])
        self.assertIsNone(self.store.value)

    def test_lost_cloudron_create_response_is_recovered(self):
        self.cloudron.lose_create_response = True
        with self.assertRaises(TimeoutError):
            self.run_action('enable')
        self.assertTrue(self.run_action('enable')['enabled'])
        self.assertEqual(self.cloudron.count, 1)

    def test_lost_netbird_create_response_is_recovered(self):
        self.netbird.lose_create_response = True
        with self.assertRaises(TimeoutError):
            self.run_action('enable')
        self.assertTrue(self.run_action('enable')['enabled'])
        self.assertEqual(self.netbird.count, 1)

    def test_interrupted_reenable_is_recovered(self):
        self.run_action('enable')
        self.run_action('disable')
        self.netbird.fail_update = True
        with self.assertRaises(TimeoutError):
            self.run_action('enable')
        self.assertTrue(self.run_action('enable')['enabled'])
        self.assertEqual(self.cloudron.count, 1)
        self.assertEqual(self.netbird.count, 1)

    def test_foreign_provider_is_never_adopted(self):
        self.netbird.providers['foreign'] = dict(id='foreign', name='Cloudron')
        with self.assertRaises(ValueError):
            self.run_action('enable')
        self.assertFalse(self.cloudron.clients)

    def test_changed_managed_callback_is_not_deleted(self):
        self.run_action('enable')
        self.cloudron.clients[self.store.value['client_id']]['loginRedirectUri'] = 'https://other.example.invalid/callback'
        with self.assertRaises(ValueError):
            self.run_action('disable')
        self.assertEqual(len(self.cloudron.clients), 1)

    def test_removed_connector_is_not_recreated(self):
        self.run_action('enable')
        self.netbird.providers.clear()
        with self.assertRaises(ValueError):
            self.run_action('enable')

    def test_removed_client_is_not_recreated(self):
        self.run_action('enable')
        state = copy.deepcopy(self.store.value)
        providers = copy.deepcopy(self.netbird.providers)
        self.cloudron.clients.clear()
        for action in ('status', 'enable', 'disable'):
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, 'client was removed'):
                self.run_action(action)
        self.assertFalse(self.cloudron.clients)
        self.assertEqual(self.store.value, state)
        self.assertEqual(self.netbird.providers, providers)

    def test_requires_owner_and_bound_origins(self):
        self.netbird.role = 'user'
        with self.assertRaises(ValueError):
            self.run_action('enable')
        self.netbird.role = 'owner'
        self.run_action('enable')
        self.store.value['netbird'] = 'https://other.example.invalid'
        with self.assertRaises(ValueError):
            self.run_action('disable')

    def test_origin_validation(self):
        for value in ('http://host', 'https://user:pass@host', 'https://host/api', 'https://host?x=1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                M.origin(value)


if __name__ == '__main__':
    unittest.main()
