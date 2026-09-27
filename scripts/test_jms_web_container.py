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
            self.assertEqual(set(json.load(response)), {'baseUrl', 'seerrBaseUrl'})

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
