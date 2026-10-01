import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import verify_jms_snapshot as snapshot
import jms_git_release
import jms_publication
from jms_publication import ReleaseError


class SnapshotBatchTests(unittest.TestCase):
    def test_binary_and_spaced_paths_missing_objects_and_changed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args, data=None):
                return subprocess.check_output(['git', '-C', directory, *args], input=data,
                                               stderr=subprocess.PIPE)
            git('init', '-q')
            git('config', 'user.name', 'fixture')
            git('config', 'user.email', 'fixture@users.noreply.github.com')
            inputs = []
            for name, content in [('one file.txt', b'line\n'), ('binary.bin', b'\0\xff\nblob\n')]:
                Path(directory, name).write_bytes(content)
                inputs.append({'path': name, 'sha256': hashlib.sha256(content).hexdigest()})
            git('add', 'one file.txt', 'binary.bin')
            git('commit', '-qm', 'fixture')
            commit = git('rev-parse', 'HEAD').decode().strip()
            def execute(command, *, data=None):
                return git(*command[1:], data=data)
            with patch.object(snapshot, 'execute', execute):
                snapshot.verify_snapshot(commit, inputs)
                with self.assertRaises(ReleaseError):
                    snapshot.verify_snapshot(commit, [dict(inputs[0], sha256='0' * 64)])
                with self.assertRaises(ReleaseError):
                    snapshot.verify_snapshot(commit, [dict(inputs[0], path='missing')])
                with self.assertRaises(ReleaseError):
                    snapshot.verify_snapshot(commit, [dict(inputs[0], path='one\nfile')])


class RecordedWindowsCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.remote = self.root / 'source.git'
        subprocess.check_output(['git', 'init', '--bare', '-q', str(self.remote)])
        self.git('init', '-q', '-b', 'jms')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'user.email', 'fixture@users.noreply.github.com')
        contents = {'LICENSE': b'synthetic license', 'pubspec.yaml': b'version: 1.2.3-jms.4+5\n',
                    'pubspec.lock': b'synthetic pinned lock', '.fvmrc': b'{}',
                    'config/jms_updates.json': b'{}', 'config/jms_public_privacy_reviews.json': b'[]',
                    'config/jms_windows_native.json': json.dumps({'libraries': [{'dll': 'synthetic.dll', 'sha256': hashlib.sha256(b'synthetic native').hexdigest()}]}).encode(),
                    'lib/main.dart': b'void main() {}', 'windows/CMakeLists.txt': b'synthetic cmake',
                    'scripts/build_jms_windows.ps1': b'synthetic build input',
                    'scripts/jms_publication.py': b'synthetic publication tool',
                    'scripts/test_jms_publish.py': b'synthetic test'}
        for name, data in contents.items(): self.write(name, data)
        self.git('add', *contents)
        self.git('commit', '-qm', 'synthetic candidate source')
        self.commit = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('push', '-q', str(self.remote), 'jms')
        self.artifacts = self.root / 'artifacts'
        self.artifacts.mkdir()
        self.build = {'application': 'JMS', 'version': '1.2.3-jms.4', 'versionCode': 5,
                      'sourceCommit': self.commit, 'buildId': 'JMS-1.2.3-jms.4-windows-' + self.commit[:12],
                      'platform': 'windows-x64', 'signing': 'unsigned', 'privateConfiguration': False}
        self.portable = self.artifacts / 'JMS-Windows-1.2.3-jms.4-x64-portable.zip'
        self.installer = self.artifacts / 'JMS-Windows-1.2.3-jms.4-x64-setup.exe'
        self.installer.write_bytes(b'synthetic installer fingerprint')
        self.write_portable()
        self.manifest = self.artifacts / 'build-manifest.json'
        self.record_manifest()
        def execute(command, *, data=None): return self.git(*command[1:], data=data)
        self.enterContext(patch.object(snapshot, 'execute', execute))
        self.enterContext(patch.object(jms_publication, 'execute', execute))
        self.enterContext(patch.object(jms_publication, 'ROOT', self.repo))
        self.enterContext(patch.object(jms_git_release, 'git', lambda *args: self.git(*args).decode().strip()))

    def git(self, *args, data=None):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], input=data, stderr=subprocess.PIPE)

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def write_portable(self, *, native=b'synthetic native', info=None):
        with zipfile.ZipFile(self.portable, 'w') as archive:
            prefix = 'JMS-Windows-1.2.3-jms.4-x64/'
            archive.writestr(prefix + 'JMS_BUILD_INFO.json', json.dumps(self.build if info is None else info))
            archive.writestr(prefix + 'synthetic.dll', native)

    def record_manifest(self):
        outputs = [{'file': path.name, 'size': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                   for path in (self.portable, self.installer)]
        self.manifest.write_text(json.dumps({'build': self.build, 'outputs': outputs}), encoding='utf-8')

    def verify(self):
        return snapshot.verify_recorded_windows_candidate(self.commit, self.manifest, source_remote=str(self.remote))

    def test_later_exact_review_paths_keep_original_source_and_fingerprints(self):
        for name in snapshot.RECORDED_CANDIDATE_REVIEW_PATHS:
            self.write(name, b'[{"synthetic": true}]' if name.endswith('.json') else b'synthetic release-only change')
        self.git('add', *snapshot.RECORDED_CANDIDATE_REVIEW_PATHS)
        self.git('commit', '-qm', 'synthetic later reviews')
        result = self.verify()
        self.assertEqual(result['sourceCommit'], self.commit)
        self.assertEqual(result['outputs'][0]['sha256'], hashlib.sha256(self.portable.read_bytes()).hexdigest())
        self.assertEqual(set(result['laterReviewedPaths']), snapshot.RECORDED_CANDIDATE_REVIEW_PATHS)
        with self.assertRaises(ReleaseError): snapshot.verify_snapshot(self.commit)

    def test_uncommitted_and_build_changes_are_rejected(self):
        for path in ['lib/main.dart', 'pubspec.lock', 'config/jms_windows_native.json',
                     'windows/CMakeLists.txt', 'scripts/build_jms_windows.ps1', 'config/unreviewed.json']:
            with self.subTest(path=path):
                previous = (self.repo / path).read_bytes() if (self.repo / path).exists() else None
                self.write(path, b'synthetic changed input')
                with self.assertRaises(jms_git_release.GitReleaseError): self.verify()
                self.git('add', path)
                self.git('commit', '-qm', 'synthetic changed build input')
                with self.assertRaises(ReleaseError): self.verify()
                if previous is None:
                    self.git('rm', '-q', '--', path)
                else:
                    self.write(path, previous)
                    self.git('add', path)
                self.git('commit', '-qm', 'restore synthetic build input')

    def test_recorded_outputs_build_identity_and_native_content_cannot_be_rebound(self):
        self.portable.write_bytes(self.portable.read_bytes() + b'changed')
        with self.assertRaises(ReleaseError): self.verify()
        self.write_portable(info=dict(self.build, sourceCommit='0' * 40))
        self.record_manifest()
        with self.assertRaises(ReleaseError): self.verify()
        self.write_portable(native=b'changed native')
        self.record_manifest()
        with self.assertRaises(ReleaseError): self.verify()

    def test_unpushed_candidate_is_rejected(self):
        self.write('lib/main.dart', b'synthetic unpublished source')
        self.git('add', 'lib/main.dart')
        self.git('commit', '-qm', 'synthetic unpushed candidate')
        self.commit = self.git('rev-parse', 'HEAD').decode().strip()
        with self.assertRaises(subprocess.CalledProcessError): self.verify()
