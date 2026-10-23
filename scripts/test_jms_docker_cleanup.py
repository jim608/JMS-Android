"""Failure boundaries for retiring only owned, stopped containers after evidence."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import jms_docker_cleanup as cleanup

CID = 'a' * 64
IMAGE = 'sha256:' + 'b' * 64


class RetirementTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.ledger = Path(self.temporary.name) / 'owned.json'
        cleanup.write_json(self.ledger, {'schemaVersion': 1, 'owner': 'test-owner', 'containers': [
            {'id': CID, 'imageId': IMAGE, 'purpose': 'package-export', 'status': 'CREATED'}]})
        self.row = {'Id': CID, 'Image': IMAGE,
                    'Config': {'Labels': {cleanup.OWNER: 'test-owner', cleanup.PURPOSE: 'package-export'},
                               'Env': ['PRIVATE_FIXTURE=do-not-print']},
                    'State': {'Status': 'exited', 'Running': False, 'ExitCode': 1}}
        self.calls = []

    def capture(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == 'diff':
            return b''
        if arguments[0] == 'rm':
            entry = json.loads(self.ledger.read_text())['containers'][0]
            self.assertEqual(entry['status'], 'EVIDENCE_SAVED')
            self.assertTrue(entry['evidence']['files'])
            self.assertTrue(Path(entry['evidence']['directory'], 'inspect.json').exists())
            return CID.encode()
        if arguments[0] == 'ps':
            self.assertIn(('rm', CID), self.calls)
            return b''
        raise AssertionError(arguments)

    def retire(self, capture=None):
        output = io.StringIO()
        with patch.object(cleanup, 'inspect', return_value=self.row), \
                patch.object(cleanup, 'capture', side_effect=capture or self.capture), \
                patch.object(cleanup, 'docker') as docker, contextlib.redirect_stdout(output):
            result = cleanup.retire(self.ledger)
        self.assertNotIn('PRIVATE_FIXTURE', output.getvalue())
        self.assertNotIn('do-not-print', output.getvalue())
        return result, docker

    def test_failed_test_exit_is_archived_before_ordinary_full_id_rm_and_fresh_inventory(self):
        result, docker = self.retire()
        self.assertEqual(result, 0)
        self.assertEqual(self.calls, [('diff', CID), ('rm', CID),
                                     ('ps', '--all', '--no-trunc', '--format', '{{.ID}}')])
        self.assertEqual(docker.call_args.args, ('logs', CID))
        entry = json.loads(self.ledger.read_text())['containers'][0]
        self.assertEqual(entry['status'], 'REMOVED_VERIFIED')
        self.assertEqual(json.loads(Path(entry['evidence']['directory'], 'inspect.json').read_text()), self.row)

    def test_running_or_unknown_container_is_preserved_without_stop_export_or_rm(self):
        for state in ({'Status': 'running', 'Running': True}, {'Status': 'paused', 'Running': False}, {}):
            with self.subTest(state=state):
                self.row['State'] = state
                self.calls.clear()
                result, _ = self.retire()
                self.assertEqual(result, 1)
                self.assertEqual(self.calls, [('diff', CID)])

    def test_mismatched_owner_image_or_purpose_never_reaches_archive_or_rm(self):
        for field in ('Image', 'Id'):
            with self.subTest(field=field):
                original = self.row[field]
                self.row[field] = 'different'
                result, docker = self.retire()
                self.assertEqual(result, 1)
                self.assertFalse(self.calls)
                docker.assert_not_called()
                self.row[field] = original

    def test_archive_failure_keeps_container(self):
        def capture(*arguments):
            self.calls.append(arguments)
            if arguments[0] == 'diff':
                return b'A /tmp/test-result\n'
            raise AssertionError(arguments)
        with patch.object(cleanup, 'changed_layer', side_effect=OSError('archive write failed')):
            result, _ = self.retire(capture)
        self.assertEqual(result, 1)
        self.assertEqual(self.calls, [('diff', CID)])

    def test_failed_log_capture_refuses_removal(self):
        with patch.object(cleanup, 'inspect', return_value=self.row), \
                patch.object(cleanup, 'capture', side_effect=self.capture), \
                patch.object(cleanup, 'docker', side_effect=subprocess.CalledProcessError(1, ['docker', 'logs'])), \
                contextlib.redirect_stdout(io.StringIO()):
            result = cleanup.retire(self.ledger)
        self.assertEqual(result, 1)
        self.assertFalse(self.calls)

    def test_daemon_query_failure_cannot_be_reported_as_absence(self):
        def capture(*arguments):
            if arguments[0] == 'ps':
                raise subprocess.CalledProcessError(1, ['docker', 'ps'])
            return self.capture(*arguments)
        result, _ = self.retire(capture)
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(self.ledger.read_text())['containers'][0]['status'], 'RETAINED')

    def test_restart_after_archive_refuses_rm(self):
        output = io.StringIO()
        running = dict(self.row, State={'Status': 'running', 'Running': True})
        with patch.object(cleanup, 'inspect', side_effect=[self.row, running]), \
                patch.object(cleanup, 'capture', side_effect=self.capture), \
                patch.object(cleanup, 'docker'), contextlib.redirect_stdout(output):
            result = cleanup.retire(self.ledger)
        self.assertEqual(result, 1)
        self.assertNotIn(('rm', CID), self.calls)

    def test_interrupted_absence_check_can_resume_only_with_saved_evidence_and_fresh_inventory(self):
        def failed_inventory(*arguments):
            if arguments[0] == 'ps':
                raise subprocess.CalledProcessError(1, ['docker', 'ps'])
            return self.capture(*arguments)
        self.assertEqual(self.retire(failed_inventory)[0], 1)
        with patch.object(cleanup, 'inspect', side_effect=subprocess.CalledProcessError(1, ['docker', 'inspect'])), \
                patch.object(cleanup, 'capture', return_value=b'') as capture, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cleanup.retire(self.ledger), 0)
        capture.assert_called_once_with('ps', '--all', '--no-trunc', '--format', '{{.ID}}')


class ChangedLayerTest(unittest.TestCase):
    def test_archive_keeps_changed_members_and_omits_unchanged_image_files(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            directory = tarfile.TarInfo('etc')
            directory.type = tarfile.DIRTYPE
            archive.addfile(directory)
            for name, content in [('etc/fixture', b'changed'), ('unchanged-large-image-file', b'omitted')]:
                member = tarfile.TarInfo(name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))

        class Export:
            stdout = io.BytesIO(data.getvalue())
            def wait(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, patch.object(cleanup.subprocess, 'Popen', return_value=Export()) as process:
            output = Path(temporary) / 'changed-layer.tar.gz'
            self.assertTrue(cleanup.changed_layer(CID, b'C /etc\nC /etc/fixture\nD /tmp/deleted\n', output))
            with tarfile.open(output, 'r:gz') as archive:
                self.assertEqual(archive.getnames(), ['etc', 'etc/fixture'])
                self.assertEqual(archive.extractfile('etc/fixture').read(), b'changed')
            self.assertEqual(process.call_args.args[0], ['docker', 'export', CID])
            manifest = json.loads(output.with_name('changed-layer-manifest.json').read_text())
            self.assertFalse(manifest['mountedDataIncluded'])
            self.assertEqual(manifest['deletionsPreservedIn'], 'diff.txt')
            self.assertEqual(manifest['deletedPaths'], ['/tmp/deleted'])

    def test_incomplete_export_refuses_retirement(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w'):
            pass
        class Export:
            stdout = io.BytesIO(data.getvalue())
            def wait(self):
                return 0
        with tempfile.TemporaryDirectory() as temporary, patch.object(cleanup.subprocess, 'Popen', return_value=Export()):
            output = Path(temporary) / 'changed-layer.tar.gz'
            with self.assertRaisesRegex(ValueError, 'missed diff members'):
                cleanup.changed_layer(CID, b'A /missing-test-result\n', output)


if __name__ == '__main__':
    unittest.main()
