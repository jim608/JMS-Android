"""The public review registry cannot hide unverified or private metadata."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import check_jms_git_privacy as privacy


def digest(data):
    return hashlib.sha256(data).hexdigest()


class RegistryMemberTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        # Assemble a named synthetic relative fixture tree; no real user path.
        self.fixture_directory = Path('synthetic-1') / 'tests' / 'home' / 'applications'
        self.member = (self.fixture_directory / 'example.desktop').as_posix()
        self.payload = b'[Desktop Entry]\nName=Synthetic parser input\n'
        self.reference = 'synthetic-1/tests/parser.c'
        self.reference_data = b'parse_fixture_name_from_test();\n'
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr(self.member, self.payload)
            archive.writestr(self.reference, self.reference_data)
        self.archive = stream.getvalue()
        self.material = self.project / 'artifacts/checks/windows-release-closeout/native-ready/fixture-1.zip'
        self.material.parent.mkdir(parents=True)
        self.material.write_bytes(self.archive)
        (self.project / 'config').mkdir()
        (self.project / 'config/jms_windows_native.json').write_text(json.dumps({
            'sources': {'fixture-1.zip': {'sha256': digest(self.archive), 'size': len(self.archive)}}
        }), encoding='utf-8')
        self.review = {
            'source': 'https://repo.msys2.org/mingw/sources/fixture-1.zip',
            'archiveSha256': digest(self.archive), 'member': self.member,
            'sha256': digest(self.payload), 'rules': ['personal filesystem path'],
            'explanation': 'Synthetic relative archive path consumed by the pinned parser.',
            'evidence': {'kind': 'upstream-test-reference', 'member': self.reference,
                         'sha256': digest(self.reference_data)}
        }

    def check(self, review=None, name='config/jms_public_privacy_reviews.json', domains=()):
        return privacy.git_blob_findings(name, json.dumps([review or self.review]).encode(), domains, self.project)

    def test_only_verified_registry_member_path_is_accepted(self):
        self.assertEqual([], self.check())
        self.assertIn('personal filesystem path', self.check(name='other.json'))

    def test_missing_material_fails_closed_without_downloading(self):
        self.material.unlink()
        self.assertIn('personal filesystem path', self.check())

    def test_changed_material_member_or_evidence_identity_fails_closed(self):
        for field in ('sha256', 'archiveSha256'):
            with self.subTest(field=field):
                changed = dict(self.review, **{field: '0' * 64})
                self.assertIn('personal filesystem path', self.check(changed))
        changed = dict(self.review, evidence=dict(self.review['evidence'], sha256='0' * 64))
        self.assertIn('personal filesystem path', self.check(changed))
        self.material.write_bytes(self.archive[:-1] + bytes([self.archive[-1] ^ 1]))
        self.assertIn('personal filesystem path', self.check())

    def test_fake_path_or_origin_cannot_reuse_approval(self):
        changed = dict(self.review, member=(self.fixture_directory / 'other.desktop').as_posix())
        self.assertIn('personal filesystem path', self.check(changed))
        changed = dict(self.review, source='https://unknown.example.invalid/fixture-1.zip')
        self.assertIn('personal filesystem path', self.check(changed))

    def test_private_domain_credentials_and_unknown_fields_remain_blocked(self):
        changed = dict(self.review, localNote='https://service.private.example')
        self.assertIn('private domain', self.check(changed, domains=['private.example']))
        changed = dict(self.review, localNote='password="' + 'x' * 32 + '"')
        self.assertIn('credential assignment', self.check(changed))
        self.assertIn('personal filesystem path', self.check(changed))
        changed = dict(self.review, explanation='https://service.private.example')
        self.assertIn('private domain', self.check(changed, domains=['private.example']))

    def test_public_registry_review_does_not_approve_release_container(self):
        scanner = privacy.ArchiveScan((), [self.review])
        rejected = [rules for _, rules in scanner.scan('fixture-1.zip', self.archive) if rules]
        # The original package scanner also examines ZIP header metadata;
        # registry handling does not grant the container any exemption.
        self.assertTrue(rejected)
        changed = io.BytesIO()
        with zipfile.ZipFile(changed, 'w') as archive:
            archive.writestr(self.member, self.payload)
            archive.writestr(self.reference, self.reference_data)
            archive.writestr('secret.txt', b'password="' + b'x' * 32 + b'"')
        scanner = privacy.ArchiveScan((), [self.review])
        self.assertTrue(any(rules for _, rules in scanner.scan('fixture-1.zip', changed.getvalue())))


if __name__ == '__main__':
    unittest.main()
