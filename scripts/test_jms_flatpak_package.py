"""Filesystem acceptance checks for Flatpak packaging and source-evidence gates."""
import hashlib
import io
import json
import os
import tarfile
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import date
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
        self.metainfo = self.root / 'flatpak/com.jim608.jms.metainfo.xml'
        self.metainfo.write_text(
            '<component type="desktop-application"><id>com.jim608.jms</id>'
            '<releases><release version="0.11.1-jms.35" date="2026-10-04"/>'
            '</releases></component>\n', encoding='utf-8')
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

    def test_stage_accepts_current_appstream_release_and_preserves_history(self):
        source_root = Path(__file__).resolve().parents[1]
        (self.root / 'pubspec.yaml').write_bytes((source_root / 'pubspec.yaml').read_bytes())
        current = source_root / 'flatpak/com.jim608.jms.metainfo.xml'
        expected = current.read_bytes()
        expected_history = [ET.tostring(release) for release in ET.fromstring(expected).findall('./releases/release')]
        self.metainfo.write_bytes(expected)
        staged = self.workspace / 'staged'
        build = package.stage(self.bundle, staged, self.commit)
        copied = (staged / 'com.jim608.jms.metainfo.xml').read_bytes()
        self.assertEqual(copied, expected)
        component = ET.fromstring(copied)
        releases = component.findall('./releases/release')
        self.assertTrue(releases)
        self.assertEqual(releases[0].get('version'), build['versionName'])
        release_date = releases[0].get('date', '')
        self.assertRegex(release_date, r'^\d{4}-\d{2}-\d{2}$')
        self.assertEqual(date.fromisoformat(release_date).isoformat(), release_date)
        self.assertEqual([ET.tostring(release) for release in releases], expected_history)
        self.assertEqual(component.findtext('metadata_license'), 'CC0-1.0')
        self.assertEqual(component.findtext('project_license'), 'GPL-3.0-only')

    def test_stage_rejects_stale_appstream_release_before_copying(self):
        (self.root / 'pubspec.yaml').write_text('version: 0.11.1-jms.47+50\n', encoding='utf-8')
        staged = self.workspace / 'staged'
        with self.assertRaisesRegex(ValueError, 'AppStream latest release version differs from pubspec'):
            package.stage(self.bundle, staged, self.commit)
        self.assertFalse(staged.exists())

    def test_stage_rejects_missing_or_malformed_appstream_before_copying(self):
        staged = self.workspace / 'staged'
        for invalid in (None, '<component>'):
            with self.subTest(invalid=invalid):
                if invalid is None:
                    self.metainfo.unlink()
                else:
                    self.metainfo.write_text(invalid, encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'AppStream metadata is missing or invalid'):
                    package.stage(self.bundle, staged, self.commit)
                self.assertFalse(staged.exists())

    def test_stage_rejects_appstream_for_another_application_before_copying(self):
        self.metainfo.write_text('<component><id>org.example.Other</id>'
                                 '<releases><release version="0.11.1-jms.35"/></releases></component>',
                                 encoding='utf-8')
        staged = self.workspace / 'staged'
        with self.assertRaisesRegex(ValueError, 'AppStream application ID differs'):
            package.stage(self.bundle, staged, self.commit)
        self.assertFalse(staged.exists())

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

    def test_updated_native_materials_require_reviewed_inputs_and_installed_libraries(self):
        build = package.identity(self.commit)
        manifest = self.workspace / 'manifest.yaml'
        manifest.write_text('runtime: org.gnome.Platform\nruntime-version: "50"\n', encoding='utf-8')
        self.output.mkdir()
        installed = self.output / 'flatpak-build-manifest.json'
        binaries = {'files/lib/jms/lib/libfixture_plugin.so': 'a' * 64}
        installed.write_text(json.dumps({'build': build, 'binaries': binaries}), encoding='utf-8')
        locked = {'pubspec.lock': b'new lock', 'Dockerfile.linux': b'new SDK',
                  'linux/CMakeLists.txt': b'new native assets',
                  'linux/flutter/generated_plugins.cmake': b'new plugins'}
        public = b'fixture corresponding source'
        reviewed = {
            'versionNames': [build['versionName']],
            'inputs': {name: hashlib.sha256(data).hexdigest() for name, data in locked.items()},
            'binaries': {'libfixture_plugin.so': ['fixture']},
            'archives': [{'module': 'fixture', 'url': 'https://example.invalid/source.tar.gz',
                          'sha256': hashlib.sha256(public).hexdigest(),
                          'member': 'application-sources/fixture.source.tar.gz'}],
        }
        review_file = self.workspace / 'review.json'
        review_file.write_text(json.dumps(reviewed), encoding='utf-8')

        def git_source(command, target):
            self.assertEqual(command, 'show')
            self.assertEqual(target.split(':')[0], self.commit)
            return locked[target.split(':')[1]]

        def fetch(url, destination, digest):
            self.assertEqual(url, reviewed['archives'][0]['url'])
            self.assertEqual(digest, reviewed['archives'][0]['sha256'])
            destination.write_bytes(public)

        with (
            mock.patch.object(sources, 'APP_SOURCE_REVIEW', review_file),
            mock.patch.object(sources, 'git', side_effect=git_source),
            mock.patch.object(sources, 'download', side_effect=fetch) as download,
        ):
            locked['pubspec.lock'] = b'unreviewed lock'
            with self.assertRaisesRegex(ValueError, 'Reviewed Flatpak source changed: pubspec.lock'):
                sources.collect(manifest, self.output, self.commit)
            locked['pubspec.lock'] = b'new lock'
            original = installed.read_bytes()
            binaries['files/lib/jms/lib/libunknown.so'] = 'b' * 64
            installed.write_text(json.dumps({'build': build, 'binaries': binaries}), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'Unreviewed installed Flatpak application libraries'):
                sources.collect(manifest, self.output, self.commit)
            download.assert_not_called()
            installed.write_bytes(original)
            sources.collect(manifest, self.output, self.commit)

        archive = next(self.output.glob('*native-materials.tar.gz'))
        with tarfile.open(archive, 'r:gz') as material:
            self.assertEqual(material.extractfile(reviewed['archives'][0]['member']).read(), public)
            self.assertEqual(json.load(material.extractfile('source-materials.json'))['application'],
                             {'inputs': reviewed['inputs'], 'binaries': reviewed['binaries']})

    def test_application_source_review_selects_each_approved_version_only(self):
        review = json.loads(sources.APP_SOURCE_REVIEW.read_bytes())
        for version in ('0.12.0-jms.60', '0.12.0-jms.61', '0.12.0-jms.62', '0.12.1-jms.63', '0.12.1-jms.64', '0.12.1-jms.65'):
            with self.subTest(version=version):
                self.assertIn(version, review['versionNames'])
        for version in ('0.12.0-jms.6', '0.12.0-jms.9999'):
            with self.subTest(version=version):
                self.assertIsNone(sources.reviewed_application_sources(self.commit, {'versionName': version}, self.output))

    def test_reviewed_media_reuse_verifies_manifest_commit_and_immutable_archive_members(self):
        public = b'fixture pinned corresponding source'
        source_commit = 'c' * 40
        media_url = 'https://example.invalid/lib.git'
        member = f'components/lib-{source_commit}.tar.gz'
        record = {'module': 'lib', 'url': media_url, 'commit': source_commit, 'member': member,
                  'sha256': hashlib.sha256(public).hexdigest()}
        manifest = {'modules': [{'name': 'lib', 'sources': [
            {'type': 'git', 'url': media_url, 'commit': source_commit}]}]}
        baseline = {'url': 'https://example.invalid/previous.tar.gz', 'sha256': 'd' * 64,
                    'size': 0, 'archives': [record]}
        packed = self.workspace / 'baseline.tar.gz'
        with tarfile.open(packed, 'w:gz') as archive:
            entry = tarfile.TarInfo(member)
            entry.size = len(public)
            archive.addfile(entry, io.BytesIO(public))
        baseline['size'] = packed.stat().st_size

        def download(url, path, digest, **kwargs):
            self.assertEqual((url, digest), (baseline['url'], baseline['sha256']))
            path.write_bytes(packed.read_bytes())

        with mock.patch.object(sources, 'download', side_effect=download) as remote:
            manifest['modules'][0]['sources'][0]['commit'] = 'e' * 40
            with self.assertRaisesRegex(ValueError, 'Reviewed Flatpak media source inputs differ'):
                sources.reviewed_media_archives(baseline, manifest, self.workspace)
            remote.assert_not_called()
            manifest['modules'][0]['sources'][0]['commit'] = source_commit
            record['sha256'] = 'f' * 64
            with self.assertRaisesRegex(ValueError, 'Reviewed Flatpak media source member differs'):
                sources.reviewed_media_archives(baseline, manifest, self.workspace)

            record['sha256'] = hashlib.sha256(public).hexdigest()
            reused = sources.reviewed_media_archives(baseline, manifest, self.workspace)
            self.assertEqual(reused[('lib', media_url, source_commit)], record)
            self.assertEqual((self.workspace / Path(member).name).read_bytes(), public)

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
