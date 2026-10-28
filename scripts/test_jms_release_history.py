import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import jms_release_history as history
import prepare_jms_release as candidate


class FakeGithub:
    def __init__(self, payloads):
        self.payloads, self.downloads = payloads, []

    def asset_bytes(self, asset, destination):
        self.downloads.append(asset['id'])
        Path(destination).write_bytes(self.payloads[asset['id']])

    def api(self, *args, **kwargs):
        raise AssertionError('History inspection must never mutate GitHub')


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache, self.sdk = self.root / 'cache', self.root / 'sdk'
        self.sdk.mkdir()
        for name in ('aapt.exe', 'apksigner.bat'):
            (self.sdk / name).write_bytes(b'fixture tool, never executed')
        self.payloads = {}
        self.github = FakeGithub(self.payloads)

    def asset(self, name='update.json', content=b'{"versionCode":2049}', identity=11):
        self.payloads[identity] = content
        return {'id': identity, 'name': name, 'size': len(content), 'state': 'uploaded',
                'digest': 'sha256:' + hashlib.sha256(content).hexdigest()}

    def release(self, assets):
        return {'id': 7, 'draft': False, 'tag_name': 'untrusted-name-999999', 'assets': assets}

    def verify(self, release, code=2063):
        return history.verify_published_version_codes(self.github, [release], code, self.cache, self.sdk)

    def apk_bytes(self, omit=None):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            for name in ('AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libapp.so',
                         'lib/arm64-v8a/libflutter.so'):
                if name != omit:
                    archive.writestr(name, b'fixture')
        return output.getvalue()

    def badging(self, package='com.jim608.jms.dev', code='2049', extra=''):
        return (f"package: name='{package}' versionCode='{code}' versionName='fixture' {extra}\n"
                "sdkVersion:'24'\nnative-code: 'arm64-v8a'\n").encode()

    def signature(self, signer=history.SIGNER, count=1):
        return (f'Verifies\nNumber of signers: {count}\n'
                f'Signer #1 certificate SHA-256 digest: {signer}\n').encode()

    def test_manifest_is_default_and_never_invokes_apk_inspector(self):
        release = self.release([self.asset(), self.asset('misleading.apk', b'unused', 12)])
        with patch.object(history, 'inspect_historical_apk') as inspect:
            records = self.verify(release)
        inspect.assert_not_called()
        self.assertEqual(self.github.downloads, [11])
        self.assertEqual(records[0]['versionCode'], 2049)
        self.assertEqual(records[0]['proof'], 'update.json')

    def test_missing_manifest_reads_actual_dev_apk_and_ignores_name_claims(self):
        asset = self.asset('claimed-code-1.apk', self.apk_bytes())
        with patch.object(history, 'execute', side_effect=[self.badging(), self.signature()]) as execute:
            records = self.verify(self.release([asset]))
        self.assertEqual(records[0]['applicationId'], 'com.jim608.jms.dev')
        self.assertEqual(records[0]['versionCode'], 2049)
        self.assertEqual(records[0]['signerSha256'], history.SIGNER)
        self.assertEqual(records[0]['proof'], 'verified-apk')
        self.assertEqual([call.kwargs['timeout'] for call in execute.call_args_list], [60, 120])

    def test_valid_cached_apk_by_asset_identity_avoids_download(self):
        asset = self.asset('anything.apk', self.apk_bytes())
        path = history.history_asset_path(self.cache, asset, apk=True)
        path.parent.mkdir()
        path.write_bytes(self.payloads[11])
        with patch.object(history, 'execute', side_effect=[self.badging(), self.signature()]):
            self.verify(self.release([asset]))
        self.assertEqual(self.github.downloads, [])
        self.assertIn('asset-11-', path.name)

    def test_forged_same_size_cache_is_rejected_without_redownload_or_inspection(self):
        asset = self.asset('test.apk', self.apk_bytes())
        path = history.history_asset_path(self.cache, asset, apk=True)
        path.parent.mkdir()
        path.write_bytes(b'X' * asset['size'])
        with patch.object(history, 'inspect_historical_apk') as inspect:
            with self.assertRaisesRegex(history.ReleaseError, 'SHA256'):
                self.verify(self.release([asset]))
        inspect.assert_not_called()
        self.assertEqual(self.github.downloads, [])

    def test_download_digest_or_size_mismatch_never_enters_cache(self):
        for change in ('digest', 'size'):
            with self.subTest(change=change):
                asset = self.asset('test.apk', self.apk_bytes())
                asset[change] = 'sha256:' + '0' * 64 if change == 'digest' else asset['size'] + 1
                with self.assertRaisesRegex(history.ReleaseError, 'size or SHA256'):
                    self.verify(self.release([asset]))
                self.assertEqual(list(self.cache.glob('*')), [])

    def test_missing_or_malformed_authenticated_identity_is_rejected(self):
        for key, value in (('digest', None), ('digest', 'md5:' + '0' * 32),
                           ('digest', 'sha256:' + 'z' * 64), ('size', True), ('size', 0),
                           ('size', history.MAX_ASSET + 1), ('id', True), ('state', 'new')):
            with self.subTest(key=key, value=value):
                asset = self.asset('test.apk', self.apk_bytes())
                asset[key] = value
                with self.assertRaises(history.ReleaseError):
                    self.verify(self.release([asset]))
        self.assertEqual(self.github.downloads, [])

    def test_missing_or_multiple_apks_never_skip_release(self):
        for assets in ([], [self.asset('source.zip', b'not an APK')],
                       [self.asset('one.apk'), self.asset('two.apk', identity=12)]):
            with self.subTest(assets=assets), self.assertRaisesRegex(history.ReleaseError, 'unambiguous'):
                self.verify(self.release(assets))
        self.assertEqual(self.github.downloads, [])

    def test_apk_mime_type_is_also_an_ambiguity_signal(self):
        other = self.asset('misnamed.bin', identity=12)
        other['content_type'] = 'application/vnd.android.package-archive'
        with self.assertRaisesRegex(history.ReleaseError, 'unambiguous'):
            self.verify(self.release([self.asset('test.apk'), other]))

    def test_duplicate_assets_manifest_or_release_metadata_rejects(self):
        manifest = self.asset()
        for assets in ([manifest, copy.deepcopy(manifest)],
                       [manifest, self.asset(identity=12)],
                       [manifest, self.asset('different.json')]):
            with self.subTest(assets=assets), self.assertRaisesRegex(history.ReleaseError, 'duplicat'):
                self.verify(self.release(assets))
        release = self.release([manifest])
        with self.assertRaisesRegex(history.ReleaseError, 'Duplicate historical release'):
            history.verify_published_version_codes(self.github, [release, release], 2063,
                                                    self.cache, self.sdk)

    def test_invalid_manifest_never_falls_back_to_apk(self):
        values = (b'bad JSON', b'[]', b'{}', b'{"versionCode":true}', b'{"versionCode":"2049"}',
                  b'{"versionCode":0}', b'{"versionCode":-1}', b'{"versionCode":2049.0}',
                  b'{"versionCode":NaN}', b'{"versionCode":1,"versionCode":2049}')
        for index, content in enumerate(values):
            with self.subTest(content=content):
                manifest = self.asset(content=content, identity=100 + index)
                with patch.object(history, 'inspect_historical_apk') as inspect:
                    with self.assertRaisesRegex(history.ReleaseError, 'invalid update.json'):
                        self.verify(self.release([manifest, self.asset('unused.apk', identity=50)]))
                inspect.assert_not_called()

    def test_manifest_identity_failure_also_never_falls_back(self):
        manifest = self.asset()
        manifest['digest'] = None
        with patch.object(history, 'inspect_historical_apk') as inspect, \
             self.assertRaisesRegex(history.ReleaseError, 'authenticated SHA256'):
            self.verify(self.release([manifest, self.asset('unused.apk', identity=12)]))
        inspect.assert_not_called()
        self.assertEqual(self.github.downloads, [])

    def test_equal_or_higher_manifest_code_rejects(self):
        for previous in (2063, 2064):
            with self.subTest(previous=previous), self.assertRaisesRegex(history.ReleaseError, 'not newer'):
                self.verify(self.release([self.asset(content=json.dumps({'versionCode': previous}).encode(),
                                                       identity=previous)]))

    def test_equal_or_higher_dev_apk_code_also_rejects(self):
        asset = self.asset('lower-code-1.apk', self.apk_bytes())
        for previous in ('2063', '2064'):
            with self.subTest(previous=previous), \
                 patch.object(history, 'execute', side_effect=[self.badging(code=previous), self.signature()]), \
                 self.assertRaisesRegex(history.ReleaseError, 'not newer'):
                self.verify(self.release([asset]))

    def test_candidate_code_must_be_a_positive_integer_not_bool(self):
        for code in (True, False, 0, -1, '2063', 2063.0, history.MAX_VERSION_CODE + 1):
            with self.subTest(code=code), self.assertRaises(history.ReleaseError):
                self.verify(self.release([self.asset()]), code)
        self.assertEqual(self.github.downloads, [])

    def test_malformed_release_metadata_is_not_skipped(self):
        for release in ({}, {'id': 1, 'draft': 'false'},
                        {'id': 1, 'draft': False, 'tag_name': 'x'},
                        {'id': 1, 'draft': False, 'assets': [], 'tag_name': ''}):
            with self.subTest(release=release), self.assertRaises(history.ReleaseError):
                self.verify(release)
        with self.assertRaises(history.ReleaseError):
            history.verify_published_version_codes(self.github, iter([]), 2063, self.cache, self.sdk)

    def test_published_release_after_draft_is_still_checked(self):
        draft = {'id': 1, 'draft': True}
        previous = self.release([self.asset(content=b'{"versionCode":2063}')])
        with self.assertRaisesRegex(history.ReleaseError, 'not newer'):
            history.verify_published_version_codes(self.github, [draft, previous], 2063,
                                                    self.cache, self.sdk)

    def inspect_fixture(self, badging=None, signature=None, omit=None):
        apk = self.root / 'fixture.apk'
        apk.write_bytes(self.apk_bytes(omit))
        with patch.object(history, 'execute', side_effect=[badging or self.badging(),
                                                          signature or self.signature()]):
            return history.inspect_historical_apk(apk, self.sdk)

    def test_unapproved_package_split_abi_and_untrusted_code_reject(self):
        badging = (self.badging(package='other.package'), self.badging(extra="split='config.en'"),
                   self.badging(extra="versionCodeMajor='1'"),
                   self.badging().replace(b"'arm64-v8a'", b"'arm64-v8a' 'x86_64'"),
                   self.badging(code='0'), self.badging(code='-1'), self.badging(code='true'),
                   self.badging(code='2100000001'), self.badging(code='9' * 5000),
                   self.badging() + self.badging(), b'unknown SDK output')
        for value in badging:
            with self.subTest(value=value), self.assertRaises(history.ReleaseError):
                self.inspect_fixture(badging=value)

    def test_missing_apk_members_and_non_apk_bytes_reject(self):
        with self.assertRaisesRegex(history.ReleaseError, 'required entries'):
            self.inspect_fixture(omit='lib/arm64-v8a/libapp.so')
        apk = self.root / 'fake.apk'
        apk.write_bytes(b'not an APK')
        with patch.object(history, 'execute', return_value=self.badging()), \
             self.assertRaisesRegex(history.ReleaseError, 'archive is invalid'):
            history.inspect_historical_apk(apk, self.sdk)

    def test_unpinned_multiple_or_unknown_signer_output_rejects(self):
        for signature in (self.signature('0' * 64), self.signature(count=2),
                          self.signature() + b'Signer #2 certificate SHA-256 digest: ' + b'0' * 64 + b'\n',
                          self.signature().replace(b'Signer #1', b'Signer #2'),
                          b'unknown signature output', self.signature().replace(b'Verifies', b'DOES NOT VERIFY')):
            with self.subTest(signature=signature), self.assertRaisesRegex(history.ReleaseError, 'signer'):
                self.inspect_fixture(signature=signature)

    def test_unknown_sdk_tool_failure_and_timeout_fail_closed(self):
        apk = self.root / 'fixture.apk'
        apk.write_bytes(self.apk_bytes())
        with self.assertRaisesRegex(history.ReleaseError, 'tools are unavailable'):
            history.inspect_historical_apk(apk, self.root / 'unknown-sdk')
        for error in (OSError('missing command'), subprocess.TimeoutExpired('fixture', 60),
                      history.ReleaseError('nonzero tool exit'), UnicodeDecodeError('utf8', b'\xff', 0, 1, 'bad')):
            with self.subTest(error=error), patch.object(history, 'execute', side_effect=error), \
                 self.assertRaisesRegex(history.ReleaseError, 'inspection failed'):
                history.inspect_historical_apk(apk, self.sdk)

    def test_signer_command_failure_cannot_accept_valid_badging(self):
        apk = self.root / 'fixture.apk'
        apk.write_bytes(self.apk_bytes())
        for error in (history.ReleaseError('signer nonzero exit'),
                      subprocess.TimeoutExpired('apksigner', 120)):
            with self.subTest(error=error), \
                 patch.object(history, 'execute', side_effect=[self.badging(), error]), \
                 self.assertRaisesRegex(history.ReleaseError, 'inspection failed'):
                history.inspect_historical_apk(apk, self.sdk)

    def test_missing_sdk_command_never_uses_path_fallback(self):
        (self.sdk / 'apksigner.bat').unlink()
        with patch.object(history, 'execute') as execute, \
             self.assertRaisesRegex(history.ReleaseError, 'tools are unavailable'):
            history.inspect_historical_apk(self.root / 'unused.apk', self.sdk)
        execute.assert_not_called()

    def test_normal_production_package_is_also_inspectable(self):
        self.assertEqual(self.inspect_fixture(badging=self.badging(package='com.jim608.jms'))['versionCode'], 2049)

    def test_existing_candidate_validator_still_rejects_dev_package(self):
        with patch.object(candidate, 'run', side_effect=[self.badging().decode(), self.signature().decode()]), \
             self.assertRaisesRegex(ValueError, 'Not a complete JMS ARM64 APK'):
            candidate.apk_info(self.root / 'unused.apk', self.sdk)


if __name__ == '__main__':
    unittest.main()
