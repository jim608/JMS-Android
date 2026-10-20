import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from correct_jms_release_description import correct_description, PLATFORMS, _public_url, release_snapshot
from jms_publication import ReleaseError
from jms_release_notes import release_body_for_candidate


VERSION = '0.11.1-jms.42'
SOURCE = '2' * 40
REVISION = '3' * 40
CHINESE = f'# JMS {VERSION}\n\n## 修正\n- 修正字幕載入。\n'
NOTES = (f'# JMS {VERSION}\n\n## 繁體中文 / Traditional Chinese\n\n### 修正\n- 修正字幕載入。\n'
         '\n## English\n\n### Fixed\n- Fix subtitle loading.\n')


class FakeReleaseApi:
    def __init__(self, platform='android'):
        self.platform = platform
        self.repository, manifest_name = PLATFORMS[platform]
        self.calls, self.downloads = [], []
        build = f'JMS-{VERSION}-' + ('a' * 12 if platform == 'android' else platform + '-' + SOURCE[:12])
        installer = (f'JMS-Android-{VERSION}-release-arm64-test-signed.apk' if platform == 'android'
                     else f'JMS-Windows-{VERSION}-x64-setup.exe' if platform == 'windows'
                     else f'JMS-Linux-{VERSION}-x86_64.pkg.tar.xz')
        source = f'JMS-Windows-{VERSION}-source.zip' if platform == 'windows' else f'JMS-{VERSION}-source.zip'
        self.manifest = {'schemaVersion': 1, 'applicationId': 'com.jim608.jms', 'versionName': VERSION,
                         'versionCode': 2044 if platform == 'android' else 44, 'sourceCommit': SOURCE, 'buildId': build,
                         'apk' if platform == 'android' else 'installer': {'name': installer, 'size': 20, 'sha256': 'a' * 64},
                         'source': {'name': source, 'size': 30, 'sha256': 'b' * 64}}
        self.manifest.update({'abis': ['arm64-v8a']} if platform == 'android' else {'platform': platform + '-x64'})
        self.release = {'id': 7, 'tag_name': 'v' + VERSION, 'target_commitish': 'jms', 'name': 'Old title',
                        'body': release_body_for_candidate(CHINESE, VERSION, SOURCE, build),
                        'draft': False, 'prerelease': True,
                        'html_url': f'https://github.com/{self.repository}/releases/tag/v{VERSION}',
                        'assets': [{'id': 1, 'name': manifest_name, 'size': 1, 'digest': 'sha256:' + 'c' * 64,
                                    'state': 'uploaded', 'browser_download_url':
                                    f'https://github.com/{self.repository}/releases/download/v{VERSION}/{manifest_name}'},
                                   {'id': 2, 'name': installer, 'size': 20, 'digest': 'sha256:' + 'a' * 64, 'state': 'uploaded'},
                                   {'id': 3, 'name': source, 'size': 30, 'digest': 'sha256:' + 'b' * 64, 'state': 'uploaded'}]}
        self.patch_mutation = None
        self.public_mutation = None
        self.refresh_manifest()

    def refresh_manifest(self):
        self.manifest_bytes = json.dumps(self.manifest).encode()
        self.release['assets'][0].update(size=len(self.manifest_bytes),
                                          digest='sha256:' + hashlib.sha256(self.manifest_bytes).hexdigest())

    def api(self, endpoint, method='GET', payload=None):
        self.calls.append((endpoint, method, payload))
        if method == 'PATCH':
            self.release.update(payload)
            if self.patch_mutation:
                self.patch_mutation(self.release)
        return copy.deepcopy(self.release)

    def fetch(self, url, maximum):
        self.downloads.append(url)
        if url.startswith('https://api.github.com/'):
            result = copy.deepcopy(self.release)
            if self.public_mutation:
                self.public_mutation(result)
            return json.dumps(result).encode()
        return self.manifest_bytes

    def correct(self, apply=False, **options):
        defaults = dict(platform=self.platform, source_commit=SOURCE, notes_revision_commit=REVISION,
                        expected_asset_count=3, fetch=self.fetch)
        defaults.update(options)
        return correct_description(self, VERSION, NOTES, apply, **defaults)


