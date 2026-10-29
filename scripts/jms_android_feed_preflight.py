"""Fail closed on prospective Android updater incompatibility before public writes.

All network I/O is anonymous GET. Both real checker implementations execute
against a local MockClient replay; historical releases/manifests are never edited.
"""
from __future__ import annotations

import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid

from jms_publication import ReleaseError, SafeRedirect, allowed_url, save_json, sha256

REPOSITORY = 'jim608/JMS-Android'
FEED_URL = 'https://api.github.com/repos/' + REPOSITORY + '/releases?per_page=20'
MAX_MANIFEST = 65536


def require(value, reason):
    if not value:
        raise ReleaseError(reason)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate feed JSON field')
        result[key] = value
    return result


def json_bytes(raw):
    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)


def owned_asset_url(url, tag, name):
    if not isinstance(url, str) or not allowed_url(url, repository=REPOSITORY):
        return False
    parts = urllib.parse.urlsplit(url).path.split('/')[1:]
    return (urllib.parse.unquote(parts[4]) == tag
            and urllib.parse.unquote(parts[5]) == name
            and all('/' not in urllib.parse.unquote(p) and '\\' not in urllib.parse.unquote(p)
                    for p in parts))


def read_anonymous(url, limit):
    require(url == FEED_URL or allowed_url(url, repository=REPOSITORY),
            'Prospective feed GET outside exact repository')
    request = urllib.request.Request(url, headers={
        'User-Agent': 'JMS-Android-feed-preflight', 'Accept': 'application/vnd.github+json'
        if url == FEED_URL else 'application/json', 'Cache-Control': 'no-cache'})
    # No cookie processor, authorization, GH token or credential helper is used.
    opener = urllib.request.build_opener(SafeRedirect())
    with opener.open(request, timeout=30) as response:
        raw = response.read(limit + 1)
        require(response.status == 200 and len(raw) <= limit,
                'Public feed response exceeded bound or was not HTTP200')
    return raw


def history_binding(releases):
    require(isinstance(releases, list) and len(releases) <= 20,
            'Public history bookend exceeds exact first-page bound')
    # Public download counters are volatile and ignored by both checkers. Bind
    # every field that selects/validates a release plus asset identities/digests.
    rows = []
    for release in releases:
        require(isinstance(release, dict) and isinstance(release.get('assets'), list),
                'Public history bookend has invalid shape')
        row = {k: release.get(k) for k in ('id', 'tag_name', 'draft', 'prerelease', 'name',
                                          'body', 'published_at', 'created_at', 'target_commitish')}
        row['assets'] = [{k: a.get(k) for k in ('id', 'name', 'state', 'size', 'digest', 'browser_download_url')}
                         for a in release['assets']]
        rows.append(row)
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def snapshot_history(reader=read_anonymous):
    raw = reader(FEED_URL, 2 * 1024 * 1024)
    releases = json_bytes(raw)
    require(isinstance(releases, list) and len(releases) <= 20,
            'Expected exact bounded public first-page release history')
    responses, issues, seen = {}, [], set()
    for release in releases:
        require(isinstance(release, dict) and type(release.get('draft')) is bool
                and type(release.get('prerelease')) is bool,
                'Public history has invalid release/channel shape')
        tag, assets = release.get('tag_name'), release.get('assets')
        require(isinstance(tag, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,199}', tag)
                and tag not in seen and isinstance(assets, list), 'Unsafe or duplicate history tag/assets')
        seen.add(tag)
        for asset in assets:
            require(isinstance(asset, dict) and isinstance(asset.get('name'), str)
                    and owned_asset_url(asset.get('browser_download_url'), tag, asset['name']),
                    'Public history asset URL/name escapes its release')
        if release['draft']:
            continue
        metadata = [a for a in assets if a.get('name') == 'update.json' and a.get('state') == 'uploaded']
        if len(metadata) != 1:
            issues.append({'tag': tag, 'reason': 'missing_or_duplicate_manifest'})
            continue
        asset = metadata[0]
        if type(asset.get('size')) is not int or not 0 < asset['size'] <= MAX_MANIFEST:
            issues.append({'tag': tag, 'reason': 'invalid_manifest_size'})
            continue
        url = asset['browser_download_url']
        try:
            body = reader(url, MAX_MANIFEST)
            require(len(body) == asset['size'], 'History manifest byte size differs')
            if asset.get('digest') is not None:
                require(asset['digest'] == 'sha256:' + hashlib.sha256(body).hexdigest(),
                        'History manifest GitHub digest differs')
            value = json_bytes(body)
            require(isinstance(value, dict), 'History manifest is not an object')
        except (ValueError, UnicodeError, urllib.error.URLError, OSError) as error:
            issues.append({'tag': tag, 'reason': 'unreadable_or_invalid_manifest',
                           'errorType': type(error).__name__})
            # A missing/error response remains missing in MockClient, not repaired.
            continue
        responses[url] = {'statusCode': 200, 'body': body.decode('utf-8')}
    return {'releases': releases, 'responses': responses, 'historyIssues': issues,
            'publicHistorySha256': hashlib.sha256(raw).hexdigest(),
            'historyBindingSha256': history_binding(releases)}


