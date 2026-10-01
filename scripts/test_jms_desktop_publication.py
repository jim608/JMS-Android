import unittest
import json
import tempfile
from pathlib import Path
from unittest.mock import patch
from jms_publication import Github, ReleaseError, allowed_url
from jms_desktop_publication import resume_publication_state


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
