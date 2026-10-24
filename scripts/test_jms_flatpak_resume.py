import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import resume_jms_flatpak as resume
from jms_publication import ReleaseError


class FlatpakResumeTests(unittest.TestCase):
    source = 'a' * 40
    bundle_name = 'JMS-Linux-0.11.1-jms.35-x86_64.flatpak'

    def fixture(self):
        run = {'id': 123, 'status': 'completed', 'conclusion': 'failure',
               'head_sha': self.source, 'head_branch': 'jms', 'path': resume.WORKFLOW,
               'event': 'workflow_dispatch', 'run_attempt': 1,
               'repository': {'full_name': resume.REPOSITORY},
               'head_repository': {'full_name': resume.REPOSITORY}}
        jobs = {'total_count': 1, 'jobs': [{'name': 'flatpak', 'status': 'completed',
                'conclusion': 'failure', 'steps': [
                    {'name': name, 'status': 'completed', 'conclusion': 'success'}
                    for name in resume.NATIVE_STEPS]}]}
        artifact = {'id': 456, 'name': 'jms-flatpak-failure-' + self.source + '-1',
                    'expired': False, 'size_in_bytes': 99, 'digest': 'sha256:' + 'b' * 64,
                    'workflow_run': {'id': 123, 'head_branch': 'jms', 'head_sha': self.source}}
        return run, jobs, {'total_count': 1, 'artifacts': [artifact]}

    def github(self, records):
        github = Mock()
        github.api.side_effect = records
        return github

    def archive(self, name=None, extra=None):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr(name or 'candidate/' + self.bundle_name, b'original-bundle-bytes')
            if extra:
                archive.writestr(extra, b'unexpected')
        return data.getvalue()

    def test_requires_both_completed_original_native_build_steps(self):
        records = self.fixture()
        result = resume.native_artifact(self.github(records), 123, self.source)
        self.assertEqual(result['id'], 456)
        for state in ('failure', 'skipped', None):
            with self.subTest(state=state):
                changed = copy.deepcopy(records)
                changed[1]['jobs'][0]['steps'][1]['conclusion'] = state
                with self.assertRaises(ReleaseError):
                    resume.native_artifact(self.github(changed), 123, self.source)

    def test_rejects_wrong_source_fork_workflow_branch_and_incomplete_run(self):
        for field, value in [('head_sha', 'c' * 40), ('head_branch', 'main'),
                             ('path', '.github/workflows/other.yml'),
                             ('status', 'in_progress'), ('conclusion', 'success'),
                             ('head_repository', {'full_name': 'example/fork'})]:
            with self.subTest(field=field):
                records = self.fixture()
                records[0][field] = value
                with self.assertRaises(ReleaseError):
                    resume.native_artifact(self.github(records), 123, self.source)

    def test_rejects_expired_unhashed_ambiguous_or_different_origin_artifact(self):
        for field, value in [('expired', True), ('digest', ''),
                             ('workflow_run', {'id': 999, 'head_sha': self.source,
                                               'head_branch': 'jms'})]:
            with self.subTest(field=field):
                records = self.fixture()
                records[2]['artifacts'][0][field] = value
                with self.assertRaises(ReleaseError):
                    resume.native_artifact(self.github(records), 123, self.source)
        records = self.fixture()
        records[2]['artifacts'] *= 2
        records[2]['total_count'] = 2
        with self.assertRaises(ReleaseError):
            resume.native_artifact(self.github(records), 123, self.source)

    def test_binary_download_requires_registered_sha256(self):
        data = self.archive()
        github = Mock(executable='gh', environment={})
        for correct in (True, False):
            with self.subTest(correct=correct), tempfile.TemporaryDirectory() as temporary:
                artifact = {'id': 456, 'digest': 'sha256:' + (
                    hashlib.sha256(data).hexdigest() if correct else '0' * 64)}
                process = Mock(stdout=io.BytesIO(data))
                process.wait.return_value = process.poll.return_value = 0
                with patch.object(resume.subprocess, 'Popen', return_value=process):
                    if correct:
                        resume.download(github, artifact, Path(temporary) / 'artifact.zip')
                    else:
                        with self.assertRaises(ReleaseError):
                            resume.download(github, artifact, Path(temporary) / 'artifact.zip')

    def test_extracts_only_original_bundle_and_rejects_ambiguous_or_unsafe_zip(self):
        cases = [self.archive(), self.archive(extra='../unsafe'),
                 self.archive(extra=self.bundle_name)]
        for index, data in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / 'artifact.zip'
                archive.write_bytes(data)
                target = Path(temporary) / self.bundle_name
                if index == 0:
                    member = resume.extract_bundle(archive, target, self.bundle_name)
                    self.assertEqual(member, 'candidate/' + self.bundle_name)
                    self.assertEqual(target.read_bytes(), b'original-bundle-bytes')
                else:
                    with self.assertRaises(ReleaseError):
                        resume.extract_bundle(archive, target, self.bundle_name)

    def test_resume_preserves_app_identity_and_refuses_existing_candidate(self):
        artifact = self.fixture()[2]['artifacts'][0]
        data = self.archive()
        def download(_github, _artifact, destination):
            destination.write_bytes(data)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'candidate'
            with patch.object(resume, 'native_artifact', return_value=artifact), \
                    patch.object(resume, 'download', side_effect=download), \
                    patch.object(resume.subprocess, 'check_output',
                                 return_value=b'version: 0.11.1-jms.35+37\n'):
                origin = resume.resume(Mock(), 123, self.source, output)
                self.assertEqual(origin['sourceCommit'], self.source)
                self.assertEqual(origin['buildId'], 'JMS-0.11.1-jms.35-flatpak-' + self.source[:12])
                self.assertEqual(origin['bundle']['sha256'], hashlib.sha256(b'original-bundle-bytes').hexdigest())
                self.assertEqual(json.loads((output / 'native-build-origin.json').read_text()), origin)
                with self.assertRaises(ReleaseError):
                    resume.resume(Mock(), 123, self.source, output)


if __name__ == '__main__':
    unittest.main()
