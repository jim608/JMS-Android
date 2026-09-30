import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

from package_jms_sources import committed_archive


class CommittedArchiveTests(unittest.TestCase):
    def test_exact_commit_ignores_dirty_and_untracked_files_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE).decode().strip()
            git('init', '-q')
            git('config', 'user.name', 'fixture')
            git('config', 'user.email', 'fixture@users.noreply.github.com')
            git('config', 'core.autocrlf', 'false')
            (root / 'source.txt').write_bytes(b'committed source\n')
            git('add', 'source.txt')
            git('commit', '-qm', 'fixture source')
            commit = git('rev-parse', 'HEAD')
            git('config', 'core.autocrlf', 'true')
            (root / 'source.txt').write_bytes(b'dirty local source')
            (root / 'AGENTS.md').write_text('local instructions')
            archive = root / 'source.zip'
            record = {'sourceCommit': commit, 'inputs': [{'path': 'source.txt', 'sha256': hashlib.sha256(b'committed source\n').hexdigest()}]}
            committed_archive(commit, archive, root, record)
            with zipfile.ZipFile(archive) as bundle:
                self.assertEqual(b'committed source\n', bundle.read('JMS/source.txt'))
                self.assertNotIn('JMS/AGENTS.md', bundle.namelist())
                self.assertFalse(json.loads(bundle.read('JMS/source-manifest.json'))['dirty'])
            with self.assertRaisesRegex(ValueError, 'replacement'):
                committed_archive(commit, archive, root)
            record['inputs'][0]['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'Build input'):
                committed_archive(commit, root / 'invalid.zip', root, record)
            self.assertFalse((root / 'invalid.zip').exists())

    def test_submodule_uses_pinned_commit_and_rejects_missing_checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            def git(root, *args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE).decode().strip()
            for name in ('parent', 'dependency'):
                root = base / name
                root.mkdir()
                git(root, 'init', '-q')
                git(root, 'config', 'user.name', 'fixture')
                git(root, 'config', 'user.email', 'fixture@users.noreply.github.com')
                (root / 'LICENSE').write_text('synthetic license')
                git(root, 'add', 'LICENSE')
                git(root, 'commit', '-qm', 'fixture source')
            parent, dependency = base / 'parent', base / 'dependency'
            pin = git(dependency, 'rev-parse', 'HEAD')
            git(parent, '-c', 'protocol.file.allow=always', 'submodule', 'add', str(dependency), 'dependency')
            git(parent, 'commit', '-qam', 'pin fixture dependency')
            commit = git(parent, 'rev-parse', 'HEAD')
            archive = base / 'complete.zip'
            committed_archive(commit, archive, parent)
            with zipfile.ZipFile(archive) as bundle:
                self.assertEqual(b'synthetic license', bundle.read('JMS/dependency/LICENSE'))
                self.assertEqual(pin, json.loads(bundle.read('JMS/dependency/JMS_SUBMODULE_SOURCE.json'))['commit'])
            (parent / 'dependency').rename(parent / 'missing-dependency')
            (parent / 'dependency').mkdir()
            with self.assertRaisesRegex(ValueError, 'checkout is missing'):
                committed_archive(commit, base / 'incomplete.zip', parent)


if __name__ == '__main__':
    unittest.main()
