"""Synthetic evidence must never become an archive-wide privacy exemption."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import check_jms_git_privacy as privacy


def digest(data):
    return hashlib.sha256(data).hexdigest()


def container(members):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return stream.getvalue()


def review(archive, member, data, evidence_member=None, evidence_data=None):
    return {'archiveSha256': digest(archive), 'member': member, 'sha256': digest(data),
            'source': 'https://upstream.example.invalid/releases/fixture-1.zip',
            'explanation': 'Synthetic unit-test fixture with a pinned source reference.',
            'rules': ['private file type'],
            'evidence': {'kind': 'upstream-test-reference',
                         'member': evidence_member or member,
                         'sha256': digest(evidence_data if evidence_data is not None else data)}}


class PublicEvidenceTests(unittest.TestCase):
    def scan(self, data, reviews, domains=(), **limits):
        scanner = privacy.ArchiveScan(domains, reviews, **limits)
        results = scanner.scan('release.zip', data)
        scanner.finish()
        return scanner, [(name, rules) for name, rules in results if rules]

    def test_exact_member_is_accepted_without_exempting_other_members(self):
        payload = b'synthetic public fixture'
        archive = container({'fixture.key': payload, 'other.key': payload})
        _, rejected = self.scan(archive, [review(archive, 'fixture.key', payload)])
        self.assertEqual([('release.zip/other.key', ['private file type'])], rejected)

    def test_one_bit_change_and_forged_path_or_container_invalidate_review(self):
        payload = b'synthetic public fixture'
        archive = container({'fixture.key': payload})
        approval = review(archive, 'fixture.key', payload)
        for changed in (container({'fixture.key': payload[:-1] + b'd'}),
                        container({'forged/fixture.key': payload}),
                        container({'fixture.key': payload, 'extra.txt': b'x'})):
            with self.subTest(sha=digest(changed)):
                self.assertTrue(self.scan(changed, [approval])[1])

    def test_local_policy_and_unapproved_credential_rule_always_block(self):
        payload = b'https://private.example.invalid'
        archive = container({'fixture.key': payload})
        approval = review(archive, 'fixture.key', payload)
        approval['rules'].append('private domain')
        self.assertTrue(self.scan(archive, [approval], ['private.example.invalid'])[1])
        payload = ('password="' + 'x' * 32 + '"').encode()
        archive = container({'fixture.key': payload})
        self.assertTrue(self.scan(archive, [review(archive, 'fixture.key', payload)])[1])

    def test_evidence_member_must_be_present_and_identical(self):
        payload = b'synthetic public fixture'
        archive = container({'fixture.key': payload, 'test.txt': b'changed'})
        approval = review(archive, 'fixture.key', payload, 'test.txt', b'original')
        with self.assertRaisesRegex(ValueError, 'reference'):
            self.scan(archive, [approval])

    def test_distribution_requires_exact_origin_and_reference_assets(self):
        payload = b'synthetic key fixture'
        reference = b'test consumes fixture.key'
        upstream = container({'fixture.key': payload, 'test.txt': reference})
        release = container({'app/fixture.key': payload})
        approval = review(upstream, 'fixture.key', payload, 'test.txt', reference)
        approval['distributions'] = [{'archiveSha256': digest(release), 'member': 'app/fixture.key'}]
        with tempfile.TemporaryDirectory() as directory, patch.object(privacy, 'load_public_reviews', return_value=[approval]):
            root = Path(directory)
            (root / 'upstream.zip').write_bytes(upstream)
            (root / 'release.zip').write_bytes(release)
            paths = [root / 'upstream.zip', root / 'release.zip']
            self.assertTrue(privacy.scan_packages_cached(paths, [], root / 'cache')['accepted'])
            with self.assertRaisesRegex(ValueError, 'origin'):
                privacy.scan_packages_cached(paths[1:], [], root / 'cache')
            (root / 'release.zip').write_bytes(container({'app/fixture.key': payload + b'x'}))
            self.assertFalse(privacy.scan_packages_cached(paths, [], root / 'cache')['accepted'])

    def test_all_additional_references_must_be_verified(self):
        payload = b'synthetic public fixture'
        archive = container({'fixture.key': payload, 'first.txt': b'reference'})
        approval = review(archive, 'fixture.key', payload, 'first.txt', b'reference')
        approval['additionalEvidence'] = [{'member': 'missing.txt', 'sha256': digest(b'missing')}]
        with self.assertRaisesRegex(ValueError, 'reference'):
            self.scan(archive, [approval])

    def test_raw_sample_requires_independent_reference_and_explicit_scope(self):
        payload = b'intentionally invalid tar fixture'
        reference = b'test expects archive parsing to raise an error for broken.tar'
        archive = container({'broken.tar': payload, 'test.txt': reference})
        approval = review(archive, 'broken.tar', payload, 'test.txt', reference)
        approval.update(inspection='raw-public-test-sample', testReference='test_broken_tar',
                        rawContentReview={'scope': 'raw-bytes-only', 'method': 'All synthetic bytes inspected',
                                          'conclusion': 'No private values; deliberate malformed test bytes'})
        scanner, rejected = self.scan(archive, [approval])
        self.assertFalse(rejected)
        self.assertEqual('raw bytes only; nested content not expanded', scanner.raw_samples[0]['scope'])
        with self.assertRaises(tarfile.ReadError):
            self.scan(archive, [])
        approval['rawContentReview'] = True
        with self.assertRaises(tarfile.ReadError):
            self.scan(archive, [approval])

    def test_aggregate_member_depth_and_time_limits_remain_blocking(self):
        archive = container({'a.txt': b'x' * 1000, 'b.txt': b'x' * 1000})
        for limits in ({'max_bytes': len(archive) + 1200}, {'max_members': 2},
                       {'max_seconds': -1}, {'max_depth': 0}):
            with self.subTest(limits=limits), self.assertRaises(ValueError):
                self.scan(archive, [], **limits)
        with self.assertRaises(ValueError):
            self.scan(container({'dir/': b'', 'dir2/': b''}), [], max_members=2)

    def test_tar_header_and_padding_reads_are_bounded(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for i in range(30):
                member = tarfile.TarInfo('dir' + str(i))
                member.type = tarfile.DIRTYPE
                archive.addfile(member)
        scanner = privacy.ArchiveScan([], [], max_bytes=2000)
        with self.assertRaisesRegex(ValueError, 'decompression'):
            scanner.scan('fixture.tar.gz', stream.getvalue())

    def test_link_targets_and_directory_names_are_inspected(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            link = tarfile.TarInfo('link')
            link.type = tarfile.SYMTYPE
            link.linkname = 'https://private.example.invalid/target'
            archive.addfile(link)
        scanner = privacy.ArchiveScan(['private.example.invalid'], [])
        self.assertTrue(any(rules for _, rules in scanner.scan('fixture.tar.gz', stream.getvalue())))
        _, rejected = self.scan(container({'private.example.invalid/': b''}), [], ['private.example.invalid'])
        self.assertTrue(rejected)

    def test_cache_is_bound_to_policy_evidence_scanner_settings_and_material(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'fixture.zip'
            package.write_bytes(container({'a.txt': b'public'}))
            cache = root / 'cache'
            with patch.object(privacy, 'load_public_reviews', return_value=[]):
                first = privacy.scan_package_cached(package, [], cache)
                with patch.object(privacy.ArchiveScan, 'scan', side_effect=AssertionError('cache missed')):
                    self.assertEqual(first, privacy.scan_package_cached(package, [], cache))
                changed = privacy.scan_package_cached(package, ['private.example.invalid'], cache)
                self.assertNotEqual(first['inputs'], changed['inputs'])
            with patch.object(privacy, 'load_public_reviews', return_value=[{'unapproved': True}]):
                changed = privacy.scan_package_cached(package, [], cache)
                self.assertNotEqual(first['inputs']['reviews'], changed['inputs']['reviews'])
            with patch.object(privacy, 'MAX_ARCHIVE_MEMBER_BYTES', privacy.MAX_ARCHIVE_MEMBER_BYTES - 1):
                changed = privacy.scan_package_cached(package, [], cache)
                self.assertNotEqual(first['inputs']['settings'], changed['inputs']['settings'])
            saved_count = len(list(cache.glob('*.json')))
            package.write_bytes(container({'private.key': b'unknown key'}))
            self.assertFalse(privacy.scan_package_cached(package, [], cache)['accepted'])
            self.assertEqual(saved_count, len(list(cache.glob('*.json'))))
            package.write_bytes(b'not a valid archive')
            with self.assertRaises(zipfile.BadZipFile):
                privacy.scan_package_cached(package, [], cache)
            self.assertEqual(saved_count, len(list(cache.glob('*.json'))))


if __name__ == '__main__':
    unittest.main()
