import gzip
import hashlib
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

    def fetch(self, path, headers=None, method='GET'):
        request = urllib.request.Request(self.base + path, headers=headers or {}, method=method)
        return urllib.request.urlopen(request, timeout=10)

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

    def test_root_loads_current_bootstrap_without_cache(self):
        with self.fetch('') as response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            body = response.read().decode()
            self.assertNotIn('<script src="flutter_bootstrap.js"', body)
            self.assertNotIn('{{flutter_bootstrap_js}}', body)
            self.assertIn('_flutter.loader.load({', body)
            for marker in ('id="jms-startup"', 'id="jms-startup-message"',
                           'id="jms-startup-retry"', 'onEntrypointLoaded:'):
                self.assertIn(marker, body)

    def test_service_worker_not_cached(self):
        with self.fetch('flutter_service_worker.js') as response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            self.assertIn(b"self.addEventListener", response.read())

    def main_bytes(self):
        with self.fetch('main.dart.js', {'Accept-Encoding': 'identity'}) as response:
            self.assertEqual(response.status, 200)
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            content = response.read()
            self.assertGreater(len(content), 256)
            source = os.environ.get('SOURCE_COMMIT')
            if source:
                self.assertIn(source.encode(), content)
            return content, hashlib.sha256(content).hexdigest()

    def test_main_compresses_direct_and_proxied_without_changing_bytes(self):
        identity, digest = self.main_bytes()
        for headers in ({'Accept-Encoding': 'gzip'},
                        {'Accept-Encoding': 'gzip', 'Via': '1.1 jms-fixture.invalid'},
                        {'Accept-Encoding': 'br, gzip', 'Via': '1.1 jms-fixture.invalid'}):
            with self.subTest(headers=headers), self.fetch('main.dart.js', headers) as response:
                self.assertIn(response.headers.get_content_type(), ('application/javascript', 'text/javascript'))
                self.assertEqual(response.headers.get('Content-Encoding'), 'gzip')
                self.assertIn('accept-encoding', response.headers.get('Vary', '').lower())
                self.assertEqual(response.headers.get('ETag'), f'W/"sha256-{digest}"')
                encoded = response.read()
                self.assertLess(len(encoded), len(identity))
                self.assertEqual(gzip.decompress(encoded), identity)

    def test_only_actual_main_content_hash_is_immutable_and_revalidates(self):
        identity, digest = self.main_bytes()
        path = 'main.dart.js?v=' + digest
        with self.fetch(path, {'Accept-Encoding': 'gzip', 'Via': '1.1 jms-fixture.invalid'}) as response:
            self.assertIn('immutable', response.headers.get('Cache-Control', ''))
            self.assertIn('max-age=31536000', response.headers.get('Cache-Control', ''))
            self.assertEqual(gzip.decompress(response.read()), identity)
            tag = response.headers['ETag']
        for tag_list in (tag, tag.removeprefix('W/'), '"unrelated", ' + tag, '*'):
            with self.subTest(tag=tag_list), self.assertRaises(urllib.error.HTTPError) as caught:
                self.fetch(path, {'Accept-Encoding': 'gzip', 'If-None-Match': tag_list})
            with caught.exception as response:
                self.assertEqual(response.code, 304)
                self.assertEqual(response.read(), b'')
                self.assertEqual(response.headers.get('ETag'), tag)
                self.assertIn('immutable', response.headers.get('Cache-Control', ''))
                self.assertIn('accept-encoding', response.headers.get('Vary', '').lower())

    def test_unknown_or_legacy_main_version_is_not_cached_or_satisfied_by_304(self):
        _, digest = self.main_bytes()
        for version in ('legacy-service-worker-version', '0' * 64 if digest != '0' * 64 else '1' * 64):
            with self.subTest(version=version), self.assertRaises(urllib.error.HTTPError) as caught:
                self.fetch('main.dart.js?v=' + version, {'If-None-Match': f'W/"sha256-{digest}"'})
            with caught.exception as response:
                self.assertEqual(response.code, 404)
                self.assertIn('no-store', response.headers.get('Cache-Control', ''))
                self.assertNotIn('immutable', response.headers.get('Cache-Control', ''))

    def test_stale_etag_or_modification_time_cannot_hide_current_main_bytes(self):
        identity, digest = self.main_bytes()
        for headers in ({'If-None-Match': 'W/"sha256-' + '0' * 64 + '"'},
                        {'If-Modified-Since': 'Fri, 31 Dec 9999 23:59:59 GMT'}):
            with self.subTest(headers=headers), self.fetch('main.dart.js?v=' + digest, headers) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), identity)

    def test_version_metadata_and_private_entry_head_remain_no_store(self):
        with self.fetch('version.json', method='HEAD') as response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
        try:
            response = self.fetch('jms-config.json', method='HEAD')
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 404)
            response = error
        with response:
            self.assertIn('no-store', response.headers.get('Cache-Control', ''))
            self.assertIn('application/json', response.headers.get('Content-Type', ''))
            self.assertEqual(response.read(), b'')

    def test_unversioned_static_assets_revalidate_without_blanket_immutable(self):
        with self.fetch('manifest.json', method='HEAD') as response:
            self.assertIn('no-cache', response.headers.get('Cache-Control', ''))
            self.assertNotIn('immutable', response.headers.get('Cache-Control', ''))


if __name__ == '__main__':
    unittest.main()
