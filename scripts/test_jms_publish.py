import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import jms_publication as policy
import publish_jms_release as publisher


class FakeGithub:
    def __init__(self, files):
        self.files = files
        self.uploads = []
        self.publishes = 0
        self.fail_once = None
        self.release = {'id': 7, 'draft': True, 'tag_name': 'vfixture', 'name': 'JMS fixture', 'prerelease': True,
                        'body': 'fixture notes', 'assets': []}

    def api(self, endpoint, method='GET', payload=None):
        if method == 'PATCH':
            self.publishes += 1
            self.release['draft'] = False
        return copy.deepcopy(self.release)

    def call(self, *arguments, **kwargs):
        path = Path(arguments[3])
        name = path.name
        if self.fail_once == name:
            self.fail_once = None
            raise policy.ReleaseError('fixture interrupted upload')
        self.uploads.append(name)
        self.release['assets'].append({'id': len(self.uploads), 'name': name, 'state': 'uploaded',
            'size': path.stat().st_size, 'digest': 'sha256:' + policy.sha256(path)})

    def asset_bytes(self, asset, destination):
        shutil.copyfile(self.files[asset['name']]['path'], destination)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def assets(self):
        result = {}
        for name in ['test.apk', 'update.json', 'JMS-test-source.zip']:
            path = self.root / name
            path.write_bytes(('fixture ' + name).encode())
            result[name] = {'path': str(path), 'size': path.stat().st_size, 'sha256': policy.sha256(path)}
        return result

    def state(self):
        return {'releaseId': 7, 'tag': 'vfixture', 'version': 'fixture', 'prerelease': True, 'notes': 'fixture notes'}

    def test_partial_draft_upload_resumes_without_duplicate_uploads(self):
        files = self.assets()
        github = FakeGithub(files)
        github.fail_once = 'update.json'
        state = self.state()
        target = self.root / 'verified'
        target.mkdir()
        saved = []
        with self.assertRaises(policy.ReleaseError):
            policy.upload_complete_release(github, state, files, lambda: saved.append(copy.deepcopy(state)), target)
        self.assertTrue(github.release['draft'])
        self.assertEqual(github.publishes, 0)
        policy.upload_complete_release(github, state, files, lambda: saved.append(copy.deepcopy(state)), target)
        self.assertEqual(github.uploads, list(files))
        self.assertEqual(github.publishes, 1)
        self.assertFalse(github.release['draft'])
        policy.upload_complete_release(github, state, files, lambda: None, target)
        self.assertEqual(github.uploads, list(files))
        self.assertEqual(github.publishes, 1)

    def test_existing_content_or_channel_mismatch_never_mutates(self):
        files = self.assets()
        for change in [{'body': 'different'}, {'name': 'JMS other'}, {'prerelease': False}, {'tag_name': 'elsewhere'}]:
            with self.subTest(change=change):
                github = FakeGithub(files)
                github.release.update(change)
                with self.assertRaises(policy.ReleaseError):
                    policy.upload_complete_release(github, self.state(), files, lambda: None, self.root)
                self.assertEqual(github.uploads, [])
                self.assertEqual(github.publishes, 0)

    def test_published_missing_asset_is_not_repaired_by_mutation(self):
        github = FakeGithub(self.assets())
        github.release['draft'] = False
        with self.assertRaises(policy.ReleaseError):
            policy.upload_complete_release(github, self.state(), github.files, lambda: None, self.root)
        self.assertEqual(github.uploads, [])

    def test_digest_size_duplicate_and_unexpected_asset_rejected(self):
        files = self.assets()
        asset = {'name': 'test.apk', 'state': 'uploaded', 'size': files['test.apk']['size'],
                 'digest': 'sha256:' + files['test.apk']['sha256']}
        for assets in [[dict(asset, size=1)], [dict(asset, digest='sha256:' + '0' * 64)],
                       [asset, asset], [dict(asset, name='extra')], [dict(asset, state='new')]]:
            with self.subTest(assets=assets), self.assertRaises(policy.ReleaseError):
                policy.match_assets({'assets': assets}, files)

    def test_corrupt_draft_download_blocks_publication(self):
        files = self.assets()
        github = FakeGithub(files)
        target = self.root / 'download'
        target.mkdir()
        def corrupt(asset, destination):
            Path(destination).write_bytes(b'wrong content')
        github.asset_bytes = corrupt
        with self.assertRaises(policy.ReleaseError):
            policy.upload_complete_release(github, self.state(), files, lambda: None, target)
        self.assertTrue(github.release['draft'])
        self.assertEqual(github.publishes, 0)

    def test_exclusive_lock_recovers_after_exception(self):
        lock = self.root / 'release.lock'
        with self.assertRaisesRegex(RuntimeError, 'fixture'):
            with policy.release_lock(lock):
                with self.assertRaises(policy.ReleaseError):
                    with policy.release_lock(lock):
                        self.fail('Concurrent publication entered')
                raise RuntimeError('fixture')
        with policy.release_lock(lock):
            self.assertTrue(lock.exists())

    def test_atomic_state_file_is_readable_and_has_no_pending_file(self):
        path = self.root / 'state.json'
        policy.save_json(path, {'phase': 'draft'})
        policy.save_json(path, {'phase': 'verified'})
        self.assertEqual(policy.read_json(path), {'phase': 'verified'})
        self.assertFalse(path.with_suffix('.json.pending').exists())

    def evidence(self, name, value):
        path = self.root / name
        policy.save_json(path, value)
        return {'path': name, 'sha256': policy.sha256(path)}

    def test_custody_and_native_gates_are_hash_bound_not_key_name_based(self):
        apk = self.root / 'baseline.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('lib/arm64-v8a/libmdk.so', b'fixture native')
        audit = self.evidence('audit.json', {'fixture': True, 'status': 'PASS'})
        signing = {'status': 'APPROVED', 'signerSha256': policy.SIGNER, 'knownCompromise': False,
                   'ownerStatement': 'test fixture, not a real custody claim', 'reviewedAt': 'fixture',
                   'sharingHistory': 'fixture, no real custody assertion', 'backupCustody': 'fixture',
                   'localExposureAudit': 'PASS', 'auditEvidence': audit}
        native = {'status': 'APPROVED', 'missing': [], 'nativeHashes': policy.native_hashes(apk),
                  'reviewedBy': 'fixture', 'legalBasis': ['fixture'], 'materials': [audit]}
        config = {'schemaVersion': 1, 'repository': policy.REPOSITORY,
                  'signingEvidence': self.evidence('signing.json', signing),
                  'nativeEvidence': self.evidence('native.json', native)}
        with patch.object(policy, 'ROOT', self.root):
            self.assertEqual(policy.publication_gates(config, apk), [])
            signing.pop('sharingHistory')
            incomplete = dict(config, signingEvidence=self.evidence('partial.json', signing))
            self.assertTrue(any('sharing' in message for message in policy.publication_gates(incomplete, apk)))
            self.assertTrue(policy.publication_gates(config, apk, signer='different'))
            (self.root / 'audit.json').write_text('changed')
            self.assertEqual(len(policy.publication_gates(config, apk)), 2)
            self.assertEqual(len(policy.publication_gates(dict(config, signingEvidence=None, nativeEvidence=None), apk)), 2)

    def test_other_repository_and_unapproved_custody_are_rejected(self):
        self.assertTrue(policy.publication_gates({'schemaVersion': 1, 'repository': 'DonutWare/Fladder'}, None))
        github = policy.Github()
        with self.assertRaises(policy.ReleaseError):
            github.api('repos/jim608/JMS-Android-other/releases', 'POST', {})
        with self.assertRaises(policy.ReleaseError):
            github.api('repos/DonutWare/Fladder/releases', 'POST', {})

    def test_https_download_hosts_are_restricted(self):
        self.assertTrue(policy.allowed_url('https://github.com/jim608/JMS-Android/releases/download/v1/app.apk'))
        self.assertTrue(policy.allowed_url('https://release-assets.githubusercontent.com/x?signature=fixture', redirect=True))
        for url in ['http://github.com/jim608/JMS-Android/releases/download/v1/app.apk',
                    'https://github.com/DonutWare/Fladder/releases/download/v1/app.apk',
                    'https://example.com/app.apk', 'https://' + 'user:' + 'password@github.com/jim608/JMS-Android/releases/download/x/y']:
            self.assertFalse(policy.allowed_url(url, redirect=True))

    def test_anonymous_download_rejects_wrong_hash_and_cleans_temporary_file(self):
        target = self.root / 'download.apk'
        payload = b'fixture apk'
        opener = unittest.mock.Mock()
        opener.open.return_value = io.BytesIO(payload)
        with patch.object(policy.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaises(policy.ReleaseError):
                policy.anonymous_download('https://github.com/jim608/JMS-Android/releases/download/v1/a.apk',
                                          target, len(payload), '0' * 64)
        self.assertFalse(target.exists())
        self.assertFalse(target.with_suffix('.apk.part').exists())
        request = opener.open.call_args.args[0]
        self.assertFalse(request.has_header('Authorization'))

    def test_source_snapshot_preserves_head_index_and_excludes_private_history(self):
        with patch.object(policy, 'ROOT', self.root), patch.object(publisher, 'ROOT', self.root):
            policy.execute(['git', 'init', '-q'])
            (self.root / 'LICENSE').write_text('fixture license')
            for name in ['pubspec.yaml', 'pubspec.lock', '.fvmrc', 'AGENTS.md']:
                (self.root / name).write_text('fixture\r\n')
            (self.root / 'config').mkdir()
            (self.root / 'config/jms_updates.json').write_text('{}')
            (self.root / 'unrelated.txt').write_text('must not enter source snapshot')
            policy.execute(['git', 'add', 'unrelated.txt'])
            index_before = policy.execute(['git', 'ls-files', '--stage'])
            files = policy.source_files()
            state_directory = self.root / 'state'
            state_directory.mkdir()
            commit = publisher.snapshot_source(files, None, state_directory, 'fixture')
            self.assertEqual(index_before, policy.execute(['git', 'ls-files', '--stage']))
            tree = policy.execute(['git', 'ls-tree', '-r', '--name-only', commit]).decode()
            self.assertNotIn('unrelated.txt', tree)
            self.assertIn('AGENTS.md', tree)
            parents = policy.execute(['git', 'rev-list', '--parents', '-n', '1', commit]).decode().split()
            self.assertEqual(parents, [commit])
            self.assertEqual(policy.execute(['git', 'cat-file', 'blob', commit + ':pubspec.yaml']),
                             (self.root / 'pubspec.yaml').read_bytes())

    def test_local_candidate_binding_preserves_original_record_and_checks_inputs(self):
        original = self.root / 'build.json'
        original.write_text('original evidence')
        apk = self.root / 'candidate.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('lib/arm64-v8a/libapp.so', b'JMS-build-fixture')
        record = {'mode': 'release', 'buildId': 'JMS-build-fixture', 'sourceCommit': 'old',
                  'inputs': [{'path': 'lib/main.dart', 'sha256': 'fixture'}]}
        with patch.object(publisher, 'require_bound_sources') as bound, patch.object(publisher, 'verify_snapshot') as snapshot:
            result = publisher.bind_candidate_record(record, 'reviewed', apk, original)
            bound.assert_called_once_with(record)
            snapshot.assert_called_once_with('reviewed', record['inputs'])
            self.assertEqual(result['sourceCommit'], 'reviewed')
            self.assertEqual(result['originalBuildSourceCommit'], 'old')
            self.assertEqual(record['sourceCommit'], 'old')
            self.assertEqual(original.read_text(), 'original evidence')
            with self.assertRaisesRegex(policy.ReleaseError, 'build ID'):
                publisher.bind_candidate_record(dict(record, buildId='wrong'), 'reviewed', apk, original)
            bound.side_effect = ValueError('Build input drift')
            with self.assertRaisesRegex(ValueError, 'Build input drift'):
                publisher.bind_candidate_record(record, 'reviewed', apk, original)

    def test_quality_cache_reuses_unchanged_scopes_and_rejects_modified_logs(self):
        def run(command, log, timeout):
            log.write_text('PASS')
        with patch.object(publisher, 'ROOT', self.root), patch.object(publisher, 'PUBLICATION', self.root), \
             patch.object(publisher, 'execute', side_effect=run) as execute:
            files = {'lib/main.dart': 'app', 'scripts/tool.py': 'tool', 'docs/status.md': 'old'}
            publisher.quality_checks(files)
            self.assertEqual(execute.call_count, 3)
            publisher.quality_checks(dict(files, **{'docs/status.md': 'new'}))
            self.assertEqual(execute.call_count, 3)
            publisher.quality_checks(dict(files, **{'scripts/tool.py': 'changed'}))
            self.assertEqual(execute.call_count, 4)
            (self.root / 'flutter-tests.log').write_text('tampered')
            publisher.quality_checks(dict(files, **{'scripts/tool.py': 'changed'}))
            self.assertEqual(execute.call_count, 5)

    def test_source_scanner_refuses_secret_material(self):
        with patch.object(policy, 'ROOT', self.root):
            policy.execute(['git', 'init', '-q'])
            (self.root / 'lib').mkdir()
            (self.root / 'lib/private.dart').write_bytes(b'-----BEGIN ' + b'PRIVATE KEY-----')
            with self.assertRaises(policy.ReleaseError):
                policy.source_files()

    def test_failed_preflight_cannot_reach_build_or_remote_write(self):
        config = {'baselineApk': 'base.apk', 'baselineSha256': 'fixture'}
        github = unittest.mock.Mock()
        with patch.object(publisher, 'PUBLICATION', self.root / 'publication'), \
             patch.object(publisher, 'read_json', return_value=config), \
             patch.object(publisher, 'sha256', return_value='fixture'), \
             patch.object(publisher, 'apk_info', return_value=({'versionCode': 2008}, policy.SIGNER, True, '', '')), \
             patch.object(publisher, 'verify_legacy_checker'), \
             patch.object(publisher, 'Github', return_value=github), \
             patch.object(publisher, 'source_files', return_value={}), \
             patch.object(publisher, 'quality_checks', return_value={'status': 'PASS'}), \
             patch.object(publisher, 'publication_gates', return_value=['NATIVE: missing exact sources']), \
             patch.object(publisher, 'version_info', return_value=('0.11.1-jms.9', 2009)), \
             patch.object(publisher, 'execute') as run:
            with self.assertRaisesRegex(policy.ReleaseError, 'missing exact sources'):
                publisher.publish(argparse.Namespace(channel='prerelease', dry_run=False))
            run.assert_not_called()
            github.call.assert_not_called()
            github.api.assert_not_called()
            github.releases.assert_not_called()


if __name__ == '__main__':
    unittest.main()
