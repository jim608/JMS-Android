"""Filesystem acceptance checks for Flatpak packaging and source-evidence gates."""
import hashlib
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import collect_jms_flatpak_sources as sources
import package_jms_flatpak as package


class FlatpakPackageTests(unittest.TestCase):
    commit = 'a' * 40
    ostree_commit = 'b' * 64

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name)
        self.root = self.workspace / 'source'
        self.root.mkdir()
        (self.root / 'pubspec.yaml').write_text('version: 0.11.1-jms.35+37\n', encoding='utf-8')
        (self.root / 'LICENSE').write_text('Fixture license\n', encoding='utf-8')
        (self.root / 'flatpak').mkdir()
        (self.root / 'flatpak/com.jim608.jms.yaml').write_text('id: com.jim608.jms\n', encoding='utf-8')
        icon = self.root / 'icons/jms/mark.svg'
        icon.parent.mkdir(parents=True)
        icon.write_text('<svg/>\n', encoding='utf-8')
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(package, 'ROOT', self.root).start()
        self.bundle = self.workspace / 'bundle'
        (self.bundle / 'lib').mkdir(parents=True)
        (self.bundle / 'data').mkdir()
        (self.bundle / 'jms').write_bytes(b'fixture executable')
        (self.bundle / 'lib/libapp.so').write_bytes(b'fixture Flutter application')
        self.output = self.workspace / 'output'
        self.deployment = self.workspace / 'installed'
        build_info = self.deployment / 'files/share/jms/JMS_BUILD_INFO.json'
        build_info.parent.mkdir(parents=True)
        build_info.write_text(json.dumps(package.identity(self.commit)), encoding='utf-8')
        (self.deployment / 'metadata').write_text(
            '[Application]\nname=com.jim608.jms\nruntime=org.gnome.Platform/x86_64/50\n',
            encoding='utf-8')
        self.flatpak = self.workspace / 'fixture.flatpak'
        self.flatpak.write_bytes(b'fixture Flatpak evidence')

    def accept_runtime(self, **changes):
        validation = self.output / 'validation/runtime-validation.json'
        validation.parent.mkdir(parents=True, exist_ok=True)
        validation.write_text(json.dumps({'install': True, 'launch': True} | changes), encoding='utf-8')

    def inventory(self):
        package.inventory(self.deployment, self.flatpak, self.output, self.commit, self.ostree_commit)

    def symlink(self, link, target):
        try:
            link.symlink_to(target)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f'This host cannot create filesystem symlinks: {error}')

    def test_stage_copies_only_release_bundle_and_binds_source(self):
        (self.root / 'private-local-settings.json').write_text('private fixture', encoding='utf-8')
        staged = self.workspace / 'staged'
        package.stage(self.bundle, staged, self.commit)
        self.assertEqual((staged / 'payload/lib/libapp.so').read_bytes(), b'fixture Flutter application')
        self.assertEqual(json.loads((staged / 'payload/JMS_BUILD_INFO.json').read_text())['sourceCommit'], self.commit)
        self.assertFalse((staged / 'private-local-settings.json').exists())
        self.assertFalse((staged / 'payload/private-local-settings.json').exists())

    def test_stage_rejects_symlink_to_file_outside_source_bundle(self):
        outside = self.workspace / 'outside.so'
        outside.write_bytes(b'must not enter candidate')
        self.symlink(self.bundle / 'lib/escaped.so', outside)
        staged = self.workspace / 'staged'
        with self.assertRaisesRegex(ValueError, 'Escaping source bundle symlink'):
            package.stage(self.bundle, staged, self.commit)
        self.assertFalse(staged.exists())

    def test_inventory_rejects_symlink_escaping_installed_payload(self):
        outside = self.workspace / 'outside-data'
        outside.write_bytes(b'must not enter evidence')
        self.symlink(self.deployment / 'files/escaped-data', outside)
        self.accept_runtime()
        with self.assertRaisesRegex(ValueError, 'Escaping installed payload symlink'):
            self.inventory()
        self.assertFalse((self.output / 'flatpak-verification.json').exists())
        self.assertFalse(list(self.output.glob('*payload.tar.gz')))

    def test_inventory_rejects_tampered_installed_source_identity(self):
        info_path = self.deployment / 'files/share/jms/JMS_BUILD_INFO.json'
        changed = json.loads(info_path.read_text())
        changed['sourceCommit'] = 'c' * 40
        info_path.write_text(json.dumps(changed), encoding='utf-8')
        self.accept_runtime()
        with self.assertRaisesRegex(ValueError, 'Installed build identity differs'):
            self.inventory()
        self.assertFalse(list(self.output.glob('*payload.tar.gz')))

    def test_inventory_requires_real_runtime_acceptance_before_archiving(self):
        with self.assertRaises(FileNotFoundError):
            self.inventory()
        self.assertFalse(list(self.output.glob('*payload.tar.gz')))
        for failed_step in ('install', 'launch'):
            with self.subTest(failed=failed_step):
                self.accept_runtime(**{failed_step: False})
                with self.assertRaisesRegex(ValueError, 'Installed runtime verification required'):
                    self.inventory()
        self.assertFalse((self.output / 'flatpak-verification.json').exists())
        self.assertFalse(list(self.output.glob('*payload.tar.gz')))

    def test_hardlinked_deployment_files_have_complete_regular_tar_bytes(self):
        library = self.deployment / 'files/lib/libfirst.so'
        library.parent.mkdir(parents=True)
        content = b'complete native library bytes\x00\xff'
        library.write_bytes(content)
        equal = library.with_name('libsecond.so')
        os.link(library, equal)
        self.assertTrue(os.path.samefile(library, equal))
        self.accept_runtime()
        self.inventory()
        payload = next(self.output.glob('*payload.tar.gz'))
        with tarfile.open(payload, 'r:gz') as archive:
            for name in ('files/lib/libfirst.so', 'files/lib/libsecond.so'):
                with self.subTest(member=name):
                    member = archive.getmember(name)
                    self.assertTrue(member.isfile())
                    self.assertFalse(member.islnk())
                    self.assertEqual(member.linkname, '')
                    self.assertEqual(archive.extractfile(member).read(), content)
        verification = json.loads((self.output / 'flatpak-verification.json').read_text())
        for name in ('files/lib/libfirst.so', 'files/lib/libsecond.so'):
            self.assertEqual(verification['members'][name], hashlib.sha256(content).hexdigest())

    def test_source_reuse_rejects_each_changed_native_input_before_download(self):
        manifest = self.workspace / 'manifest.yaml'
        manifest.write_text('modules: []\n', encoding='utf-8')
        for changed_path in ('pubspec.lock', 'Dockerfile.linux', 'linux/CMakeLists.txt'):
            def git_source(*arguments, **_):
                return b'changed native input' if arguments == (
                    'show', self.commit + ':' + changed_path) else b'unchanged native input'

            with self.subTest(changed=changed_path), \
                    mock.patch.object(sources, 'git', side_effect=git_source), \
                    mock.patch.object(sources, 'download', side_effect=AssertionError('Rejected inputs must not download')) as download:
                with self.assertRaisesRegex(ValueError, 'Native baseline source changed: ' + changed_path):
                    sources.collect(manifest, self.output, self.commit)
                download.assert_not_called()
                self.assertFalse(list(self.output.glob('*native-materials.tar.gz')))


if __name__ == '__main__':
    unittest.main()
