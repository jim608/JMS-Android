import hashlib
from pathlib import Path
import tarfile
import unittest

from check_jms_git_privacy import load_public_reviews, reviewed_archive_findings


ROOT = Path(__file__).resolve().parents[1]
FFMPEG = ROOT / 'artifacts/checks/flatpak-preparation/dependency-sources/ffmpeg-7.1.5.tar.xz'
ORIGIN = 'de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f'


@unittest.skipUnless(FFMPEG.is_file(), 'Pinned official FFmpeg source material is not available locally')
class FlatpakOfficialSourcePrivacyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if hashlib.sha256(FFMPEG.read_bytes()).hexdigest() != ORIGIN:
            raise AssertionError('Official FFmpeg archive differs from fixed source identity')
        cls.reviews = [review for review in load_public_reviews() if review.get('archiveSha256') == ORIGIN]
        if len(cls.reviews) != 6:
            raise AssertionError('Exact six official source member reviews required')
        with tarfile.open(FFMPEG, 'r:xz') as archive:
            cls.contents = {review['member']: archive.extractfile(review['member']).read()
                            for review in cls.reviews}

    def test_exact_public_source_members_require_matching_origin_and_content(self):
        for review in self.reviews:
            member = review['member']
            content = self.contents[member]
            self.assertEqual(hashlib.sha256(content).hexdigest(), review['sha256'])
            contexts = ((ORIGIN, member),)
            with self.subTest(member=member):
                self.assertEqual(reviewed_archive_findings(member, content, [], contexts), [])
                self.assertTrue(reviewed_archive_findings(member, content + b'changed', [], contexts))
                self.assertTrue(reviewed_archive_findings(member, content, [], (('0' * 64, member),)))

    def test_public_url_fixtures_never_override_private_domain_policy(self):
        member = 'ffmpeg-7.1.5/libavformat/tests/url.c'
        reasons = reviewed_archive_findings(member, self.contents[member], ['ffmpeg'], ((ORIGIN, member),))
        self.assertIn('private domain', reasons)


if __name__ == '__main__':
    unittest.main()
