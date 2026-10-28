"""Production startup state and generated-worker integrity; no real user data."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MARKER = '__JMS_MAIN_CONTENT_SHA256__'


class WebBootstrapTests(unittest.TestCase):
    def test_production_startup_state_machine(self):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Existing Node runtime is required')
        result = subprocess.run([node, str(ROOT / 'scripts/test_jms_web_bootstrap.js')],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertEqual(json.loads(result.stdout)['passed'], 9)

    @classmethod
    def setUpClass(cls):
        candidates = [os.environ.get('JMS_TEST_DART'),
                      str(ROOT / '.jms-tools/flutter/bin/cache/dart-sdk/bin/dart.exe'),
                      shutil.which('dart')]
        cls.dart = next((Path(p).resolve() for p in candidates if p and Path(p).is_file()), None)
        if cls.dart is None:
            raise AssertionError('Existing pinned Flutter/Dart runtime is required')
        worker = Path('packages/flutter_tools/lib/src/web/file_generators/js/flutter_service_worker.js')
        cls.template = next((parent / worker for parent in cls.dart.parents if (parent / worker).is_file()), None)
        if cls.template is None:
            raise AssertionError('Pinned Flutter service-worker template is required')

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='jms-web-bootstrap-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.main = b'window.syntheticFixture = "current-build";\n'
        index = '<html><script>const version="' + MARKER + '";</script></html>'
        bootstrap = 'const version="' + MARKER + '";'
        self.resources = {name: hashlib.md5(data).hexdigest() for name, data in {
            'main.dart.js': self.main, 'index.html': index.encode(),
            'flutter_bootstrap.js': bootstrap.encode()}.items()}
        self.resources['/'] = self.resources['index.html']
        self.resources['assets/config/config.json'] = '0' * 32
        self.resources['version.json'] = '1' * 32
        self.core = ['main.dart.js', 'index.html', 'flutter_bootstrap.js']
        worker = self.template.read_text(encoding='utf-8').replace(
            '$$RESOURCES_MAP', json.dumps(self.resources)).replace('$$CORE_LIST', json.dumps(self.core))
        for name, data in {'main.dart.js': self.main, 'index.html': index.encode(),
                           'flutter_bootstrap.js': bootstrap.encode(),
                           'flutter_service_worker.js': worker.encode()}.items():
            (self.directory / name).write_bytes(data)

    def run_prepare(self):
        return subprocess.run([str(self.dart), '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                               str(ROOT / 'scripts/prepare_jms_web_bootstrap.dart'), str(self.directory)],
                              capture_output=True, timeout=60)

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.directory.iterdir()}

    def test_main_and_generated_manifest_are_bound_to_exact_final_bytes(self):
        original = self.snapshot()
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        record = json.loads(result.stdout)
        checksum = hashlib.sha256(self.main).hexdigest()
        self.assertEqual(record['mainSha256'], checksum)
        self.assertEqual((self.directory / 'main.dart.js').read_bytes(), self.main)
        worker = (self.directory / 'flutter_service_worker.js').read_text(encoding='utf-8')
        resources = json.loads(re.search(r'^const RESOURCES = (\{.*?\});$', worker, re.M).group(1))
        core = json.loads(re.search(r'^const CORE = (\[.*?\]);$', worker, re.M).group(1))
        self.assertIn('main.dart.js?v=' + checksum, core)
        self.assertEqual(resources[core[0]], self.resources['main.dart.js'])
        for name in ['index.html', 'flutter_bootstrap.js']:
            data = (self.directory / name).read_bytes()
            self.assertIn(checksum.encode(), data)
            self.assertNotIn(MARKER.encode(), data)
            self.assertEqual(resources[name], hashlib.md5(data).hexdigest())
        self.assertEqual(resources['/'], resources['index.html'])
        self.assertNotIn('assets/config/config.json', resources)
        self.assertNotIn('version.json', resources)
        self.assertIn("new Request(value, {'cache': 'no-cache'})", worker)
        # The existing update, fetch and offline handlers retain exact bytes.
        original_tail = original['flutter_service_worker.js'].decode().split('// During activate,', 1)[1]
        self.assertEqual(worker.split('// During activate,', 1)[1], original_tail)

    def test_bad_original_main_manifest_hash_fails_before_any_write(self):
        file = self.directory / 'flutter_service_worker.js'
        file.write_text(file.read_text(encoding='utf-8').replace(self.resources['main.dart.js'], '0' * 32), encoding='utf-8')
        before = self.snapshot()
        self.assertNotEqual(self.run_prepare().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_unsupported_worker_template_fails_before_any_write(self):
        file = self.directory / 'flutter_service_worker.js'
        file.write_text(file.read_text(encoding='utf-8').replace("'cache': 'reload'", "'cache': 'force-cache'"), encoding='utf-8')
        before = self.snapshot()
        self.assertNotEqual(self.run_prepare().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_repeated_finalize_is_rejected_without_rewriting_hashes(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        before = self.snapshot()
        self.assertNotEqual(self.run_prepare().returncode, 0)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
