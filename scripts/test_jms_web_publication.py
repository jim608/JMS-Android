import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from jms_desktop_publication import validate_web_inventory
from jms_publication import ReleaseError


class WebPublicationTests(unittest.TestCase):
    def test_invalid_platform_version_executable_and_asset_are_rejected(self):
        for fault in ('none', 'platform', 'version', 'executable', 'asset'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                commit = 'a' * 40
                record = {'repository': 'jim608/JMS-Web', 'platform': 'web',
                          'sourceRepository': 'jim608/JMS-Android', 'sourceCommit': commit,
                          'versionName': '0.11.1-jms.22', 'versionCode': 24,
                          'buildId': 'JMS-0.11.1-jms.22-web-' + commit[:12],
                          'validation': {'container': True}, 'webArchive': 'web.zip',
                          'sourceArchive': 'source.zip', 'assets': []}
                with zipfile.ZipFile(directory / 'web.zip', 'w') as archive:
                    archive.writestr('main.dart.js', 'wrong' if fault == 'executable' else record['buildId'])
                    for name in ('index.html', 'flutter_bootstrap.js', 'assets/NOTICES'):
                        archive.writestr(name, 'synthetic runtime')
                for name in ('source.zip', 'SHA256SUMS.txt', 'RELEASE_NOTES.md'):
                    (directory / name).write_text('synthetic fixture')
                (directory / 'source.json').write_text(json.dumps(record))
                for path in directory.iterdir():
                    record['assets'].append({'name': path.name, 'size': path.stat().st_size,
                                             'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
                if fault == 'platform': record['platform'] = 'linux-x64'
                if fault == 'version': record['versionCode'] = 25
                if fault == 'asset': (directory / 'web.zip').write_bytes(b'changed')
                (directory / 'web-publication.json').write_text(json.dumps(record))
                with patch('jms_desktop_publication.git', return_value='version: 0.11.1-jms.22+24'), \
                        patch('jms_desktop_publication.verify_source_archive'), \
                        patch('jms_desktop_publication.load_policy', return_value=[]), \
                        patch('jms_desktop_publication.scan_packages_cached', return_value={'accepted': True}):
                    if fault == 'none':
                        self.assertEqual('web', validate_web_inventory(directory)[0]['platform'])
                    else:
                        with self.assertRaises(ReleaseError): validate_web_inventory(directory)


if __name__ == '__main__':
    unittest.main()
