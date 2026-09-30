"""Exercise release-tag privacy boundaries against a local bare remote."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PushHookTests(unittest.TestCase):
    def test_published_history_new_secrets_and_unrelated_tags(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary, 'work')
            repo.mkdir()
            remote = Path(temporary, 'remote.git')

            def git(*args, check=True):
                return subprocess.run(['git', '-C', str(repo), *args],
                                      capture_output=True, check=check)

            git('init', '-q')
            git('init', '--bare', '-q', str(remote))
            git('config', 'user.name', 'fixture')
            git('config', 'user.email', 'fixture@users.noreply.github.com')
            git('config', 'core.autocrlf', 'false')
            file = repo / 'fixture.txt'

            def commit(content):
                file.write_text(content, encoding='utf-8')
                git('add', 'fixture.txt')
                git('commit', '-qm', 'test: synthetic fixture')
                return git('rev-parse', 'HEAD').stdout.decode().strip()

            base = commit('baseline')
            git('push', str(remote), base + ':refs/heads/main')
            commit('old.private.invalid')
            published = commit('clean candidate')
            git('push', str(remote), published + ':refs/heads/jms')
            (repo / '.git/jms-private-domains').write_text(
                'old.private.invalid\nnew.private.invalid\n', encoding='utf-8')
            (repo / 'scripts').mkdir()
            shutil.copyfile(root / 'scripts/check_jms_git_privacy.py',
                            repo / 'scripts/check_jms_git_privacy.py')
            hook = (root / '.githooks/pre-push').read_text(encoding='utf-8')
            hook = hook.replace('jms_python=python3',
                                "jms_python='" + Path(sys.executable).as_posix() + "'")
            target = repo / '.git/hooks/pre-push'
            target.write_text(hook, encoding='utf-8', newline='\n')
            target.chmod(0o755)
            newer = commit('publication tooling')
            result = git('push', '--atomic', str(remote),
                         newer + ':refs/heads/jms',
                         published + ':refs/tags/release', check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            secret = commit('new.private.invalid')
            result = git('push', str(remote), secret + ':refs/tags/secret', check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'private domain', result.stdout + result.stderr)
            clean = commit('secret removed later')
            result = git('push', str(remote), clean + ':refs/tags/removed', check=False)
            self.assertNotEqual(result.returncode, 0)
            git('checkout', '--orphan', 'unrelated')
            unrelated = commit('unrelated clean tree')
            result = git('push', str(remote), unrelated + ':refs/tags/unrelated', check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(git('ls-remote', str(remote), 'refs/tags/*').stdout.count(b'\n'), 1)

