import hashlib
import io
import json
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch
import zipfile

from jms_publication import ReleaseError
import prepare_jms_flatpak_release as preparation
import test_jms_desktop_publication as fixtures


class FlatpakPreparationTests(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.FlatpakPublicationTests('test_flatpak_only_uses_existing_linux_publisher_without_pacman_feed')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.directory = fixture.directory
        version = fixture.record['versionName']
        commit = fixture.record['sourceCommit']
        self.build = dict(fixture.identity, applicationId='com.jim608.jms')
        fixture.identity = self.build
        payload_name = f'JMS-Linux-{version}-flatpak-payload.tar.gz'
        (self.directory / fixture.record['flatpak']['payload']).rename(self.directory / payload_name)
        fixture.receipt['payload']['name'] = payload_name
        fixture.write_json('flatpak-verification.json', fixture.receipt)
        fixture.write_manifest()
        source = self.directory / f'JMS-{version}-source.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('JMS/pubspec.yaml', 'version: ' + version + '+37\n')
            archive.writestr('JMS/CHANGELOG.md', fixture.record['canonicalNotes'])
            archive.writestr('JMS/LICENSE', fixture.payload_members['files/share/licenses/jms/LICENSE'])
            archive.writestr('JMS/source-manifest.json', json.dumps({'sourceCommit': commit, 'dirty': False}))
        component = b'GPL native corresponding source fixture'
        evidence = {'build': self.build, 'sources': [{
            'module': 'native-fixture', 'url': 'https://example.invalid/native-source.tar.gz',
            'sha256': hashlib.sha256(component).hexdigest(), 'member': 'components/native-source.tar.gz'}]}
        fixture.write_json('flatpak-native-sources.json', evidence)
        material = self.directory / f'JMS-Linux-{version}-flatpak-native-materials.tar.gz'
        with tarfile.open(material, 'w:gz') as archive:
            for name, data in [('source-materials.json', json.dumps(evidence).encode()),
                               ('components/native-source.tar.gz', component)]:
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        (self.directory / 'validation').mkdir()
        fixture.write_json('validation/runtime-validation.json', fixture.receipt['validation'])
        fixture.write_json('runner-source.json', {'SOURCE_COMMIT': commit, 'VERSION': version,
                            'BUILD_ID': self.build['buildId'], 'GITHUB_RUN_ID': '100'})
        fixture.write_json('validation/diagnostic.json', {'local': 'synthetic diagnostics'})
        for name in ('desktop-publication.json', 'SHA256SUMS.txt', 'RELEASE_NOTES.md'):
            (self.directory / name).unlink()
        self.source = source
        self.material = material

    def prepare(self, run_id=100):
        with patch.object(preparation, 'verify_source_archive') as verify:
            record = preparation.prepare(self.directory, run_id)
            verify.assert_called_once_with(self.source, self.build['sourceCommit'])
            return record

    def test_prepares_exact_candidate_public_inventory_without_local_logs(self):
        record = self.prepare()
        names = {entry['name'] for entry in record['assets']}
        self.assertEqual(len(names), 9)
        self.assertIn(self.source.name, names)
        self.assertIn(self.material.name, names)
        self.assertNotIn('runner-source.json', names)
        self.assertFalse(any(name.startswith('validation/') for name in names))
        self.assertNotIn('update-linux.json', names)
        self.assertEqual(record['flatpak']['ci']['runId'], 100)
        notes = (self.directory / 'RELEASE_NOTES.md').read_text(encoding='utf-8')
        self.assertIn(self.build['sourceCommit'], notes)
        self.assertIn(self.build['buildId'], notes)
        self.assertEqual(self.prepare(), record)

    def test_existing_prepared_candidate_is_never_replaced_with_another_run(self):
        record = self.prepare()
        before = (self.directory / 'desktop-publication.json').read_bytes()
        runner = json.loads((self.directory / 'runner-source.json').read_text())
        runner['GITHUB_RUN_ID'] = '101'
        (self.directory / 'runner-source.json').write_text(json.dumps(runner))
        with self.assertRaisesRegex(ReleaseError, 'refusing replacement'):
            self.prepare(101)
        self.assertEqual((self.directory / 'desktop-publication.json').read_bytes(), before)
        self.assertEqual(json.loads(before)['flatpak']['ci']['runId'], record['flatpak']['ci']['runId'])

    def test_native_archive_must_match_corresponding_source_evidence(self):
        evidence = json.loads((self.directory / 'flatpak-native-sources.json').read_text())
        evidence['sources'][0]['sha256'] = 'd' * 64
        (self.directory / 'flatpak-native-sources.json').write_text(json.dumps(evidence))
        with self.assertRaisesRegex(ReleaseError, 'archive differs from evidence'):
            self.prepare()
        self.assertFalse((self.directory / 'desktop-publication.json').exists())

    def test_missing_actual_runtime_verification_blocks_candidate_prep(self):
        (self.directory / 'validation/runtime-validation.json').write_text('{}')
        with self.assertRaisesRegex(ReleaseError, 'runtime verification differs'):
            self.prepare()

    def test_fresh_ci_runner_has_no_native_parent(self):
        runner = json.loads((self.directory / 'runner-source.json').read_text())
        runner.update(VERIFICATION_COMMIT=self.build['sourceCommit'], NATIVE_BUILD_RUN_ID='')
        (self.directory / 'runner-source.json').write_text(json.dumps(runner))
        with patch.object(preparation, 'verify_flatpak_verification_inputs') as inputs:
            record = self.prepare()
        inputs.assert_called_once_with(self.build['sourceCommit'], self.build['sourceCommit'])
        self.assertEqual(record['flatpak']['ci']['verificationCommit'], self.build['sourceCommit'])
        self.assertNotIn('nativeBuildRunId', record['flatpak']['ci'])
        self.assertNotIn('nativeBuildOrigin', record['flatpak']['ci'])

    def test_resumed_ci_records_verification_head_without_rebinding_source_or_public_assets(self):
        runner = json.loads((self.directory / 'runner-source.json').read_text())
        runner.update(VERIFICATION_COMMIT='d' * 40, NATIVE_BUILD_RUN_ID='99')
        (self.directory / 'runner-source.json').write_text(json.dumps(runner))
        bundle = self.directory / f'JMS-Linux-{self.build["versionName"]}-x86_64.flatpak'
        origin = {'schemaVersion': 1, 'sourceCommit': self.build['sourceCommit'],
                  'buildId': self.build['buildId'], 'runId': 99, 'artifactId': 201,
                  'artifactName': 'synthetic-failure-artifact', 'artifactDigest': 'sha256:' + 'b' * 64,
                  'bundle': preparation.item(bundle), 'bundleMember': 'candidate/' + bundle.name}
        (self.directory / 'native-build-origin.json').write_text(json.dumps(origin))
        with patch.object(preparation, 'verify_flatpak_verification_inputs') as inputs:
            record = self.prepare()
        inputs.assert_called_once_with(self.build['sourceCommit'], 'd' * 40)
        self.assertEqual(record['sourceCommit'], self.build['sourceCommit'])
        self.assertEqual(record['buildId'], self.build['buildId'])
        self.assertEqual(record['flatpak']['ci']['nativeBuildRunId'], 99)
        self.assertEqual(record['flatpak']['ci']['nativeBuildOrigin'], origin)
        self.assertEqual(len(record['assets']), 9)
        self.assertNotIn('native-build-origin.json', {entry['name'] for entry in record['assets']})

    def test_resumed_ci_requires_matching_parent_and_runner_identity(self):
        runner = json.loads((self.directory / 'runner-source.json').read_text())
        for changed in (dict(runner, VERIFICATION_COMMIT='d' * 40),
                        dict(runner, SOURCE_COMMIT='b' * 40),
                        dict(runner, NATIVE_BUILD_RUN_ID='true')):
            (self.directory / 'runner-source.json').write_text(json.dumps(changed))
            with self.subTest(runner=changed), self.assertRaisesRegex(ReleaseError, 'runner source/verification identity'):
                self.prepare()


if __name__ == '__main__':
    unittest.main()