class ReleaseDescriptionTests(unittest.TestCase):
    def test_default_dry_run_all_native_platforms_verifies_exact_candidate_without_writes(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                api = FakeReleaseApi(platform)
                before = copy.deepcopy(api.release)
                receipt = api.correct()
                self.assertEqual(receipt['status'], 'dry-run')
                self.assertEqual(api.release, before)
                self.assertEqual([method for _, method, _ in api.calls], ['GET'])
                self.assertEqual(receipt['buildId'], api.manifest['buildId'])
                self.assertEqual(receipt['sourceCommit'], SOURCE)
                self.assertEqual(receipt['notesRevisionCommit'], REVISION)
                self.assertEqual(len(api.downloads), 2)

    def test_apply_changes_only_title_body_and_verifies_fresh_authenticated_and_anonymous_get(self):
        api = FakeReleaseApi()
        plan = api.correct()
        before = release_snapshot(api.release, VERSION)
        api.calls.clear()
        receipt = api.correct(True, approved_body_sha256=plan['bodySha256'])
        self.assertEqual(receipt['status'], 'applied')
        self.assertEqual([method for _, method, _ in api.calls], ['GET', 'PATCH', 'GET'])
        patch = api.calls[1]
        self.assertEqual(set(patch[2]), {'name', 'body'})
        self.assertTrue(patch[0].endswith('/releases/7'))
        self.assertEqual(receipt['releaseBefore'], before)
        self.assertEqual(receipt['releaseAfter'], before)
        self.assertTrue(receipt['immutableAssetsUnchanged'])
        self.assertEqual(receipt['remoteReadback']['bodySha256'], plan['bodySha256'])
        self.assertIn('## English', api.release['body'])
        self.assertIn(api.manifest['buildId'], api.release['body'])

    def test_already_current_is_idempotent_and_receipts_do_not_touch_publisher_state(self):
        api = FakeReleaseApi()
        api.release.update(name='JMS ' + VERSION,
                           body=release_body_for_candidate(NOTES, VERSION, SOURCE, api.manifest['buildId']))
        with tempfile.TemporaryDirectory() as directory:
            publisher = Path(directory) / 'publisher-state.json'
            publisher.write_bytes(b'original immutable state')
            receipt = api.correct(receipt_directory=Path(directory) / 'correction')
            self.assertEqual(receipt['status'], 'already-current')
            self.assertEqual(publisher.read_bytes(), b'original immutable state')
            self.assertEqual(Path(receipt['preview']['path']).read_bytes(), receipt['body'].encode())
            self.assertTrue((Path(directory) / 'correction/dry-run.json').is_file())
            self.assertTrue((Path(directory) / 'correction/already-current.json').is_file())
            self.assertTrue(all(method == 'GET' for _, method, _ in api.calls))

    def test_apply_requires_exact_reviewed_body_hash(self):
        api = FakeReleaseApi()
        for value in (None, '0' * 64):
            with self.assertRaises(ReleaseError):
                api.correct(True, approved_body_sha256=value)
        self.assertTrue(all(method == 'GET' for _, method, _ in api.calls))

    def test_wrong_source_build_platform_and_manifest_identity_are_rejected(self):
        for field, value in [('sourceCommit', '4' * 40), ('versionName', '0.11.1-jms.41'),
                             ('applicationId', 'other.application'), ('schemaVersion', 2),
                             ('abis', ['x86_64']), ('buildId', f'JMS-{VERSION}-windows-' + 'a' * 12)]:
            api = FakeReleaseApi()
            api.manifest[field] = value
            api.refresh_manifest()
            with self.subTest(field=field), self.assertRaises(ReleaseError):
                api.correct()
        api = FakeReleaseApi('windows')
        api.manifest['platform'] = 'linux-x64'
        api.refresh_manifest()
        with self.assertRaises(ReleaseError):
            api.correct()
        with self.assertRaises(ReleaseError):
            FakeReleaseApi().correct(expected_build_id='wrong')

    def test_manifest_hash_size_url_and_payload_source_bindings_are_rejected(self):
        mutations = [lambda api: setattr(api, 'manifest_bytes', api.manifest_bytes + b' '),
                     lambda api: api.release['assets'][0].update(size=2),
                     lambda api: api.release['assets'][0].update(browser_download_url='https://example.invalid/update.json'),
                     lambda api: api.release['assets'][1].update(digest='sha256:' + 'f' * 64),
                     lambda api: api.release['assets'][2].update(size=31)]
        for mutation in mutations:
            api = FakeReleaseApi()
            mutation(api)
            with self.subTest(mutation=mutation), self.assertRaises(ReleaseError):
                api.correct()

    def test_duplicate_asset_names_or_ids_missing_sha_and_unuploaded_assets_are_rejected(self):
        for key, value in [('id', 1), ('name', 'update.json'), ('digest', None), ('state', 'new')]:
            api = FakeReleaseApi()
            api.release['assets'][1][key] = value
            with self.subTest(key=key), self.assertRaises(ReleaseError):
                api.correct()
        api = FakeReleaseApi()
        api.release['assets'].append(copy.deepcopy(api.release['assets'][1]))
        with self.assertRaises(ReleaseError):
            api.correct(expected_asset_count=4)

    def test_wrong_repository_web_draft_stable_tag_and_footer_are_rejected(self):
        for key, value in [('draft', True), ('prerelease', False), ('tag_name', 'vother'),
                           ('target_commitish', ''), ('body', 'missing candidate footer')]:
            api = FakeReleaseApi()
            api.release[key] = value
            with self.subTest(key=key), self.assertRaises(ReleaseError):
                api.correct()
        for repository in ('jim608/JMS-Web', 'other/repo'):
            api = FakeReleaseApi()
            api.repository = repository
            with self.assertRaises(ReleaseError):
                api.correct()
        with self.assertRaises(ReleaseError):
            FakeReleaseApi().correct(platform='web')

    def test_asset_or_identity_mutation_in_patch_response_stops_immediately(self):
        for mutation in (lambda release: release['assets'][1].update(size=21),
                         lambda release: release.update(id=8), lambda release: release.update(draft=True),
                         lambda release: release.update(target_commitish='other'),
                         lambda release: release.update(body='not saved')):
            api = FakeReleaseApi()
            plan = api.correct()
            api.patch_mutation = mutation
            with self.subTest(mutation=mutation), self.assertRaises(ReleaseError):
                api.correct(True, approved_body_sha256=plan['bodySha256'])

    def test_anonymous_drift_is_rejected_before_patch_and_after_patch(self):
        api = FakeReleaseApi()
        api.public_mutation = lambda release: release['assets'][1].update(size=21)
        with self.assertRaises(ReleaseError):
            api.correct()
        self.assertFalse(any(method == 'PATCH' for _, method, _ in api.calls))
        api = FakeReleaseApi()
        plan = api.correct()
        api.patch_mutation = lambda release: setattr(api, 'public_mutation', lambda public: public.update(body='stale'))
        with self.assertRaises(ReleaseError):
            api.correct(True, approved_body_sha256=plan['bodySha256'])

    def test_anonymous_transport_rejects_http_credentials_private_hosts_and_untrusted_redirects(self):
        for url in ('http://github.com/path', 'https://' + 'user:password@github.com/path',
                    'https://github.com:8443/path', 'https://api.github.com.example.invalid/path',
                    'https://127.0.0.1/path'):
            with self.subTest(url=url), self.assertRaises(ReleaseError):
                _public_url(url)
        for host in ('github.com', 'api.github.com', 'release-assets.githubusercontent.com'):
            _public_url('https://' + host + '/path')

    def test_body_that_would_truncate_identity_in_update_dialog_is_rejected(self):
        api = FakeReleaseApi()
        large_notes = NOTES.replace('Fix subtitle loading.', 'Fix ' + 'subtitle ' * 3000 + 'loading.')
        with self.assertRaises(ReleaseError):
            correct_description(api, VERSION, large_notes, platform='android', source_commit=SOURCE,
                                notes_revision_commit=REVISION, fetch=api.fetch)


if __name__ == '__main__':
    unittest.main()