def candidate_bindings(state, files):
    require(type(state.get('versionCode')) is int and state['versionCode'] > 2008,
            'Prospective candidate must upgrade the actual installed2008 baseline')
    result = {}
    for name, asset in files.items():
        path = Path(asset['path'])
        require(path.is_file() and not path.is_symlink() and not path.is_junction()
                and path.name == name and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', name),
                'Candidate feed assets require safe regular matching files')
        require(path.stat().st_size == asset['size'] and sha256(path) == asset['sha256'],
                'Candidate feed asset bytes changed')
        result[name] = {'size': asset['size'], 'sha256': asset['sha256']}
    require('update.json' in files, 'Candidate has no updater manifest')
    raw = Path(files['update.json']['path']).read_bytes()
    require(0 < len(raw) <= MAX_MANIFEST, 'Candidate manifest exceeds updater bound')
    manifest = json_bytes(raw)
    require(isinstance(manifest, dict) and manifest.get('applicationId') == 'com.jim608.jms'
            and manifest.get('versionCode') == state['versionCode']
            and manifest.get('versionName') == state['version']
            and manifest.get('sourceCommit') == state['sourceCommit'],
            'Candidate manifest identity differs from immutable publication state')
    for key in ('apk', 'source'):
        row = manifest.get(key)
        require(isinstance(row, dict) and row.get('name') in result
                and {k: row.get(k) for k in ('size', 'sha256')} == result[row['name']],
                'Candidate manifest does not bind its APK/source bytes')
    return result, raw


def verify_leading_draft(state, bindings, history, authenticated_history):
    require(isinstance(authenticated_history, list), 'Draft resume requires a fresh authenticated placement snapshot')
    candidates = [r for r in authenticated_history if r.get('id') == state['releaseId']]
    require(len(candidates) == 1, 'Draft resume identity missing or ambiguous')
    draft = candidates[0]
    require(draft.get('draft') is True and draft.get('tag_name') == state['tag']
            and draft.get('prerelease') is state['prerelease'] and draft.get('name') == 'JMS ' + state['version']
            and draft.get('body') == state['notes'] and draft.get('target_commitish') == state['sourceCommit'],
            'Draft resume identity/channel/source/notes differ')
    public = [r for r in authenticated_history if r.get('draft') is False]
    require(history_binding(public[:20]) == history['historyBindingSha256'],
            'Authenticated draft placement and anonymous public history disagree')
    relevant = [r for r in authenticated_history if r.get('draft') is False or r.get('id') == state['releaseId']]
    require(relevant and relevant[0].get('id') == state['releaseId'],
            'Older draft placement is unproven; do not assume it becomes the first public release')
    assets = draft.get('assets')
    require(isinstance(assets, list) and len({a.get('name') for a in assets}) == len(assets),
            'Draft resume has duplicate assets')
    for asset in assets:
        name = asset.get('name')
        require(name in bindings and asset.get('state') == 'uploaded'
                and asset.get('size') == bindings[name]['size']
                and asset.get('digest') == 'sha256:' + bindings[name]['sha256']
                and owned_asset_url(asset.get('browser_download_url'), state['tag'], name),
                'Draft resume current asset size/digest differs')


