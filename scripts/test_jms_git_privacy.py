import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from check_jms_git_privacy import findings, main


class PrivacyTests(unittest.TestCase):
    def test_private_subdomain_and_personal_path_are_rejected(self):
        self.assertIn('private domain', findings('config.txt', b'https://service.private.example/api', ['private.example']))
        self.assertIn('personal filesystem path', findings('notes.md', b'C:' + b'/Users/fixture/file', []))

    def test_public_links_and_similar_domain_are_allowed(self):
        self.assertEqual([], findings('README.md', b'https://github.com/example/project https://notprivate.example', ['private.example']))

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
            finally:
                os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
