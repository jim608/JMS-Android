"""Failure boundaries for retiring only owned, stopped containers after evidence."""
import contextlib
import base64
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import urllib.parse
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
            with patch.object(cleanup, 'archive_socket_metadata', side_effect=ValueError('regular file missing')), \
                    self.assertRaisesRegex(ValueError, 'regular file missing'):
                cleanup.changed_layer(CID, b'A /missing-test-result\n', output)


class SocketMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.path = '/run/dbus/system_bus_socket'
        self.row = {'Id': CID, 'Image': IMAGE, 'Config': {'Labels': {
            cleanup.OWNER: 'test-owner', cleanup.PURPOSE: 'arch-install'}},
            'State': {'Status': 'exited', 'Running': False, 'ExitCode': 0,
                      'StartedAt': '2026-10-23T01:00:00Z', 'FinishedAt': '2026-10-23T01:01:00Z'}}
        cleanup.write_json(self.directory / 'inspect.json', self.row)
        self.stat = {'name': 'system_bus_socket', 'size': 0,
                     'mode': cleanup.GO_MODE_SOCKET | 0o777, 'mtime': '2026-10-23T01:00:01Z', 'linkTarget': ''}
        self.calls = []

    def engine(self, method, path):
        self.calls.append((method, path))
        if method == 'GET':
            self.assertEqual(path, '/containers/' + CID + '/json')
            return {}, json.dumps(self.row).encode()
        self.assertEqual(method, 'HEAD')
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlparse(path).query), {'path': [self.path]})
        value = base64.b64encode(json.dumps(self.stat).encode()).decode()
        return {'x-docker-container-path-stat': value}, b''

    def archive(self):
        with patch.object(cleanup, 'engine_request', side_effect=self.engine):
            return cleanup.archive_socket_metadata(CID, [self.path], self.directory)

    def test_verified_socket_stat_is_retained_with_exact_identity_and_double_checked_type(self):
        self.assertEqual(self.archive(), {self.path})
        proof = json.loads((self.directory / 'non-exportable-sockets.json').read_text())
        self.assertEqual(proof['containerId'], CID)
        self.assertEqual(proof['imageId'], IMAGE)
        self.assertFalse(proof['containsFilePayload'])
        self.assertEqual(proof['records'][0]['stat'], self.stat)
        self.assertEqual([call[0] for call in self.calls], ['GET', 'HEAD', 'GET', 'HEAD'])

    def test_regular_unknown_fifo_directory_and_posix_socket_modes_are_refused(self):
        for mode in (0o644, 1 << 25, 1 << 31, 1 << 19, 0o140777,
                     cleanup.GO_MODE_SOCKET | (1 << 18), -1, cleanup.GO_MODE_SOCKET | (1 << 32)):
            with self.subTest(mode=mode):
                self.stat['mode'] = mode
                with self.assertRaisesRegex(ValueError, 'not a verified'):
                    self.archive()
                self.assertFalse((self.directory / 'non-exportable-sockets.json').exists())

    def test_mismatched_name_or_nonzero_payload_is_refused(self):
        for key, value in (('name', 'different'), ('size', 1), ('size', False), ('linkTarget', '/different')):
            with self.subTest(key=key):
                original = self.stat[key]
                self.stat[key] = value
                with self.assertRaisesRegex(ValueError, 'not a verified'):
                    self.archive()
                self.stat[key] = original

    def test_changed_owner_image_or_running_container_is_refused(self):
        self.row['Image'] = 'sha256:' + 'c' * 64
        with self.assertRaisesRegex(ValueError, 'image or purpose changed'):
            self.archive()
        self.row['Image'] = IMAGE
        self.row['Config']['Labels'][cleanup.OWNER] = 'other-owner'
        with self.assertRaisesRegex(ValueError, 'image or purpose changed'):
            self.archive()
        self.row['Config']['Labels'][cleanup.OWNER] = 'test-owner'
        self.row['State']['Running'] = True
        with self.assertRaisesRegex(ValueError, 'lifecycle changed'):
            self.archive()
        self.row['State']['Running'] = False
        self.row['State']['FinishedAt'] = '2026-10-23T01:02:00Z'
        with self.assertRaisesRegex(ValueError, 'lifecycle changed'):
            self.archive()

    def test_head_failure_and_changed_stat_are_refused(self):
        def fail(method, path):
            if method == 'HEAD':
                raise ValueError('HEAD failed')
            return self.engine(method, path)
        with patch.object(cleanup, 'engine_request', side_effect=fail), self.assertRaisesRegex(ValueError, 'HEAD failed'):
            cleanup.archive_socket_metadata(CID, [self.path], self.directory)
        def changing(method, path):
            if len(self.calls) == 3:
                self.stat['mtime'] = '2026-10-23T01:00:02Z'
            return self.engine(method, path)
        self.calls.clear()
        with patch.object(cleanup, 'engine_request', side_effect=changing), self.assertRaisesRegex(ValueError, 'Socket stat changed'):
            cleanup.archive_socket_metadata(CID, [self.path], self.directory)

    def test_different_daemon_transport_fails_closed(self):
        with patch.dict(cleanup.os.environ, {'DOCKER_CONTEXT': 'test-context'}), \
                patch.object(cleanup, 'capture', return_value=b'"tcp://fixture.invalid:2375"'), \
                self.assertRaisesRegex(ValueError, 'same local Unix Docker endpoint'):
            cleanup.engine_request('HEAD', '/containers/' + CID + '/archive?path=fixture')


if __name__ == '__main__':
    unittest.main()
