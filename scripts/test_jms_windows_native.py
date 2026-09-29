import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

import zstandard
from stage_jms_windows_native import verify_package_members, verify_notices


class NativePackageBindingTests(unittest.TestCase):
    def package(self, root, members):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name, payload in members:
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        path = Path(root) / 'fixture.pkg.tar.zst'
        path.write_bytes(zstandard.ZstdCompressor().compress(data.getvalue()))
        return path

    def entry(self, data=b'fixture-dll', **extra):
        return {'dll': 'fixture.dll', 'sha256': hashlib.sha256(data).hexdigest(), **extra}

    def test_exact_package_member_and_explicit_alias(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.package(root, [('ucrt64/bin/original.dll', b'fixture-dll')])
            verify_package_members(path, [self.entry(packageMember='ucrt64/bin/original.dll')])

    def test_changed_member_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.package(root, [('ucrt64/bin/fixture.dll', b'changed-dll')])
            with self.assertRaisesRegex(ValueError, 'differs'):
                verify_package_members(path, [self.entry()])

    def test_wrong_platform_directory_does_not_match_basename(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.package(root, [('mingw32/bin/fixture.dll', b'fixture-dll')])
            with self.assertRaisesRegex(ValueError, 'missing'):
                verify_package_members(path, [self.entry()])

    def test_duplicate_member_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            item = ('ucrt64/bin/fixture.dll', b'fixture-dll')
            path = self.package(root, [item, item])
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                verify_package_members(path, [self.entry()])

    def test_sdk_wrapper_requires_exact_binary_member(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'sdk.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('x64/fixture.dll', b'fixture-dll')
            verify_package_members(path, [self.entry(packageMember='x64/fixture.dll')])
            with self.assertRaisesRegex(ValueError, 'missing'):
                verify_package_members(path, [self.entry(packageMember='x86/fixture.dll')])

    def test_notice_content_and_component_binding(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            (folder / 'notices').mkdir()
            (folder / 'notices/LICENSE').write_bytes(b'fixture-license')
            record = {'libraries': [{'notices': ['LICENSE']}], 'notices': {
                'LICENSE': {'sha256': hashlib.sha256(b'fixture-license').hexdigest()}}}
            self.assertEqual(len(verify_notices(folder, record)), 1)
            (folder / 'notices/LICENSE').write_bytes(b'changed-license')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                verify_notices(folder, record)
            record['libraries'][0]['notices'] = ['missing']
            with self.assertRaisesRegex(ValueError, 'binding'):
                verify_notices(folder, record)

    def test_missing_notices_rejected(self):
        with self.assertRaisesRegex(ValueError, 'required'):
            verify_notices(Path('.'), {'libraries': [{}]})


if __name__ == '__main__':
    unittest.main()
