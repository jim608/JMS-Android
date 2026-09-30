import unittest
from unittest.mock import patch
from jms_publication import Github, ReleaseError, allowed_url


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


if __name__ == '__main__':
    unittest.main()
