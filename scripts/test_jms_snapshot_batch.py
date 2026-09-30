import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_jms_snapshot as snapshot
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