def build_prospective_fixture(state, files, history, *, authenticated_history=None):
    bindings, raw = candidate_bindings(state, files)
    tag = state['tag']
    require(tag == 'v' + state['version'] and type(state.get('prerelease')) is bool,
            'Candidate tag/channel differs from actual version')
    matching = [row for row in history['releases'] if row['tag_name'] == tag]
    require(len(matching) <= 1, 'Duplicate public candidate release')
    already_public = bool(matching)
    if already_public:
        existing = matching[0]
        require(type(state.get('releaseId')) is int and state['releaseId'] > 0
                and existing.get('id') == state['releaseId'] and existing.get('draft') is False
                and existing.get('prerelease') is state['prerelease']
                and existing.get('name') == 'JMS ' + state['version']
                and existing.get('body') == state['notes'],
                'Public resume identity/channel/notes differ from immutable state')
        assets = existing['assets']
        require(len(assets) == len(bindings) and {a.get('name') for a in assets} == set(bindings),
                'Public resume assets differ from immutable candidate')
        for asset in assets:
            expected = bindings[asset['name']]
            require(asset.get('state') == 'uploaded' and asset.get('size') == expected['size']
                    and asset.get('digest') == 'sha256:' + expected['sha256']
                    and owned_asset_url(asset.get('browser_download_url'), tag, asset['name']),
                    'Public resume current asset size/digest differs')
        metadata = next(a for a in assets if a['name'] == 'update.json')
        response = history['responses'].get(metadata['browser_download_url'])
        require(isinstance(response, dict) and response.get('statusCode') == 200
                and response.get('body') == raw.decode('utf-8'),
                'Public resume actual manifest bytes differ')
    else:
        require(state.get('published') is not True,
                'Published candidate absent from bounded history; do not recreate or hide history')
        if state.get('releaseId') is not None:
            verify_leading_draft(state, bindings, history, authenticated_history)
    candidate = {'tag_name': tag, 'name': 'JMS ' + state['version'], 'body': state['notes'],
                 'draft': False, 'prerelease': state['prerelease'],
                 'published_at': datetime.now(timezone.utc).isoformat(),
                 'html_url': 'https://github.com/' + REPOSITORY + '/releases/tag/' + tag,
                 'assets': [{'name': name, **binding, 'state': 'uploaded',
                     'browser_download_url': 'https://github.com/' + REPOSITORY + '/releases/download/' + tag + '/' + name}
                    for name, binding in bindings.items()]}
    responses = copy.deepcopy(history['responses'])
    candidate_url = next(row['browser_download_url'] for row in candidate['assets'] if row['name'] == 'update.json')
    responses[candidate_url] = {'statusCode': 200, 'body': raw.decode('utf-8')}
    return {'schemaVersion': 1, 'repository': REPOSITORY, 'sourceUrl': FEED_URL,
            'installedVersionCode': 2008, 'candidateVersionCode': state['versionCode'],
            # The API page limit applies BEFORE either checker filters channels.
            # Keep the unmodified observed page separately for audit and retain all
            # historical integrity blockers, even for a legitimately displaced row.
            'releases': copy.deepcopy(history['releases']) if already_public
                else [candidate, *copy.deepcopy(history['releases'])][:20],
            'observedPublicReleases': copy.deepcopy(history['releases']),
            'displacedPublicReleases': [] if already_public
                else copy.deepcopy(history['releases'][19:]),
            'candidateOrdering': 'observed-public-page' if already_public else
                'observed-leading-draft' if state.get('releaseId') is not None else
                'new-release-first-assumption',
            'candidatePlacementVerified': already_public or state.get('releaseId') is not None,
            'responses': responses, 'historyIssues': copy.deepcopy(history['historyIssues']),
            'publicHistorySha256': history['publicHistorySha256'], 'candidateAssets': bindings,
            'historyBindingSha256': history['historyBindingSha256'],
            'candidateAlreadyPublic': already_public}


def matrix_decision(rows, fixture, prerelease):
    required = {'legacy8-prerelease', 'current-prerelease'}
    if not prerelease:
        required |= {'legacy8-stable', 'current-stable'}
    require(len(rows) == 4 and {row['case'] for row in rows} == {'legacy8-stable', 'legacy8-prerelease', 'current-stable', 'current-prerelease'},
            'Complete four-channel compatibility matrix required')
    blockers = list(fixture['historyIssues'])
    for row in rows:
        if row['case'] in required and (row.get('status') != 'available'
                or row.get('versionCode') != fixture['candidateVersionCode']):
            blockers.append({'case': row['case'], 'reason': 'candidate_not_available',
                             'status': row.get('status')})
    return blockers


