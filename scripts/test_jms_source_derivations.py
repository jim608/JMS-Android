"""Exact synthetic lineage cannot authorize unrelated source data or secrets."""
import copy
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zstandard

import check_jms_git_privacy as privacy
import jms_source_derivations as lineage


def tar_bytes(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for name, content in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()


def zip_bytes(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, content in sorted(files.items()):
            archive.writestr(name, content)
    return output.getvalue()


class SourceDerivationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'config').mkdir()
        self.source_name = 'synthetic-openssl-1.src.tar.zst'
        self.inner_name = 'source/openssl-1.tar.gz'
        self.source_files = {'openssl-1/build.info': b'Explicit synthetic source graph',
                             'openssl-1/fixture.key': b'public synthetic fixture',
                             'openssl-1/a.pem': b'unknown synthetic A',
                             'openssl-1/b.pem': b'unknown synthetic B',
                             'openssl-1/c.pem': b'unknown synthetic C',
                             'openssl-1/LICENSE.txt': b'Synthetic source license'}
        self.origin = {'archive': self.source_name,
                       'url': 'https://repo.msys2.org/mingw/sources/' + self.source_name}
        self.build()

    def build(self):
        original_inner = gzip.compress(tar_bytes(self.source_files), mtime=0)
        recipe = ('source=("https://github.com/openssl/openssl/releases/download/openssl-${pkgver}/openssl-${pkgver}.tar.gz"{,.asc})\n'
                  "sha256sums=('" + lineage.digest(original_inner) + "'\n"
                  "            'SKIP'\n)\n"
                  'prepare() { true; }\nbuild() { true; }\ncheck() { true; }\npackage() { true; }\n').encode()
        original_files = {self.inner_name: original_inner, 'source/PKGBUILD': recipe,
                          'source/openssl-1.tar.gz.asc': b'Original signature placeholder'}
        self.original = zstandard.ZstdCompressor().compress(tar_bytes(original_files))
        self.origin['sha256'] = lineage.digest(self.original)
        path = self.root / 'artifacts/checks/m32/msys' / self.source_name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.original)
        native = {'sourceBase': 'https://repo.msys2.org/mingw/sources/',
                  'sources': {self.source_name: {'sha256': self.origin['sha256']}}}
        (self.root / 'config/jms_windows_native.json').write_text(json.dumps(native))
        removed = [{'member': 'openssl-1/' + name,
                    'sha256': lineage.digest(self.source_files['openssl-1/' + name]),
                    'reason': 'Synthetic unused source data; no credential approval.',
                    'evidence': [{'member': 'openssl-1/build.info',
                                  'sha256': lineage.digest(self.source_files['openssl-1/build.info'])}]}
                   for name in ('a.pem', 'b.pem', 'c.pem')]
        retained = {name: data for name, data in self.source_files.items()
                    if name not in {item['member'] for item in removed}}
        self.derived_inner = gzip.compress(tar_bytes(retained), mtime=0)
        manifest = {'schemaVersion': 1, 'origin': self.origin, 'sourceMember': self.inner_name,
                    'removed': removed, 'originalSourceSha256': lineage.digest(original_inner),
                    'derivedSourceSha256': lineage.digest(self.derived_inner),
                    'retainedMembers': len(retained), 'retainedRegularFiles': len(retained)}
        manifest_data = json.dumps(manifest).encode()
        self.files = dict(original_files)
        self.files[self.inner_name] = self.derived_inner
        self.files.update({'source/JMS_DERIVATION.json': manifest_data,
                           'source/JMS_SOURCE_SCOPE.md': lineage.scope_text(),
                           'source/JMS_REMOVE_UNUSED_FIXTURES.py': lineage.removal_script(),
                           'source/PKGBUILD.jms-derived': lineage.derived_recipe(
                               recipe, lineage.digest(original_inner), lineage.digest(self.derived_inner))})
        self.data = zip_bytes(self.files)
        self.policy = {'archiveSha256': lineage.digest(self.data),
                       'manifestSha256': lineage.digest(manifest_data), 'origin': self.origin,
                       'sourceMember': self.inner_name, 'removed': removed}
        (self.root / 'config/jms_source_derivations.json').write_text(json.dumps([self.policy]))
        fixture = self.inner_name + '/openssl-1/fixture.key'
        self.review = {'archiveSha256': self.origin['sha256'], 'member': fixture,
                       'sha256': lineage.digest(self.source_files['openssl-1/fixture.key']),
                       'source': self.origin['url'], 'rules': ['private file type'],
                       'explanation': 'Synthetic exact public fixture reference.',
                       'evidence': {'kind': 'upstream-test-reference',
                                    'member': self.inner_name + '/openssl-1/build.info',
                                    'sha256': lineage.digest(self.source_files['openssl-1/build.info'])},
                       'distributions': [{'archiveSha256': lineage.digest(self.data), 'member': fixture}]}

    def test_exact_retained_source_and_explicit_distribution_are_verified(self):
        aliases = lineage.verify_lineage(self.data, self.policy, self.root)
        self.assertEqual(5, len(aliases))
        scanner = privacy.ArchiveScan([], [self.review], project=self.root)
        findings = scanner.scan('derived.zip', self.data)
        scanner.finish()
        self.assertFalse([item for item in findings if item[1]])
        scanner = privacy.ArchiveScan([], [], project=self.root)
        self.assertTrue([item for item in scanner.scan('derived.zip', self.data) if item[1]])

    def test_changed_bit_forged_path_extra_file_and_fourth_removal_are_rejected(self):
        for mode in ('bit', 'path', 'extra', 'fourth', 'recipe', 'script', 'manifest'):
            with self.subTest(mode=mode):
                files = dict(self.files)
                retained = {name: data for name, data in self.source_files.items()
                            if not name.endswith(('a.pem', 'b.pem', 'c.pem'))}
                if mode == 'bit':
                    retained['openssl-1/fixture.key'] += b'x'
                elif mode == 'path':
                    retained['openssl-1/forged.key'] = retained.pop('openssl-1/fixture.key')
                elif mode == 'fourth':
                    del retained['openssl-1/LICENSE.txt']
                elif mode == 'extra':
                    files['source/extra.txt'] = b'not reviewed'
                else:
                    key = {'recipe': 'source/PKGBUILD.jms-derived',
                           'script': 'source/JMS_REMOVE_UNUSED_FIXTURES.py',
                           'manifest': 'source/JMS_DERIVATION.json'}[mode]
                    files[key] += b'x'
                if mode in ('bit', 'path', 'fourth'):
                    files[self.inner_name] = gzip.compress(tar_bytes(retained), mtime=0)
                data = zip_bytes(files)
                policy = dict(self.policy, archiveSha256=lineage.digest(data))
                with self.assertRaises(ValueError):
                    lineage.verify_lineage(data, policy, self.root)

    def test_wrong_origin_hash_unknown_exclusion_and_evidence_are_rejected(self):
        for mode in ('origin', 'url', 'evidence', 'removed'):
            policy = copy.deepcopy(self.policy)
            if mode == 'origin':
                policy['origin']['sha256'] = '0' * 64
            elif mode == 'url':
                policy['origin']['url'] = 'https://forged.example.invalid/' + self.source_name
            elif mode == 'evidence':
                policy['removed'][0]['evidence'][0]['sha256'] = '0' * 64
            else:
                policy['removed'][0]['member'] = 'openssl-1/unknown.pem'
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                lineage.verify_lineage(self.data, policy, self.root)

    def test_private_policy_and_unknown_credentials_are_not_covered_by_lineage(self):
        self.source_files['openssl-1/private.txt'] = b'https://private.example.invalid'
        self.source_files['openssl-1/unknown.txt'] = b'password="' + b'x' * 32 + b'"'
        self.build()
        scanner = privacy.ArchiveScan(['private.example.invalid'], [self.review], project=self.root)
        findings = scanner.scan('derived.zip', self.data)
        scanner.finish()
        rejected = [reason for _, reasons in findings for reason in reasons]
        self.assertIn('private domain', rejected)
        self.assertIn('credential assignment', rejected)

    def test_malformed_nested_container_and_resource_limits_still_block(self):
        self.source_files['openssl-1/unknown.tar'] = b'not a tar archive'
        self.build()
        with self.assertRaises((ValueError, tarfile.ReadError)):
            privacy.ArchiveScan([], [self.review], project=self.root).scan('derived.zip', self.data)
        with patch.object(lineage, 'MAX_MEMBERS', 2), self.assertRaises(ValueError):
            lineage.verify_lineage(self.data, self.policy, self.root)
        with patch.object(lineage, 'MAX_BYTES', 64), self.assertRaises(ValueError):
            lineage.verify_lineage(self.data, self.policy, self.root)

    def test_lineage_cache_inputs_change_with_policy_original_and_validator(self):
        first = lineage.lineage_cache_inputs([self.policy['archiveSha256']], self.root)
        path = self.root / 'artifacts/checks/m32/msys' / self.source_name
        path.write_bytes(path.read_bytes() + b'x')
        self.assertNotEqual(first, lineage.lineage_cache_inputs([self.policy['archiveSha256']], self.root))
        with self.assertRaises(ValueError):
            lineage.verify_lineage(self.data, self.policy, self.root)


if __name__ == '__main__':
    unittest.main()
