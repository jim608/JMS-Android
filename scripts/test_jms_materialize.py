import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from materialize_jms_source import materialize


class MaterializeTests(unittest.TestCase):
    def test_only_clean_line_endings_can_change(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as temporary:
            try:
                os.chdir(temporary)
                def git(*args):
                    subprocess.run(['git', *args], check=True, capture_output=True)
                git('init', '-q')
                git('config', 'user.name', 'fixture')
                git('config', 'user.email', 'fixture@users.noreply.github.com')
                git('config', 'core.autocrlf', 'true')
                source = Path('fixture.txt')
                source.write_bytes(b'one\r\ntwo\r\n')
                git('add', 'fixture.txt')
                git('commit', '-qm', 'fixture')
                materialize()
                self.assertIn(b'\r\n', source.read_bytes())
                materialize(apply=True)
                self.assertEqual(b'one\ntwo\n', source.read_bytes())
                source.write_bytes(b'changed\n')
                with self.assertRaisesRegex(ValueError, 'Commit reviewed'):
                    materialize(apply=True)
                self.assertEqual(b'changed\n', source.read_bytes())
            finally:
                os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