def checker_tool_bindings(root, packages, harness):
    policy_path = root / 'config/jms_publication.json'
    policy = json_bytes(policy_path.read_bytes())
    record_path = root / policy['baselineBuildRecord']
    require(record_path.resolve().is_relative_to(root.resolve())
            and sha256(record_path) == policy['baselineBuildRecordSha256'],
            'Frozen baseline source record changed')
    baseline = json_bytes(record_path.read_bytes())
    require(baseline.get('version') == '0.11.1-jms.8' and baseline.get('baseVersionCode') == 8,
            'Frozen source record is not installed8')
    expected = {row['path']: row['sha256'] for row in baseline['inputs']}
    bindings = {'harness': sha256(harness), 'module': sha256(Path(__file__)),
                'publicationPolicy': sha256(policy_path), 'baselineBuildRecord': sha256(record_path)}
    for verifier, config_path in packages.items():
        config = json_bytes(config_path.read_bytes())
        matches = [p for p in config['packages'] if p.get('name') == 'fladder']
        require(len(matches) == 1, 'Exactly one checker package binding required')
        uri = urllib.parse.urlsplit(urllib.parse.urljoin(config_path.resolve().as_uri(), matches[0]['rootUri']))
        require(uri.scheme == 'file' and not uri.netloc and not uri.query and not uri.fragment,
                'Checker package root must be a local file URI')
        checkout = Path(urllib.request.url2pathname(uri.path)).resolve()
        wanted = root.resolve() if verifier == 'current' else (root / 'artifacts/publication/legacy-checker').resolve()
        require(checkout == wanted, 'Checker package points outside its expected source tree')
        bindings[verifier + 'Packages'] = sha256(config_path)
        for name in ('lib/util/update_checker.dart', 'lib/util/update_source.dart', 'lib/util/brand.dart'):
            path = checkout / name
            require(path.is_file() and not path.is_symlink() and not path.is_junction(),
                    'Checker source must be a regular local file')
            value = sha256(path)
            if verifier == 'legacy8':
                require(value == expected.get(name), 'Frozen .8 algorithm source changed')
            bindings[verifier + ':' + name] = value
    return bindings


