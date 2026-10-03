import hashlib
from pathlib import Path
import tempfile
import unittest

from jms_windows_bundle import DEBUG_ARTIFACTS, copy_without_verified_debug_kernel, validate_release_bundle


class WindowsReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'candidate'
        for name, data in {'jms.exe': b'synthetic runner', 'flutter_windows.dll': b'synthetic engine',
                           'data/app.so': b'synthetic AOT', 'data/flutter_assets/assets/example.dat': b'synthetic asset',
                           'native-example.dll': b'synthetic retained native library'}.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def kernel(self, value=b'synthetic debug-only kernel'):
        path = self.source / DEBUG_ARTIFACTS[0]
        path.write_bytes(value)
        return hashlib.sha256(value).hexdigest()

    def test_aot_bundle_without_debug_assets_is_accepted(self):
        files = validate_release_bundle(self.source)
        self.assertEqual(len(files), 5)
        self.assertIn('data/app.so', files)

    def test_reserved_debug_artifacts_block_release_packaging(self):
        for name in DEBUG_ARTIFACTS:
            with self.subTest(name=name):
                path = self.source / name
                path.write_bytes(b'synthetic generated debug data')
                with self.assertRaisesRegex(ValueError, 'debug-only'):
                    validate_release_bundle(self.source)
                path.unlink()

    def test_empty_or_missing_aot_is_rejected(self):
        path = self.source / 'data/app.so'
        path.write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'AOT'):
            validate_release_bundle(self.source)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'AOT'):
            validate_release_bundle(self.source)

    def test_precise_correction_preserves_aot_assets_native_and_original(self):
        digest = self.kernel()
        destination = self.root / 'publication-2'
        result = copy_without_verified_debug_kernel(self.source, destination, digest)
        self.assertEqual(result['removedMember'], DEBUG_ARTIFACTS[0])
        self.assertEqual(result['removedSha256'], digest)
        self.assertTrue((self.source / DEBUG_ARTIFACTS[0]).exists())
        self.assertFalse((destination / DEBUG_ARTIFACTS[0]).exists())
        for name in result['retainedFiles']:
            self.assertEqual((self.source / name).read_bytes(), (destination / name).read_bytes())

    def test_one_changed_byte_invalidates_correction(self):
        digest = self.kernel()
        (self.source / DEBUG_ARTIFACTS[0]).write_bytes(b'synthetic debug-only kernel!')
        with self.assertRaisesRegex(ValueError, 'differs'):
            copy_without_verified_debug_kernel(self.source, self.root / 'publication-2', digest)
        self.assertFalse((self.root / 'publication-2').exists())

    def test_another_debug_member_cannot_use_the_kernel_review(self):
        digest = self.kernel()
        (self.source / DEBUG_ARTIFACTS[1]).write_bytes(b'synthetic other snapshot')
        with self.assertRaisesRegex(ValueError, 'Additional unreviewed'):
            copy_without_verified_debug_kernel(self.source, self.root / 'publication-2', digest)
        self.assertFalse((self.root / 'publication-2').exists())

    def test_existing_destination_is_preserved(self):
        digest = self.kernel()
        destination = self.root / 'publication-2'
        destination.mkdir()
        marker = destination / 'retained.dat'
        marker.write_bytes(b'existing unrelated contents')
        with self.assertRaisesRegex(ValueError, 'new distinct'):
            copy_without_verified_debug_kernel(self.source, destination, digest)
        self.assertEqual(marker.read_bytes(), b'existing unrelated contents')


if __name__ == '__main__':
    unittest.main()
