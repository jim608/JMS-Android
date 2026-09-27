import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from jms_legacy_verifier import prepare_legacy_verifier


class LegacyVerifierTests(unittest.TestCase):
    def test_preserves_bytes_and_isolates_package_resolution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.dart_tool').mkdir()
            (root / '.dart_tool/package_config.json').write_text(json.dumps({
                'configVersion': 2, 'packages': [
                    {'name': 'fladder', 'rootUri': '../', 'packageUri': 'lib/'},
                    {'name': 'http', 'rootUri': '../../http/', 'packageUri': 'lib/'},
                ]}))
            release = root / 'artifacts/releases/fixture-build'
            release.mkdir(parents=True)
            inputs = []
            with zipfile.ZipFile(release / 'JMS-0.11.1-jms.8-source.zip', 'w') as archive:
                for name in ['update_checker', 'update_source', 'brand']:
                    path = 'lib/util/' + name + '.dart'
                    content = ('fixture ' + name + '\r\n').encode()
                    archive.writestr('JMS/' + path, content)
                    inputs.append({'path': path, 'sha256': hashlib.sha256(content).hexdigest()})
            baseline = {'buildId': 'fixture-build', 'inputs': inputs}
            target = prepare_legacy_verifier(root, baseline)
            config = json.loads(target.read_text())
            self.assertEqual(target.parent.as_uri() + '/', config['packages'][0]['rootUri'])
            self.assertTrue(config['packages'][1]['rootUri'].startswith('file:'))
            for entry in inputs:
                self.assertEqual(entry['sha256'], hashlib.sha256((target.parent / entry['path']).read_bytes()).hexdigest())
            inputs[0]['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'does not match'):
                prepare_legacy_verifier(root, baseline)


if __name__ == '__main__':
    unittest.main()