def preflight_android_feed(root, state, files, state_directory, execute, *, reader=read_anonymous,
                           authenticated_history=None, require_placement=False):
    root, state_directory = Path(root), Path(state_directory)
    output = state_directory / ('feed-preflight-' + uuid.uuid4().hex)
    output.mkdir()
    state_binding = {k: state.get(k) for k in ('tag', 'version', 'versionCode', 'sourceCommit',
                                               'notes', 'prerelease', 'releaseId', 'published')}
    before, _ = candidate_bindings(state, files)
    history = snapshot_history(reader)
    draft_snapshot = None
    if state.get('releaseId') is not None and not any(r['tag_name'] == state['tag'] for r in history['releases']):
        require(callable(authenticated_history), 'Draft resume requires the existing GET-only repository client')
        draft_snapshot = authenticated_history()
    fixture = build_prospective_fixture(state, files, history, authenticated_history=draft_snapshot)
    fixture['preflightPhase'] = 'placement-required' if require_placement else 'pre-write-preview'
    fixture['placementRequired'] = require_placement
    fixture_path = output / 'prospective-feed.json'
    save_json(fixture_path, fixture)
    if require_placement and not fixture['candidatePlacementVerified']:
        # Do not leave a successful preview as the latest receipt when the
        # stronger upload gate refuses its still-unverified ordering assumption.
        save_json(output / 'report.json', {
            'status': 'BLOCKED', 'repository': REPOSITORY, 'candidateTag': state['tag'],
            'preflightPhase': fixture['preflightPhase'], 'placementRequired': True,
            'candidateOrdering': fixture['candidateOrdering'], 'candidatePlacementVerified': False,
            'publicationPlacementGateSatisfied': False, 'remoteWritesPerformed': False,
            'blockers': [{'reason': 'unverified_candidate_api_placement'}]})
        save_json(state_directory / 'feed-preflight-latest.json', {
            'status': 'BLOCKED', 'report': output.name + '/report.json',
            'reportSha256': sha256(output / 'report.json')})
        raise ReleaseError('Candidate API placement is unproven; require an exact observed leading draft or public release before upload')
    fixture_hash = sha256(fixture_path)
    harness = root / 'scripts/check_jms_legacy_feed.dart'
    packages = {'legacy8': root / 'artifacts/publication/legacy-checker/package_config.json',
                'current': root / '.dart_tool/package_config.json'}
    tools = checker_tool_bindings(root, packages, harness)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
        environment.pop(name, None)
    rows = []
    for verifier, package in packages.items():
        for channel in ('stable', 'prerelease'):
            case = verifier + '-' + channel
            command = [root / '.jms-tools/flutter/bin/dart.bat', '--packages=' + str(package),
                       'scripts/check_jms_legacy_feed.dart', '--history-fixture=' + str(fixture_path),
                       '--' + channel, '--report-only']
            raw = execute(command, environment=environment, log=output / (case + '.log'), timeout=120)
            row = json_bytes(raw.strip())
            require(isinstance(row, dict) and row.get('mode') == 'prospective-fixture'
                    and row.get('channel') == channel and row.get('installedVersionCode') == 2008
                    and row.get('networkRequestsIssued') == 0, 'Offline compatibility checker report differs')
            rows.append(dict(row, case=case))
    after, _ = candidate_bindings(state, files)
    require(before == after and sha256(fixture_path) == fixture_hash
            and state_binding == {k: state.get(k) for k in state_binding}
            and tools == checker_tool_bindings(root, packages, harness),
            'Candidate/history fixture/checker bindings changed during replay')
    live_history_raw = reader(FEED_URL, 2 * 1024 * 1024)
    require(history_binding(json_bytes(live_history_raw)) == history['historyBindingSha256'],
            'Public release history changed during offline replay; refresh and re-review before any write')
    if require_placement and not fixture['candidateAlreadyPublic']:
        # The initial draft snapshot only proves its placement at the start of
        # replay. Re-read the existing GET-only client before upload so a draft
        # edit, asset change or public-order change cannot survive this gate.
        verify_leading_draft(state, after, history, authenticated_history())
    blockers = matrix_decision(rows, fixture, state['prerelease'])
    report = {'status': 'BLOCKED' if blockers else 'PASS', 'repository': REPOSITORY,
              'candidateVersionCode': state['versionCode'], 'candidateTag': state['tag'],
              'candidateSourceCommit': state['sourceCommit'], 'candidateAssets': before,
              'publicHistorySha256': history['publicHistorySha256'], 'historyRows': len(history['releases']),
              'historyBindingSha256': history['historyBindingSha256'],
              'livePublicHistorySha256': hashlib.sha256(live_history_raw).hexdigest(),
              'prospectiveRows': len(fixture['releases']), 'fixtureSha256': fixture_hash,
              'observedPublicRows': len(fixture['observedPublicReleases']),
              'displacedPublicRows': len(fixture['displacedPublicReleases']),
              'candidateOrdering': fixture['candidateOrdering'],
              'candidatePlacementVerified': fixture['candidatePlacementVerified'],
              'preflightPhase': fixture['preflightPhase'],
              'placementRequired': require_placement,
              'publicationPlacementGateSatisfied': require_placement and fixture['candidatePlacementVerified'],
              'toolBindings': tools, 'matrix': rows, 'blockers': blockers,
              'legacyOptInManualBootstrapMayBeRequired': any(row['case'] == 'legacy8-prerelease'
                  and (row.get('status') != 'available' or row.get('versionCode') != state['versionCode']) for row in rows),
              'policyWaiverGranted': False, 'remoteWritesPerformed': False,
              'deviceAcceptance': False, 'checkedAtUtc': datetime.now(timezone.utc).isoformat()}
    save_json(output / 'report.json', report)
    save_json(state_directory / 'feed-preflight-latest.json', {
        'status': report['status'], 'report': output.name + '/report.json', 'reportSha256': sha256(output / 'report.json')})
    require(not blockers, 'Prospective Android feed incompatible; see local feed-preflight-latest.json. '
            'Legacy opt-in bootstrap/history support remains unresolved; no policy waiver or public write.')
    return report
