import os
from pathlib import Path
import subprocess
import tempfile
import hashlib
import unittest
from unittest.mock import patch

from jms_git_release import committed_source, push_release, verify_build_record, GitReleaseError


class GitReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.previous = Path.cwd()
        self.addCleanup(os.chdir, self.previous)
        self.root = Path(self.temp.name)
        self.remote = str(self.root / 'remote.git')
        self.run_git('init', '--bare', '-q', self.remote)
        self.work = self.root / 'work'
        self.work.mkdir()
        os.chdir(self.work)
        self.run_git('init', '-q', '-b', 'main')
        self.run_git('config', 'user.name', 'fixture')
        self.run_git('config', 'user.email', 'fixture@users.noreply.github.com')
        self.run_git('config', 'core.autocrlf', 'false')
        Path('.git/jms-private-domains').write_text('private.example\n')
        self.base = self.commit('chore: baseline', 'base')
        self.run_git('push', '-q', self.remote, 'main')
        self.run_git('checkout', '-qb', 'jms')
        self.first = self.commit('fix: first change', 'first')
        self.second = self.commit('test: second change', 'second')

    def run_git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.PIPE).decode().strip()

    def commit(self, message, content):
        Path('source.txt').write_text(content)
        self.run_git('add', 'source.txt')
        self.run_git('commit', '-qm', message)
        return self.run_git('rev-parse', 'HEAD')

    def test_order_main_tag_and_idempotent_resume(self):
        push_release(self.remote, self.second, 'vfixture', dry_run=True)
        self.assertNotIn('refs/heads/jms', self.run_git('ls-remote', self.remote))
        push_release(self.remote, self.second, 'vfixture')
        # Simulate interruption after atomic push, before local state was saved.
        push_release(self.remote, self.second, 'vfixture')
        self.assertEqual(self.base, self.run_git('--git-dir=' + self.remote, 'rev-parse', 'main'))
        self.assertEqual(self.second, self.run_git('--git-dir=' + self.remote, 'rev-parse', 'refs/tags/vfixture'))
        self.assertEqual([self.first, self.second], self.run_git('--git-dir=' + self.remote, 'rev-list', '--reverse', self.base + '..jms').splitlines())

    def test_build_inputs_bind_to_real_commit_bytes(self):
        from verify_jms_snapshot import verify_snapshot
        import jms_publication
        inputs = [{'path': 'source.txt', 'sha256': hashlib.sha256(b'second').hexdigest()}]
        with patch.object(jms_publication, 'ROOT', self.work):
            verify_snapshot(self.second, inputs)
            with self.assertRaises(jms_publication.ReleaseError):
                verify_snapshot(self.first, inputs)

    def test_gitlink_is_a_pointer_and_does_not_hide_blob_findings(self):
        from check_jms_git_privacy import blob_findings, tree_entries
        self.run_git('update-index', '--add', '--cacheinfo', '160000,' + self.base + ',external-source')
        self.run_git('commit', '-qm', 'chore: pin external source')
        entries = tree_entries('HEAD')
        self.assertEqual('commit', entries['external-source'][0])
        self.assertEqual([('source.txt', [])], blob_findings(entries, ['private.example']))

    def test_non_fast_forward_and_existing_tag_refused(self):
        push_release(self.remote, self.second, 'vfixture')
        self.run_git('checkout', '--detach', self.base)
        other = self.commit('fix: divergent change', 'other')
        self.run_git('push', '-q', self.remote, other + ':refs/heads/fixture-divergence')
        self.run_git('checkout', 'jms')
        self.run_git('--git-dir=' + self.remote, 'update-ref', 'refs/heads/jms', other)
        with self.assertRaises(GitReleaseError):
            push_release(self.remote, self.second, 'vnext')
        self.assertEqual(other, self.run_git('--git-dir=' + self.remote, 'rev-parse', 'jms'))
        self.run_git('--git-dir=' + self.remote, 'update-ref', 'refs/heads/jms', self.second)
        self.run_git('--git-dir=' + self.remote, 'update-ref', 'refs/tags/vnext', self.base)
        with self.assertRaises(GitReleaseError):
            push_release(self.remote, self.second, 'vnext')

    def test_interruption_before_push_can_resume(self):
        real_run = subprocess.run
        def interrupted(command, **kwargs):
            if 'push' in command:
                raise OSError('fixture interruption')
            return real_run(command, **kwargs)
        with patch('jms_git_release.subprocess.run', side_effect=interrupted), self.assertRaises(OSError):
            push_release(self.remote, self.second, 'vfixture')
        push_release(self.remote, self.second, 'vfixture')
        self.assertEqual(self.second, self.run_git('--git-dir=' + self.remote, 'rev-parse', 'jms'))

    def test_dirty_wrong_branch_and_old_build_refused(self):
        Path('source.txt').write_text('dirty')
        with self.assertRaises(GitReleaseError):
            committed_source()
        self.run_git('restore', 'source.txt')
        self.run_git('checkout', 'main')
        with self.assertRaises(GitReleaseError):
            committed_source()
        with self.assertRaises(GitReleaseError):
            verify_build_record({'sourceCommit': self.second, 'workspaceCommit': self.second}, self.second)

    def test_removed_secret_blocks_push(self):
        self.commit('fix: intermediate', 'https://service.private.example')
        head = self.commit('fix: clean final', 'clean')
        with self.assertRaises(GitReleaseError):
            push_release(self.remote, head, 'vfixture')
        self.assertNotIn('refs/heads/jms', self.run_git('ls-remote', self.remote))


if __name__ == '__main__':
    unittest.main()
