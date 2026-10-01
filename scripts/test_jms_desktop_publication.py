import unittest
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from jms_publication import Github, ReleaseError, allowed_url
import jms_desktop_publication as desktop
from jms_desktop_publication import release_tag, resume_publication_state


class DesktopPublicationTests(unittest.TestCase):
    def test_repository_scope_is_exact(self):
        for repository in ('jim608/JMS-Desktop', 'jim608/JMS-Linux', 'jim608/JMS-Web'):
            github = Github(repository=repository)
            with patch.object(github, 'call', return_value=b'{}') as call:
                github.api('repos/' + repository + '/releases')
                call.assert_called_once()
                with self.assertRaises(ReleaseError):
                    github.api('repos/jim608/JMS-Android/releases')
            self.assertTrue(allowed_url(
                'https://github.com/' + repository + '/releases/download/v20/asset.zip',
                repository=repository))
            self.assertFalse(allowed_url(
                'https://github.com/jim608/JMS-Android/releases/download/v20/asset.zip',
                repository=repository))

    def test_other_repository_is_rejected(self):
        with self.assertRaises(ReleaseError):
            Github(repository='DonutWare/Fladder')

    def test_release_tag_defaults_or_matches_exact_full_application_version(self):
        record = {'versionName': '0.11.1-jms.25', 'versionCode': 27}
        self.assertEqual(release_tag(record), 'v0.11.1-jms.25')
        self.assertEqual(release_tag(dict(record, releaseTag='v0.11.1-jms.25')), 'v0.11.1-jms.25')
        self.assertEqual(release_tag(dict(record, releaseTag='v0.11.1-jms.25+27')), 'v0.11.1-jms.25+27')
        for tag in ('v0.11.1-jms.25+28', 'v0.11.1-jms.26+27', 'v0.11.1-jms.25-publication.1',
                    'v0.11.1-jms.25+027', 'v0.11.1-jms.25+27/other', '', None, 27):
            with self.subTest(tag=tag), self.assertRaises(ReleaseError):
                release_tag(dict(record, releaseTag=tag))

    def test_release_tag_rejects_invalid_version_identity(self):
        for code in (True, '27', 27.0, -1, None):
            with self.subTest(code=code), self.assertRaises(ReleaseError):
                release_tag({'versionName': '0.11.1-jms.25', 'versionCode': code})
        for version in ('', None, 25):
            with self.subTest(version=version), self.assertRaises(ReleaseError):
                release_tag({'versionName': version, 'versionCode': 27})

    def test_full_version_tag_drives_existing_tag_and_publication_state(self):
        record = {'repository': 'jim608/JMS-Desktop', 'sourceCommit': 'a' * 40,
                  'versionName': '0.11.1-jms.25', 'versionCode': 27,
                  'releaseTag': 'v0.11.1-jms.25+27'}
        release_commit = 'b' * 40
        calls = []
        def git(*arguments, **kwargs):
            calls.append(arguments)
            if arguments[:2] == ('ls-remote', 'https://github.com/jim608/JMS-Android.git'):
                return record['sourceCommit'] + '\trefs/heads/jms'
            if arguments == ('rev-parse', 'HEAD'):
                return release_commit
            if arguments == ('remote', 'get-url', 'origin'):
                return 'https://github.com/jim608/JMS-Desktop.git'
            if arguments[:2] == ('ls-remote', 'origin'):
                return release_commit + '\trefs/tags/' + record['releaseTag']
            return ''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / 'artifacts/release-repositories/JMS-Desktop'
            (checkout / 'releases').mkdir(parents=True)
            (checkout / 'releases/0.11.1-jms.25.json').write_text(json.dumps(record), encoding='utf-8')
            (root / 'RELEASE_NOTES.md').write_text('synthetic release notes', encoding='utf-8')
            args = SimpleNamespace(artifact_directory=str(root), platform='windows', dry_run=False,
                                   channel='prerelease')
            with patch.object(desktop, 'ROOT', root), patch.object(desktop, 'git', side_effect=git), \
                    patch.object(desktop, 'validate_inventory', return_value=(record, {})) as validate, \
                    patch.object(desktop, 'Github') as github_type, \
                    patch.object(desktop.subprocess, 'run') as push, \
                    patch.object(desktop, 'upload_complete_release') as upload, \
                    patch('builtins.print'):
                github = github_type.return_value
                github.releases.return_value = [{'id': 7, 'tag_name': record['releaseTag']}]
                github.api.return_value = {'assets': [], 'html_url': 'synthetic release'}
                desktop.publish_desktop(args)
                validate.assert_called_once_with(root, 'windows')
                push.assert_not_called()
                planned = upload.call_args.args[1]
                self.assertEqual(planned['tag'], record['releaseTag'])
                self.assertEqual(planned['releaseCommit'], release_commit)
                self.assertEqual(planned['sourceCommit'], record['sourceCommit'])
                self.assertEqual(planned['version'], record['versionName'])
                def different_existing_tag(*arguments, **kwargs):
                    if arguments[:2] == ('ls-remote', 'origin'):
                        return 'c' * 40 + '\trefs/tags/' + record['releaseTag']
                    return git(*arguments, **kwargs)
                with patch.object(desktop, 'git', side_effect=different_existing_tag):
                    with self.assertRaisesRegex(ReleaseError, 'tag exists at another commit'):
                        desktop.publish_desktop(args)
                push.assert_not_called()
                self.assertEqual(upload.call_count, 1)
            self.assertIn(('ls-remote', 'origin', 'refs/tags/' + record['releaseTag']), calls)
            self.assertNotIn(('ls-remote', 'origin', 'refs/tags/v0.11.1-jms.25'), calls)
            saved = json.loads((root / 'publication-state.json').read_text(encoding='utf-8'))
            self.assertEqual(saved['tag'], record['releaseTag'])

    def test_interrupted_release_preserves_receipts_without_accepting_identity_drift(self):
        planned = {'releaseId': 7, 'tag': 'vfixture', 'version': 'fixture',
                   'notes': 'fixture notes', 'prerelease': True,
                   'sourceCommit': 'a' * 40, 'releaseCommit': 'b' * 40}
        saved = dict(planned, verifiedAssets={'test.zip': 'c' * 64}, published=True)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'publication-state.json'
            self.assertEqual(resume_publication_state(path, planned), planned)
            path.write_text(json.dumps(saved), encoding='utf-8')
            resumed = resume_publication_state(path, planned)
            self.assertEqual(resumed['verifiedAssets'], saved['verifiedAssets'])
            self.assertTrue(resumed['published'])
            for field in planned:
                changed = dict(planned, **{field: 'different'})
                with self.subTest(field=field), self.assertRaises(ReleaseError):
                    resume_publication_state(path, changed)


if __name__ == '__main__':
    unittest.main()
