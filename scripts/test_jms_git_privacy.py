import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
import tarfile
import shutil
from unittest.mock import patch

from check_jms_git_privacy import findings, main, outgoing_findings, scan_archive


class PrivacyTests(unittest.TestCase):
    def test_linux_tar_package_contents_are_scanned(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            payload = b'https://private.example.invalid'
            member = tarfile.TarInfo('JMS/data/settings.txt')
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        results = scan_archive('portable.tar.gz', stream.getvalue(), ['private.example.invalid'])
        self.assertIn(('portable.tar.gz/JMS/data/settings.txt', ['private domain']), results)

    def setUp(self):
        argv = patch.object(sys, 'argv', ['checker'])
        argv.start()
        self.addCleanup(argv.stop)

    def test_credentials_and_binary_archive(self):
        for field in ('password', 'Cookie', 'Token', 'api_key'):
            key = 'access_token' if field == 'Token' else field
            data = (key + ' = "' + 'x' * 32 + '"').encode()
            self.assertTrue(findings('fixture.txt', data, []))
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, 'w') as archive:
            archive.writestr('lib.so', b'\x00https://service.private.example\x00')
        self.assertTrue(any(problems for _, problems in scan_archive('fixture.apk', payload.getvalue(), ['private.example'])))

    def test_real_hooks_reject_secret_blob_and_message_in_new_clone(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', 'init', '-q', '-b', 'jms', folder], check=True)
            (root / 'scripts').mkdir()
            shutil.copy2(source / 'scripts/check_jms_git_privacy.py', root / 'scripts')
            shutil.copy2(source / 'scripts/install_jms_git_hooks.py', root / 'scripts')
            shutil.copytree(source / '.githooks', root / '.githooks')
            (root / 'bin').mkdir()
            launcher = root / 'bin/python3'
            launcher.write_text('#!/bin/sh\nexec "' + sys.executable.replace('\\', '/') + '" "$@"\n')
            launcher.chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            installer = [sys.executable, 'scripts/install_jms_git_hooks.py']
            self.assertEqual(1, subprocess.run(installer, cwd=root, capture_output=True).returncode)
            (root / '.git/jms-private-domains').write_text('private.example\n')
            self.assertEqual(0, subprocess.run(installer + ['--check'], cwd=root, capture_output=True).returncode)
            def commit(message):
                return subprocess.run(['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@users.noreply.github.com', 'commit', '-qm', message], cwd=root, env=env, capture_output=True)
            (root / 'settings.txt').write_text('https://service.private.example')
            subprocess.run(['git', 'add', 'settings.txt'], cwd=root, check=True)
            result = commit('fix: fixture')
            self.assertNotEqual(0, result.returncode)
            self.assertIn(b'private domain', result.stderr)
            self.assertNotIn(b'service.private.example', result.stderr)
            (root / 'settings.txt').write_text('public fixture')
            subprocess.run(['git', 'add', 'settings.txt'], cwd=root, check=True)
            self.assertNotEqual(0, commit('fix: service.private.example').returncode)
            self.assertEqual(0, commit('fix: public fixture').returncode)

    def test_removed_secret_and_commit_message_are_checked(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as folder:
            try:
                os.chdir(folder)
                subprocess.run(['git', 'init', '-q', '-b', 'jms'], check=True)
                def commit(message):
                    subprocess.run(['git', 'add', 'settings.txt'], check=True)
                    subprocess.run(['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@users.noreply.github.com', 'commit', '-qm', message], check=True)
                Path('settings.txt').write_text('clean')
                commit('chore: baseline')
                base = subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()
                Path('settings.txt').write_text('https://service.private.example')
                commit('fix: https://service.private.example')
                Path('settings.txt').write_text('clean again')
                commit('fix: remove value')
                results = outgoing_findings('HEAD', [base], ['private.example'])
                self.assertTrue(any('/message' in name and problems for name, problems in results))
                self.assertTrue(any('/settings.txt' in name and problems for name, problems in results))
            finally:
                os.chdir(previous)

    def test_private_subdomain_and_personal_path_are_rejected(self):
        self.assertIn('private domain', findings('config.txt', b'https://service.private.example/api', ['private.example']))
        self.assertIn('personal filesystem path', findings('notes.md', str(Path.home() / 'fixture').encode(), []))

    def test_public_links_and_similar_domain_are_allowed(self):
        self.assertEqual([], findings('README.md', b'https://github.com/example/project https://notprivate.example', ['private.example']))
        self.assertEqual([], findings('sentinel.dart', b"const kBrowserManagedCookie = 'browser-managed-cookie';", []))

    def test_private_network_and_key_file_are_rejected(self):
        self.assertIn('private network endpoint', findings('config.txt', b'https://' + b'192.168.1.2:8096', []))
        self.assertIn('private file type', findings('signing.keystore', b'\x00', []))

    def test_scans_index_not_sanitized_worktree_and_does_not_print_value(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as folder:
            try:
                os.chdir(folder)
                subprocess.run(['git', 'init', '-q', '-b', 'jms'], check=True)
                Path('.git/jms-private-domains').write_text('private.example\n', encoding='utf-8')
                Path('settings.txt').write_text('https://service.private.example', encoding='utf-8')
                subprocess.run(['git', 'add', 'settings.txt'], check=True)
                Path('settings.txt').write_text('sanitized worktree', encoding='utf-8')
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    result = main()
                self.assertEqual(1, result)
                self.assertIn('settings.txt: private domain', output.getvalue())
                self.assertNotIn('service.private.example', output.getvalue())
                subprocess.run(['git', 'add', 'settings.txt'], check=True)
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, main())
                subprocess.run(['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                                'commit', '-qm', 'clean fixture'], check=True)
                Path('settings.txt').write_text('https://service.private.example', encoding='utf-8')
                subprocess.run(['git', 'add', 'settings.txt'], check=True)
                with patch.object(sys, 'argv', ['checker', '--tree', 'HEAD']), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, main())
                subprocess.run(['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                                'commit', '-qm', 'private fixture'], check=True)
                with patch.object(sys, 'argv', ['checker', '--tree', 'HEAD']), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(1, main())
            finally:
                os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
