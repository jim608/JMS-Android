import json
import os
import unittest
import urllib.error
import urllib.request


@unittest.skipUnless(os.environ.get('JMS_TEST_ORIGIN'), 'Explicit local container endpoint required')
class WebContainerTests(unittest.TestCase):
    def setUp(self):
        self.origin = os.environ.get('JMS_TEST_ORIGIN', 'http://127.0.0.1:18081').rstrip('/')
        self.prefix = os.environ.get('JMS_TEST_PREFIX', '/').strip('/')
        self.base = self.origin + '/' + (self.prefix + '/' if self.prefix else '')

    def fetch(self, path):
        return urllib.request.urlopen(self.base + path, timeout=10)

    def test_health(self):
        with urllib.request.urlopen(self.origin + '/healthz', timeout=10) as response:
            self.assertEqual(response.read(), b'ok')

    def test_public_config_not_cached(self):
        with self.fetch('assets/config/config.json') as response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            self.assertEqual(set(json.load(response)), {'baseUrl', 'seerrBaseUrl', 'diagnosticsEndpoint'})

    def test_entry_config_json_without_spa_fallback(self):
        expected = os.environ.get('JMS_TEST_ENTRY_CONFIG') == 'present'
        try:
            response = self.fetch('jms-config.json')
        except urllib.error.HTTPError as error:
            self.assertFalse(expected)
            self.assertEqual(error.code, 404)
            response = error
        with response:
            self.assertIn('application/json', response.headers.get('Content-Type', ''))
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            config = json.load(response)
            if expected:
                self.assertTrue(config['baseUrl'].startswith('https://'))
                self.assertLessEqual(set(config), {'baseUrl', 'seerrBaseUrl', 'diagnosticsEndpoint'})
            else:
                self.assertEqual(config, {'error': 'configuration_not_found'})

    def test_entry_config_rejects_write_requests(self):
        request = urllib.request.Request(self.base + 'jms-config.json', data=b'{}', method='POST')
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        self.assertEqual(caught.exception.code, 405)

    def test_spa_and_title(self):
        with self.fetch('library/example-route') as response:
            self.assertIn('text/html', response.headers.get('Content-Type', ''))
            body = response.read().decode()
            self.assertIn('<title>JMS</title>', body)
            self.assertIn('<base href="/' + (self.prefix + '/' if self.prefix else '') + '">', body)

    def test_bootstrap_not_cached(self):
        with self.fetch('flutter_bootstrap.js') as response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            self.assertGreater(len(response.read()), 100)


if __name__ == '__main__':
    unittest.main()
