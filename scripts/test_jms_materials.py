import base64
import io
import tempfile
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from collect_jms_native_materials import collect, digest
from verify_jms_android_native import ndk_license_coverage


class MaterialTests(unittest.TestCase):
    def test_license_coverage_allows_only_component_label_difference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'artifacts/native-materials-m13'
            directory.mkdir(parents=True)
            for component in ('libcxx', 'libcxxabi', 'libunwind'):
                label = 'libunwind' if component == 'libunwind' else 'libc++abi'
                (directory / f'ndk28-{component}-LICENSE.txt').write_text(
                    f'The {label} library is dual licensed\nRequired copyright and license clauses.', encoding='utf-8')
            with patch('verify_jms_android_native.ROOT', root):
                result = ndk_license_coverage(b'The libc++abi library is dual licensed\nRequired copyright and license clauses.')
                self.assertFalse(result[2]['normalizedFullTextPresent'])
                self.assertTrue(result[2]['allLicenseClausesPresent'])
                with self.assertRaisesRegex(ValueError, 'license clauses'):
                    ndk_license_coverage(b'The libc++abi library is dual licensed')

    def test_gitiles_base64_decodes_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = {'file': 'LICENSE.txt', 'url': 'https://android.googlesource.com/license?format=TEXT', 'encoding': 'base64'}
            opener = Mock()
            opener.open.return_value = io.BytesIO(base64.b64encode(b'upstream license text'))
            with patch('collect_jms_native_materials.urllib.request.build_opener', return_value=opener):
                result = collect(record, root, None)
            self.assertEqual((root / record['file']).read_bytes(), b'upstream license text')
            self.assertEqual(result['sha256'], digest(root / record['file']))
            record['file'] = 'corrupt.txt'
            opener.open.return_value = io.BytesIO(b'not base64!')
            with patch('collect_jms_native_materials.urllib.request.build_opener', return_value=opener):
                with self.assertRaises(ValueError):
                    collect(record, root, None)
            self.assertFalse((root / 'corrupt.txt').exists())
            self.assertFalse((root / 'corrupt.txt.part').exists())

    def test_official_version_archive_does_not_require_an_invented_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'release.tar.xz'
            path.write_bytes(b'official release fixture')
            record = {'file': path.name, 'url': 'https://example.org/release.tar.xz', 'version': '1.2.0',
                      'sha256': digest(path), 'status': 'ACQUIRED'}
            self.assertEqual(collect(record, root, record), record)
            path.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'bound'):
                collect(record, root, record)

    def test_unsafe_path_and_http_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            for record in [{'file': '../key', 'url': 'https://example.org/source'},
                           {'file': 'source', 'url': 'http://example.org/source'}]:
                with self.assertRaises(ValueError):
                    collect(record, Path(temporary), None)


if __name__ == '__main__':
    unittest.main()
