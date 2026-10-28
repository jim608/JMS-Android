"""Exact public CA link reviews never approve regular PEMs or private keys."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from check_jms_git_privacy import ArchiveScan, matching_reviews, scan_packages_cached, valid_evidence


# Public Amazon Root CA 3 from the reviewed official NGINX package layer.
# This fixture does not load or alter the operating system certificate store.
CA = b'''-----BEGIN CERTIFICATE-----
MIIBtjCCAVugAwIBAgITBmyf1XSXNmY/Owua2eiedgPySjAKBggqhkjOPQQDAjA5
MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6b24g
Um9vdCBDQSAzMB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTELMAkG
A1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJvb3Qg
Q0EgMzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABCmXp8ZBf8ANm+gBG1bG8lKl
ui2yEujSLtf6ycXYqm0fc4E7O5hrOXwzpcVOho6AF2hiRVd9RFgdszflZwjrZt6j
QjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBSr
ttvXBp43rDCGB5Fwx5zEGbF4wDAKBggqhkjOPQQDAgNJADBGAiEA4IWSoxe3jfkr
BqWTrBqYaGFy+uGh0PsceGCmQ5nFuMQCIQCcAu/xlJyzlvnrxir4tiz+OpAUFteM
YyRIHN8wfdVoOw==
-----END CERTIFICATE-----
'''
LINK = 'etc/ssl/certs/fixture.pem'
CERT = 'usr/share/ca-certificates/fixture.crt'
TARGET = '/' + CERT


def sha(data):
    return hashlib.sha256(data).hexdigest()


def archive(*, certificate=CA, link_type=tarfile.SYMTYPE, target=TARGET,
            extra=(), extra_links=(), include_certificate=True, link_content=None):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as output:
        member = tarfile.TarInfo(LINK)
        member.type = link_type
        if link_type == tarfile.REGTYPE:
            payload = target.encode() if link_content is None else link_content
            member.size = len(payload)
            output.addfile(member, io.BytesIO(payload))
        else:
            member.linkname = target
            output.addfile(member)
        for name, link in extra_links:
            member = tarfile.TarInfo(name)
            member.type = tarfile.SYMTYPE
            member.linkname = link
            output.addfile(member)
        for name, payload in ([(CERT, certificate)] if include_certificate else []) + list(extra):
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            output.addfile(member, io.BytesIO(payload))
    return stream.getvalue()


def review(data, *, certificate=CA, target=TARGET):
    origin = sha(data)
    source = 'https://registry-1.docker.io/v2/library/nginx/blobs/sha256:' + origin
    return {'inspection': 'public-ca-symlink', 'rules': ['private file type'],
            'source': source, 'archiveSha256': origin, 'member': LINK,
            'sha256': sha(target.encode()), 'linkTarget': target,
            'evidence': {'kind': 'upstream-public-x509-certificate',
                         'archiveSha256': origin, 'member': CERT, 'sha256': sha(certificate)},
            'certificate': {'member': CERT, 'sha256': sha(certificate),
                            'source': source, 'distributions': []},
            'explanation': 'Exact unit-test link and separately pinned public CA certificate.'}


class PublicCaSymlinkTests(unittest.TestCase):
    def scan_materials(self, materials, reviews):
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for index, data in enumerate(materials):
                path = Path(folder) / f'material-{index}.tar'
                path.write_bytes(data)
                paths.append(path)
            with patch('check_jms_git_privacy.load_public_reviews', return_value=reviews):
                return scan_packages_cached(paths, ['private.example.invalid'], cache_directory=None)

    def scan(self, data, reviews, *, name='candidate.tar', finish=True):
        scanner = ArchiveScan(['private.example.invalid'], reviews=reviews)
        results = scanner.scan(name, data)
        if finish:
            scanner.finish()
        return scanner, [(path, reasons) for path, reasons in results if reasons]

    def test_exact_symlink_and_pinned_regular_ca_are_accepted(self):
        data = archive()
        scanner, rejected = self.scan(data, [review(data)])
        self.assertEqual([], rejected)
        self.assertEqual(1, len(scanner.ca_links))
        self.assertEqual(1, len(scanner.ca_parsed_digests))

    def test_unapproved_link_regular_pem_and_hardlink_stay_blocked(self):
        for kind in (tarfile.SYMTYPE, tarfile.REGTYPE, tarfile.LNKTYPE):
            with self.subTest(kind=kind):
                data = archive(link_type=kind)
                approvals = [] if kind == tarfile.SYMTYPE else [review(data)]
                scanner, rejected = self.scan(data, approvals)
                self.assertTrue(any(path.endswith(LINK) and 'private file type' in reasons
                                    for path, reasons in rejected))
                self.assertEqual([], scanner.ca_links)

    def test_typed_row_cannot_be_used_as_a_regular_file_review(self):
        data = archive()
        row = review(data)
        self.assertEqual([], matching_reviews(TARGET.encode(), [(sha(data), LINK)], [row]))

    def test_reviewed_link_chain_resolves_to_the_same_pinned_certificate(self):
        intermediate = 'etc/ssl/intermediate.pem'
        data = archive(target='/' + intermediate, extra_links=[(intermediate, TARGET)])
        first = review(data, target='/' + intermediate)
        second = review(data)
        second['member'] = intermediate
        scanner, rejected = self.scan(data, [first, second])
        self.assertEqual([], rejected)
        self.assertEqual(2, len(scanner.ca_links))

    def test_missing_intermediate_symlink_cannot_be_supplied_by_registry_alone(self):
        intermediate = 'etc/ssl/intermediate.pem'
        data = archive(target='/' + intermediate)
        first = review(data, target='/' + intermediate)
        second = review(data)
        second['member'] = intermediate
        with self.assertRaisesRegex(ValueError, 'intermediate symlink missing'):
            self.scan(data, [first, second])

    def test_context_target_hash_source_rule_or_certificate_changes_are_blocked(self):
        data = archive()
        for edit in ('context', 'target', 'hash', 'source', 'rule', 'certificate', 'evidence'):
            with self.subTest(edit=edit):
                row = review(data)
                if edit == 'context': row['archiveSha256'] = '0' * 64
                if edit == 'target': row['linkTarget'] = '/other.crt'
                if edit == 'hash': row['sha256'] = '0' * 64
                if edit == 'source': row['source'] = 'https://unapproved.example.invalid/archive'
                if edit == 'rule': row['rules'] += ['private domain']
                if edit == 'certificate': row['certificate']['sha256'] = '0' * 64
                if edit == 'evidence': row['evidence']['kind'] = 'upstream-test-reference'
                _, rejected = self.scan(data, [row])
                self.assertTrue(any(path.endswith(LINK) for path, _ in rejected))

    def test_actual_target_mutation_is_not_approved_by_a_new_container_context(self):
        old = archive()
        changed = archive(target='/other.crt')
        row = review(old)
        row['distributions'] = [{'archiveSha256': sha(changed), 'member': LINK}]
        _, rejected = self.scan(changed, [row])
        self.assertTrue(any(path.endswith(LINK) for path, _ in rejected))

    def test_regular_file_cannot_impersonate_required_official_symlink_origin(self):
        regular = archive(link_type=tarfile.REGTYPE)
        actual = archive()
        row = review(regular)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
        scanner, _ = self.scan(regular, [row], finish=False)
        scanner.scan('actual.tar', actual)
        with self.assertRaisesRegex(ValueError, 'exact TAR symlink'):
            scanner.finish()

    def test_missing_official_source_or_certificate_does_not_complete(self):
        original = archive()
        actual = archive(include_certificate=False)
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        with self.assertRaisesRegex(ValueError, 'origin was not verified'):
            self.scan(actual, [row])
        row = review(actual)
        with self.assertRaisesRegex(ValueError, 'reference was not verified'):
            self.scan(actual, [row])

    def test_certificate_in_official_archive_does_not_supply_missing_actual_certificate(self):
        original = archive()
        actual = archive(include_certificate=False)
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        scanner, _ = self.scan(original, [row], finish=False)
        scanner.scan('actual.tar', actual)
        with self.assertRaisesRegex(ValueError, 'inspected link container'):
            scanner.finish()

    def test_certificate_evidence_must_be_regular_not_another_symlink(self):
        data = archive(include_certificate=False, extra_links=[(CERT, '/other.crt')],
                       extra=[('other.crt', CA)])
        row = review(data)
        with self.assertRaisesRegex(ValueError, 'reference was not verified'):
            self.scan(data, [row])

    def test_mismatched_certificate_path_and_escaping_or_cyclic_targets_stay_blocked(self):
        for target in ('/wrong.crt', '../../../../outside.crt', '/' + LINK):
            with self.subTest(target=target):
                data = archive(target=target)
                _, rejected = self.scan(data, [review(data, target=target)])
                self.assertTrue(any(path.endswith(LINK) for path, _ in rejected))

    def test_malformed_certificate_distributions_are_not_valid_reviews(self):
        data = archive()
        row = review(data)
        row['certificate']['distributions'] = {'invalid': 'mapping'}
        self.assertFalse(valid_evidence(row))

    def test_malformed_pem_and_private_key_payload_are_rejected_even_when_pinned(self):
        key_marker = b'-----BEGIN ' + b'PRIVATE KEY-----\nfixture\n'
        for certificate in (b'not a certificate', CA + key_marker,
                            CA.replace(b'Q0EgMzBZ', b'!!!!!!!!')):
            with self.subTest(payload=sha(certificate)), self.assertRaisesRegex(ValueError, 'Public CA evidence'):
                data = archive(certificate=certificate)
                self.scan(data, [review(data, certificate=certificate)])

    def test_non_ca_certificate_is_rejected_even_when_pinned(self):
        import ssl
        der = ssl.PEM_cert_to_DER_cert(CA.decode('ascii'))
        # Change the BasicConstraints CA boolean; parsing does not rely on a
        # valid self-signature, and this creates no key or live certificate.
        marker = b'\x06\x03\x55\x1d\x13\x01\x01\xff\x04\x05\x30\x03\x01\x01\xff'
        self.assertEqual(1, der.count(marker))
        der = der.replace(marker, marker[:-1] + b'\x00')
        certificate = ssl.DER_cert_to_PEM_cert(der).encode('ascii')
        data = archive(certificate=certificate)
        with self.assertRaisesRegex(ValueError, 'Public CA evidence'):
            self.scan(data, [review(data, certificate=certificate)])

    def test_private_key_regular_pem_keeps_both_policy_findings(self):
        key = b'-----BEGIN ' + b'PRIVATE KEY-----\nfixture\n'
        data = archive(link_type=tarfile.REGTYPE, link_content=key)
        _, rejected = self.scan(data, [review(data)])
        reasons = next(reasons for path, reasons in rejected if path.endswith(LINK))
        self.assertIn('private file type', reasons)
        self.assertIn('credential pattern', reasons)

    def test_other_findings_in_link_headers_and_nearby_members_are_preserved(self):
        target = '/https://private.example.invalid/fixture.crt'
        data = archive(target=target, extra=[('other.txt', b'https://private.example.invalid')])
        row = review(data, target=target)
        _, rejected = self.scan(data, [row])
        self.assertTrue(any(path.endswith(LINK) and 'private domain' in reasons for path, reasons in rejected))
        self.assertTrue(any(path.endswith('/other.txt') and 'private domain' in reasons for path, reasons in rejected))

    def test_altered_certificate_bytes_do_not_supply_pinned_ca_evidence(self):
        original = archive()
        changed = archive(certificate=CA + b'\n')
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(changed), 'member': LINK}]
        row['certificate']['distributions'] = [{'archiveSha256': sha(changed), 'member': CERT}]
        scanner, _ = self.scan(original, [row], finish=False)
        scanner.scan('actual.tar', changed)
        with self.assertRaisesRegex(ValueError, 'inspected link container'):
            scanner.finish()

    def test_complete_normal_material_scan_verifies_separate_official_origin(self):
        original = archive(extra=[('origin.txt', b'official fixture')])
        actual = archive(extra=[('candidate.txt', b'actual candidate')])
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
        report = self.scan_materials([actual, original], [row])
        self.assertTrue(report['accepted'])
        self.assertTrue(report['complete'])
        self.assertEqual([], report['rejected'])
        self.assertEqual(2, len(report['inputs']['materials']))

    def test_normal_material_scan_still_requires_the_actual_official_origin(self):
        original = archive(extra=[('origin.txt', b'official fixture')])
        actual = archive(extra=[('candidate.txt', b'actual candidate')])
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
        with self.assertRaisesRegex(ValueError, 'origin was not verified'):
            self.scan_materials([actual], [row])

    def test_normal_material_scan_does_not_borrow_unrelated_or_changed_current_certificate(self):
        original = archive(extra=[('origin.txt', b'official fixture')])
        for actual in (archive(include_certificate=False), archive(certificate=CA + b'\n')):
            with self.subTest(actual=sha(actual)):
                row = review(original)
                row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
                row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
                with self.assertRaisesRegex(ValueError, 'inspected link container'):
                    self.scan_materials([actual, original], [row])

    def test_normal_material_scan_requires_current_intermediate_not_just_official_one(self):
        intermediate = 'etc/ssl/intermediate.pem'
        original = archive(target='/' + intermediate, extra_links=[(intermediate, TARGET)])
        actual = archive(target='/' + intermediate)
        first = review(original, target='/' + intermediate)
        second = review(original)
        second['member'] = intermediate
        for row in (first, second):
            row['distributions'] = [{'archiveSha256': sha(actual), 'member': row['member']}]
            row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
        with self.assertRaisesRegex(ValueError, 'intermediate symlink missing'):
            self.scan_materials([actual, original], [first, second])

    def test_normal_material_scan_does_not_approve_current_regular_pem(self):
        original = archive()
        actual = archive(link_type=tarfile.REGTYPE)
        row = review(original)
        row['distributions'] = [{'archiveSha256': sha(actual), 'member': LINK}]
        row['certificate']['distributions'] = [{'archiveSha256': sha(actual), 'member': CERT}]
        report = self.scan_materials([actual, original], [row])
        self.assertFalse(report['accepted'])
        self.assertTrue(report['complete'])
        self.assertTrue(any(path.endswith(LINK) and 'private file type' in reasons
                            for path, reasons in report['rejected']))


if __name__ == '__main__':
    unittest.main()
