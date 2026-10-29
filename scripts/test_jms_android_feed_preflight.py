import argparse
import ast
import copy
from contextlib import ExitStack
import hashlib
import inspect
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import jms_android_feed_preflight as feed
import publish_jms_release as publisher


MANUAL_TAG = 'test-0.11.1-jms.46-syncplay-hdr-test.20261024'
MANUAL_APK = 'JMS-Android-TEST-0.11.1-jms.46-syncplay-hdr-test.20261024-2049-arm64-v8a.apk'


def encoded(value):
    return json.dumps(value).encode()


def asset_url(tag, name):
    return 'https://github.com/jim608/JMS-Android/releases/download/' + tag + '/' + name


class FeedPreflightTests(unittest.TestCase):
    def setUp(self):
        owned = Path(__file__).resolve().parents[1] / 'artifacts/checks/android-feed-preflight-tests'
        owned.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=owned)
        self.root = Path(self.temporary.name)
        def cleanup():
            self.assertTrue(self.root.resolve().is_relative_to(owned.resolve()))
            self.temporary.cleanup()
        self.addCleanup(cleanup)
        self.state_dir = self.root / 'artifacts/publication/v0.11.1-jms.55'
        self.state_dir.mkdir(parents=True)
        self.state = {'tag': 'v0.11.1-jms.55', 'version': '0.11.1-jms.55', 'versionCode': 2064,
                      'sourceCommit': 'a' * 40, 'notes': 'Synthetic candidate', 'prerelease': False,
                      'published': False, 'sourceFingerprint': 'fingerprint', 'gitHistoryMode': 'jms-commits-v1'}
        self.files = {}
        for name, data in [('JMS-Android-0.11.1-jms.55-release-arm64-test-signed.apk', b'synthetic APK'),
                           ('JMS-0.11.1-jms.55-source.zip', b'synthetic source')]:
            self.add_asset(name, data)
        self.manifest = {'schemaVersion': 1, 'applicationId': 'com.jim608.jms',
                         'versionName': self.state['version'], 'versionCode': 2064,
                         'sourceCommit': 'a' * 40, 'minSdk': 24, 'abis': ['arm64-v8a'],
                         'apk': {'name': next(iter(self.files)), **self.public(next(iter(self.files)))},
                         'source': {'name': 'JMS-0.11.1-jms.55-source.zip',
                                    **self.public('JMS-0.11.1-jms.55-source.zip')}}
        self.add_asset('update.json', encoded(self.manifest))
        self.history = []
        self.bodies = {}
        self.reads = []
        self.executed = []
        self.prepare_checker_roots()

    def add_asset(self, name, raw):
        path = self.root / 'artifacts' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        self.files[name] = {'path': str(path), 'size': len(raw),
                            'sha256': hashlib.sha256(raw).hexdigest()}

    def public(self, name):
        return {k: self.files[name][k] for k in ('size', 'sha256')}

    def prepare_checker_roots(self):
        frozen = self.root / 'artifacts/publication/legacy-checker'
        inputs = []
        for name in ('lib/util/update_checker.dart', 'lib/util/update_source.dart', 'lib/util/brand.dart'):
            for tree in (self.root, frozen):
                path = tree / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(('frozen ' if tree == frozen else 'current ') + name)
            inputs.append({'path': name, 'sha256': feed.sha256(frozen / name)})
        for path, checkout in ((self.root / '.dart_tool/package_config.json', self.root),
                               (frozen / 'package_config.json', frozen)):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(encoded({'packages': [{'name': 'fladder', 'rootUri': checkout.as_uri() + '/'}]}))
        baseline = self.root / 'artifacts/checks/build-8-inputs.json'
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_bytes(encoded({'version': '0.11.1-jms.8', 'baseVersionCode': 8, 'inputs': inputs}))
        self.policy = {'baselineBuildRecord': str(baseline.relative_to(self.root)),
                       'baselineBuildRecordSha256': feed.sha256(baseline), 'baselineApk': 'baseline.apk'}
        (self.root / 'baseline.apk').write_bytes(b'synthetic baseline')
        self.policy['baselineSha256'] = feed.sha256(self.root / 'baseline.apk')
        config = self.root / 'config/jms_publication.json'
        config.parent.mkdir()
        config.write_bytes(encoded(self.policy))
        harness = self.root / 'scripts/check_jms_legacy_feed.dart'
        harness.parent.mkdir()
        harness.write_text('synthetic harness bytes')

    def manual_release(self, tag=MANUAL_TAG):
        return {'id': 46, 'tag_name': tag, 'name': 'Historical manual TEST', 'body': 'Preserve history',
                'draft': False, 'prerelease': True, 'published_at': '2026-10-24T00:00:00Z',
                'assets': [{'name': MANUAL_APK, 'size': 1000, 'state': 'uploaded',
                            'browser_download_url': asset_url(tag, MANUAL_APK)}]}

    def reader(self, url, limit):
        self.reads.append(url)
        return encoded(self.history) if url == feed.FEED_URL else self.bodies[url]

    def executor(self, command, *, environment, log, timeout):
        self.executed.append([str(value) for value in command])
        self.assertFalse(any(name in environment for name in ('GH_TOKEN', 'GITHUB_TOKEN')))
        fixture = json.loads(Path(next(str(v).split('=', 1)[1] for v in command
                                       if str(v).startswith('--history-fixture='))).read_text())
        legacy = '/legacy-checker/' in str(command[1]).replace('\\', '/')
        channel = 'stable' if '--stable' in command else 'prerelease'
        has_manual = any(row['tag_name'] == MANUAL_TAG for row in fixture['releases'])
        visible = channel == 'prerelease' or fixture['releases'][0]['prerelease'] is False
        status = 'incomplete' if has_manual and legacy and channel == 'prerelease' else 'available' if visible else 'noRelease'
        # This is a process-boundary fake, not a reimplementation/claim about the
        # actual checker. Root separately runs the immutable Dart algorithms.
        row = {'mode': 'prospective-fixture', 'channel': channel, 'installedVersionCode': 2008,
               'networkRequestsIssued': 0, 'status': status,
               'versionCode': fixture['candidateVersionCode'] if status == 'available' else None}
        raw = encoded(row)
        Path(log).write_bytes(raw)
        return raw

    def run_gate(self, executor=None, reader=None, authenticated_history=None, require_placement=False):
        return feed.preflight_android_feed(self.root, self.state, self.files, self.state_dir,
                                           executor or self.executor, reader=reader or self.reader,
                                           authenticated_history=authenticated_history,
                                           require_placement=require_placement)

    def test_candidate_and_history_replay_preserve_all_rows_and_only_read_manifests(self):
        self.history = [self.manual_release()]
        before = copy.deepcopy(self.history)
        history = feed.snapshot_history(self.reader)
        fixture = feed.build_prospective_fixture(self.state, self.files, history)
        self.assertEqual(fixture['releases'][1:], before)
        self.assertEqual(self.history, before)
        self.assertEqual(history['historyIssues'], [{'tag': MANUAL_TAG, 'reason': 'missing_or_duplicate_manifest'}])
        self.assertEqual(self.reads, [feed.FEED_URL])
        self.assertNotIn(asset_url(MANUAL_TAG, 'update.json'), fixture['responses'])

    def test_complete_matrix_passes_clean_stable_candidate(self):
        report = self.run_gate()
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(len(self.executed), 4)
        self.assertFalse(report['policyWaiverGranted'])
        self.assertEqual(report['preflightPhase'], 'pre-write-preview')
        self.assertFalse(report['candidatePlacementVerified'])
        self.assertFalse(report['publicationPlacementGateSatisfied'])
        self.assertTrue(all(row['status'] == 'available' for row in report['matrix']))

    def test_development_application_identity_cannot_be_a_production_candidate_fix(self):
        self.manifest['applicationId'] = 'com.jim608.jms.dev'
        self.add_asset('update.json', encoded(self.manifest))
        with self.assertRaisesRegex(feed.ReleaseError, 'manifest identity'):
            self.run_gate()
        self.assertEqual(self.reads, [])

    def test_candidate_byte_drift_is_rejected_before_public_snapshot(self):
        Path(self.files[next(iter(self.files))]['path']).write_bytes(b'changed')
        with self.assertRaisesRegex(feed.ReleaseError, 'bytes changed'):
            self.run_gate()
        self.assertEqual(self.reads, [])

    def test_stable_success_does_not_waive_legacy_optin_manual46_failure(self):
        self.history = [self.manual_release()]
        with self.assertRaisesRegex(feed.ReleaseError, 'no policy waiver'):
            self.run_gate()
        latest = json.loads((self.state_dir / 'feed-preflight-latest.json').read_text())
        report = json.loads((self.state_dir / latest['report']).read_text())
        self.assertEqual(report['status'], 'BLOCKED')
        matrix = {row['case']: row['status'] for row in report['matrix']}
        self.assertEqual(matrix['legacy8-stable'], 'available')
        self.assertEqual(matrix['legacy8-prerelease'], 'incomplete')
        self.assertEqual(matrix['current-prerelease'], 'available')
        self.assertTrue(report['legacyOptInManualBootstrapMayBeRequired'])

    def test_history_issue_blocks_even_if_candidate_displaces_it_past_client20(self):
        self.history = [dict(self.manual_release('vfixture-' + str(i)), assets=[]) for i in range(19)] + [self.manual_release()]
        def all_pass(*args, **kwargs):
            raw = self.executor(*args, **kwargs)
            row = json.loads(raw)
            row.update(status='available', versionCode=2064)
            return encoded(row)
        with self.assertRaisesRegex(feed.ReleaseError, 'incompatible'):
            self.run_gate(all_pass)
        fixture = json.loads(next(self.state_dir.glob('feed-preflight-*/prospective-feed.json')).read_text())
        self.assertEqual(len(fixture['releases']), 20)
        self.assertEqual(fixture['releases'][1:], self.history[:19])
        self.assertEqual(fixture['observedPublicReleases'], self.history)
        self.assertEqual(fixture['displacedPublicReleases'], self.history[19:])
        self.assertIn({'tag': MANUAL_TAG, 'reason': 'missing_or_duplicate_manifest'},
                      fixture['historyIssues'])

    def test_api_window_displaces_twenty_first_stable_malformed_row_before_channel_filter(self):
        self.history = [dict(self.manual_release('vfixture-' + str(i)), assets=[])
                        for i in range(19)]
        last = dict(self.manual_release('vold-stable'), prerelease=False, assets=[])
        self.history.append(last)
        observed = copy.deepcopy(self.history)
        fixture = feed.build_prospective_fixture(self.state, self.files,
                                                 feed.snapshot_history(self.reader))
        # Actual API per_page=20 excludes the oldest public row before either
        # immutable checker filters stable releases. It must not poison the
        # stable replay from a fictitious 21st API row.
        stable_replay = [r for r in fixture['releases'] if not r['prerelease']]
        self.assertEqual([r['tag_name'] for r in stable_replay], [self.state['tag']])
        self.assertEqual(fixture['observedPublicReleases'], observed)
        self.assertEqual(fixture['displacedPublicReleases'], [last])
        self.assertIn({'tag': 'vold-stable', 'reason': 'missing_or_duplicate_manifest'},
                      fixture['historyIssues'])
        self.assertEqual(self.history, observed)

    def test_manual46_within_real_first_page_remains_in_replay_and_blocks_optin(self):
        self.history = [dict(self.manual_release('vfixture-' + str(i)), assets=[])
                        for i in range(20)]
        self.history[2] = self.manual_release()
        fixture = feed.build_prospective_fixture(self.state, self.files,
                                                 feed.snapshot_history(self.reader))
        self.assertEqual(len(fixture['releases']), 20)
        self.assertEqual(fixture['releases'][3]['tag_name'], MANUAL_TAG)
        self.assertEqual(fixture['candidateOrdering'], 'new-release-first-assumption')
        self.assertFalse(fixture['candidatePlacementVerified'])
        with self.assertRaisesRegex(feed.ReleaseError, 'no policy waiver'):
            self.run_gate()

    def test_prerelease_stable_unavailable_is_reported_without_relabeling(self):
        self.state['prerelease'] = True
        report = self.run_gate()
        self.assertEqual({row['status'] for row in report['matrix'] if row['channel'] == 'stable'}, {'noRelease'})
        self.assertEqual(report['status'], 'PASS')

    def test_unsafe_history_asset_urls_never_requested(self):
        for url in ('https://evil.invalid/update.json',
                    'https://github.com/other/repo/releases/download/' + MANUAL_TAG + '/update.json',
                    asset_url('wrong-tag', 'update.json'),
                    asset_url(MANUAL_TAG, 'update.json') + '?token=not-a-real-token'):
            with self.subTest(url=url):
                self.history = [self.manual_release()]
                self.history[0]['assets'][0].update(name='update.json', browser_download_url=url)
                with self.assertRaisesRegex(feed.ReleaseError, 'URL/name'):
                    feed.snapshot_history(self.reader)
                self.assertTrue(all(value == feed.FEED_URL for value in self.reads))

    def test_wrong_history_size_digest_or_json_is_explicitly_blocking(self):
        for kind in ('size', 'digest', 'json', 'duplicate-json-field'):
            self.history = [self.manual_release()]
            raw = b'{"schemaVersion":1}' if kind != 'json' else b'not json'
            if kind == 'duplicate-json-field':
                raw = b'{"a":1,"a":2}'
            url = asset_url(MANUAL_TAG, 'update.json')
            row = {'name': 'update.json', 'state': 'uploaded', 'size': len(raw), 'browser_download_url': url,
                   'digest': 'sha256:' + hashlib.sha256(raw).hexdigest()}
            if kind == 'size': row['size'] += 1
            if kind == 'digest': row['digest'] = 'sha256:' + '0' * 64
            self.history[0]['assets'] = [row]
            self.bodies[url] = raw
            with self.subTest(kind=kind):
                history = feed.snapshot_history(self.reader)
                self.assertEqual(history['historyIssues'][0]['reason'], 'unreadable_or_invalid_manifest')
                self.assertNotIn(url, history['responses'])

    def test_changed_candidate_or_frozen_algorithm_during_replay_invalidates_gate(self):
        for target in (Path(self.files[next(iter(self.files))]['path']),
                       self.root / 'artifacts/publication/legacy-checker/lib/util/update_checker.dart'):
            original = target.read_bytes()
            def mutate(*args, **kwargs):
                raw = self.executor(*args, **kwargs)
                target.write_bytes(b'drift')
                return raw
            with self.subTest(target=target.name), self.assertRaises(feed.ReleaseError):
                self.run_gate(mutate)
            target.write_bytes(original)

    def public_candidate(self):
        self.state.update(releaseId=55, published=True)
        row = {'id': 55, 'tag_name': self.state['tag'], 'name': 'JMS ' + self.state['version'],
               'body': self.state['notes'], 'draft': False, 'prerelease': self.state['prerelease'],
               'published_at': '2026-10-30T00:00:00Z', 'assets': []}
        for name, value in self.files.items():
            row['assets'].append({'name': name, 'state': 'uploaded', 'size': value['size'],
                'digest': 'sha256:' + value['sha256'], 'browser_download_url': asset_url(self.state['tag'], name)})
        self.bodies[asset_url(self.state['tag'], 'update.json')] = Path(self.files['update.json']['path']).read_bytes()
        return row

    def test_exact_already_public_resume_replays_real_history_without_prepend_or_replacement(self):
        self.history = [self.public_candidate()]
        original = copy.deepcopy(self.history)
        fixture = feed.build_prospective_fixture(self.state, self.files, feed.snapshot_history(self.reader))
        self.assertTrue(fixture['candidateAlreadyPublic'])
        self.assertEqual(fixture['releases'], original)
        self.assertEqual(len(fixture['releases']), 1)
        self.assertEqual(fixture['candidateOrdering'], 'observed-public-page')
        self.assertTrue(fixture['candidatePlacementVerified'])

    def test_public_resume_identity_assets_or_actual_manifest_mismatch_refused(self):
        for change in ('id', 'channel', 'notes', 'digest', 'size', 'duplicate', 'manifest'):
            row = self.public_candidate()
            if change == 'id': row['id'] = 999
            if change == 'channel': row['prerelease'] = not row['prerelease']
            if change == 'notes': row['body'] = 'different'
            if change == 'digest': row['assets'][0]['digest'] = None
            if change == 'size': row['assets'][0]['size'] += 1
            if change == 'duplicate': row['assets'].append(copy.deepcopy(row['assets'][0]))
            self.history = [row]
            history = feed.snapshot_history(self.reader)
            if change == 'manifest':
                history['responses'][asset_url(self.state['tag'], 'update.json')]['body'] += ' '
            with self.subTest(change=change), self.assertRaises(feed.ReleaseError):
                feed.build_prospective_fixture(self.state, self.files, history)

    def test_published_missing_from_history_and_unknown_public_tag_cannot_be_recreated(self):
        self.state['published'] = True
        with self.assertRaisesRegex(feed.ReleaseError, 'absent'):
            feed.build_prospective_fixture(self.state, self.files, feed.snapshot_history(self.reader))
        self.history = [self.public_candidate()]
        self.state.pop('releaseId')
        with self.assertRaisesRegex(feed.ReleaseError, 'immutable state'):
            feed.build_prospective_fixture(self.state, self.files, feed.snapshot_history(self.reader))

    def test_leading_partial_draft_requires_exact_fresh_identity_and_public_order(self):
        draft = self.public_candidate()
        self.state['published'] = False
        draft.update(draft=True, target_commitish=self.state['sourceCommit'])
        draft['assets'] = draft['assets'][:1]
        history = feed.snapshot_history(self.reader)
        fixture = feed.build_prospective_fixture(self.state, self.files, history,
                                                  authenticated_history=[draft])
        self.assertEqual(len(fixture['releases']), 1)
        self.assertFalse(fixture['candidateAlreadyPublic'])
        self.assertEqual(fixture['candidateOrdering'], 'observed-leading-draft')
        self.assertTrue(fixture['candidatePlacementVerified'])
        with self.assertRaisesRegex(feed.ReleaseError, 'fresh authenticated placement'):
            feed.build_prospective_fixture(self.state, self.files, history)
        public = self.manual_release()
        self.history = [public]
        with self.assertRaisesRegex(feed.ReleaseError, 'Older draft placement'):
            feed.build_prospective_fixture(self.state, self.files, feed.snapshot_history(self.reader),
                                             authenticated_history=[public, draft])

    def test_draft_resume_snapshot_drift_or_asset_mismatch_is_not_repaired(self):
        draft = self.public_candidate()
        self.state['published'] = False
        draft.update(draft=True, target_commitish=self.state['sourceCommit'])
        for change in ('notes', 'asset', 'public-snapshot'):
            row = copy.deepcopy(draft)
            if change == 'notes': row['body'] = 'different'
            if change == 'asset': row['assets'][0]['digest'] = None
            rows = [row]
            if change == 'public-snapshot': rows.append(self.manual_release())
            with self.subTest(change=change), self.assertRaises(feed.ReleaseError):
                feed.build_prospective_fixture(self.state, self.files, feed.snapshot_history(self.reader),
                                                 authenticated_history=rows)

    def test_upload_placement_gate_refuses_a_new_release_first_assumption(self):
        self.assertEqual(self.run_gate()['status'], 'PASS')
        self.executed.clear()
        with self.assertRaisesRegex(feed.ReleaseError, 'placement is unproven'):
            self.run_gate(require_placement=True)
        self.assertEqual(self.executed, [])
        latest = json.loads((self.state_dir / 'feed-preflight-latest.json').read_text())
        report = json.loads((self.state_dir / latest['report']).read_text())
        self.assertEqual(latest['status'], 'BLOCKED')
        self.assertEqual(report['preflightPhase'], 'placement-required')
        self.assertFalse(report['publicationPlacementGateSatisfied'])

    def test_upload_placement_gate_observes_leading_draft_twice(self):
        draft = self.public_candidate()
        self.state['published'] = False
        draft.update(draft=True, target_commitish=self.state['sourceCommit'])
        draft['assets'] = []
        authenticated = Mock(return_value=[draft])
        report = self.run_gate(require_placement=True, authenticated_history=authenticated)
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(report['preflightPhase'], 'placement-required')
        self.assertTrue(report['publicationPlacementGateSatisfied'])
        self.assertEqual(authenticated.call_count, 2)

    def test_upload_placement_gate_rejects_draft_change_at_replay_bookend(self):
        draft = self.public_candidate()
        self.state['published'] = False
        draft.update(draft=True, target_commitish=self.state['sourceCommit'])
        changed = dict(draft, body='changed while the checker replayed')
        authenticated = Mock(side_effect=[[draft], [changed]])
        with self.assertRaisesRegex(feed.ReleaseError, 'identity/channel/source/notes differ'):
            self.run_gate(require_placement=True, authenticated_history=authenticated)
        self.assertEqual(authenticated.call_count, 2)

    def test_publisher_preview_precedes_push_and_verified_placement_precedes_upload(self):
        nodes = sorted((n for n in ast.walk(ast.parse(inspect.getsource(publisher.publish)))
                        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)),
                       key=lambda n: (n.lineno, n.col_offset))
        gates = [n for n in nodes if n.func.id == 'preflight_android_feed']
        self.assertEqual(len(gates), 2)
        actual_push = next(n for n in nodes if n.func.id == 'push_release'
                           and not any(k.arg == 'dry_run' for k in n.keywords))
        upload = next(n for n in nodes if n.func.id == 'upload_complete_release')
        self.assertLess(gates[0].lineno, actual_push.lineno)
        self.assertLess(actual_push.lineno, gates[1].lineno)
        self.assertLess(gates[1].lineno, upload.lineno)
        self.assertFalse(any(k.arg == 'require_placement' for k in gates[0].keywords))
        self.assertTrue(next(k.value.value for k in gates[1].keywords if k.arg == 'require_placement'))

    def test_public_history_change_during_replay_blocks_before_write(self):
        calls = 0
        def changing(url, limit):
            nonlocal calls
            if url == feed.FEED_URL:
                calls += 1
                if calls == 2:
                    self.history.append(self.manual_release())
            return self.reader(url, limit)
        with self.assertRaisesRegex(feed.ReleaseError, 'history changed during offline replay'):
            self.run_gate(reader=changing)

    def test_only_irrelevant_download_counters_may_change_in_live_bookend(self):
        self.history = [self.public_candidate()]
        calls = 0
        def counting(url, limit):
            nonlocal calls
            if url == feed.FEED_URL:
                calls += 1
                if calls == 2:
                    self.history[0]['assets'][0]['download_count'] = 42
            return self.reader(url, limit)
        report = self.run_gate(reader=counting)
        self.assertEqual(report['status'], 'PASS')
        self.assertNotEqual(report['publicHistorySha256'], report['livePublicHistorySha256'])

    def test_missing_matrix_case_or_network_report_cannot_authorize_publication(self):
        def invalid(*args, **kwargs):
            row = json.loads(self.executor(*args, **kwargs))
            row['networkRequestsIssued'] = 1
            return encoded(row)
        with self.assertRaisesRegex(feed.ReleaseError, 'Offline'):
            self.run_gate(invalid)
        with self.assertRaisesRegex(feed.ReleaseError, 'Complete four'):
            feed.matrix_decision([], {'historyIssues': [], 'candidateVersionCode': 2064}, False)

    def test_failed_real_publisher_flow_performs_zero_remote_writes_and_preserves54_state(self):
        self.state['prerelease'] = True
        self.history = [self.manual_release()]
        native = self.root / 'native.json'
        native.write_bytes(encoded({'materials': []}))
        self.policy['nativeEvidence'] = {'path': 'native.json', 'sha256': feed.sha256(native)}
        (self.root / 'config/jms_publication.json').write_bytes(encoded(self.policy))
        state_path = self.state_dir / 'state.json'
        state_path.write_bytes(encoded(self.state))
        old54 = self.state_dir.parent / 'v0.11.1-jms.54/state.json'
        old54.parent.mkdir()
        old_bytes = encoded({'published': True, 'anonymousVerified': None, 'lastError': 'original legacy failure'})
        old54.write_bytes(old_bytes)
        record = {'sourceCommit': 'a' * 40, 'buildId': 'synthetic-build', 'publicationSnapshot': True, 'inputs': []}
        record_path = self.root / 'artifacts/checks/build-0.11.1-jms.55-inputs.json'
        record_path.write_bytes(encoded(record))
        github = Mock()
        github.authenticate.return_value = {'permissions': {'push': True}}
        github.releases.return_value = copy.deepcopy(self.history)
        def apk_info(path, sdk):
            return ({'versionCode': 2008 if Path(path).name == 'baseline.apk' else 2064,
                     'versionName': self.state['version']}, publisher.SIGNER, None, None, None)
        def gated(root, state, files, directory, execute, **kwargs):
            return feed.preflight_android_feed(root, state, files, directory, self.executor, reader=self.reader)
        patches = {'ROOT': self.root, 'PUBLICATION': self.state_dir.parent,
                   'committed_source': Mock(return_value='a' * 40), 'check_upstream': Mock(),
                   'execute': Mock(return_value=b''), 'verify_legacy_checker': Mock(),
                   'Github': Mock(return_value=github), 'source_files': Mock(return_value={}),
                   'version_info': Mock(return_value=(self.state['version'], 2064)),
                   'bind_candidate_record': Mock(return_value=record),
                   'source_fingerprint': Mock(return_value='fingerprint'),
                   'push_release': Mock(), 'quality_checks': Mock(return_value={'status': 'PASS'}),
                   'publication_gates': Mock(return_value=[]), 'apk_info': apk_info,
                   'evidence_file': lambda reference: self.root / reference['path'],
                   'verify_build_record': Mock(), 'require_bound_sources': Mock(), 'verify_snapshot': Mock(),
                   'verify_package': Mock(return_value=self.manifest), 'release_files': Mock(return_value=self.files),
                   'verify_asset_privacy': Mock(), 'preflight_android_feed': gated,
                   'upload_complete_release': Mock(), 'verify_remote': Mock()}
        # Existing package directory avoids exercising an unrelated build helper.
        (self.root / 'artifacts/releases/synthetic-build').mkdir(parents=True)
        with ExitStack() as stack:
            for name, value in patches.items():
                stack.enter_context(patch.object(publisher, name, value))
            with self.assertRaisesRegex(feed.ReleaseError, 'Prospective Android feed incompatible'):
                publisher.publish(argparse.Namespace(channel='prerelease', dry_run=False))
        self.assertEqual(github.api.call_count, 0)
        self.assertEqual(github.call.call_count, 0)
        self.assertEqual(patches['upload_complete_release'].call_count, 0)
        self.assertEqual(patches['verify_remote'].call_count, 0)
        self.assertTrue(all(call.kwargs.get('dry_run') is True for call in patches['push_release'].call_args_list))
        self.assertEqual(old54.read_bytes(), old_bytes)


if __name__ == '__main__':
    unittest.main()
