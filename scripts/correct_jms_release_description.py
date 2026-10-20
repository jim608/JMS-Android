"""Revise public release prose without changing a published candidate or its assets."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from jms_publication import Github, ReleaseError
from jms_release_notes import release_notes_for, release_body_for_candidate, validate_release_notes


ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {
    'android': ('jim608/JMS-Android', 'update.json'),
    'windows': ('jim608/JMS-Desktop', 'update.json'),
    'linux': ('jim608/JMS-Linux', 'update-linux.json'),
}
MAX_JSON = 4 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _public_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443)
            or parsed.hostname not in {'github.com', 'api.github.com', 'release-assets.githubusercontent.com',
                                       'objects.githubusercontent.com'}):
        raise ReleaseError('Anonymous readback must remain on authorized GitHub HTTPS hosts')


class _GithubRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        _public_url(newurl)
        return super().redirect_request(request, fp, code, message, headers, newurl)


def anonymous_bytes(url, maximum):
    _public_url(url)
    request = urllib.request.Request(url, headers={
        'User-Agent': 'JMS-release-description-readback',
        'Accept': 'application/vnd.github+json' if urllib.parse.urlsplit(url).hostname == 'api.github.com'
                  else 'application/octet-stream',
        'Cache-Control': 'no-cache', 'Pragma': 'no-cache',
    })
    try:
        with urllib.request.build_opener(_GithubRedirect()).open(request, timeout=60) as response:
            _public_url(response.url)
            if response.status != 200:
                raise ReleaseError('Anonymous readback did not return HTTP 200')
            data = response.read(maximum + 1)
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ReleaseError('Anonymous GitHub readback failed; no remote correction can be confirmed') from None
    if not data or len(data) > maximum:
        raise ReleaseError('Anonymous JSON exceeds its bounded size')
    return data


def release_snapshot(release, version, expected_asset_count=None):
    if (type(release.get('id')) is not int or release['id'] <= 0
            or release.get('tag_name') != 'v' + version or release.get('draft') is not False
            or release.get('prerelease') is not True or not release.get('target_commitish')):
        raise ReleaseError('Expected an existing public JMS prerelease with the exact identity')
    assets = []
    names, identifiers = set(), set()
    for asset in release.get('assets', []):
        name, identifier = asset.get('name'), asset.get('id')
        if (not isinstance(name, str) or not name or '/' in name or '\\' in name
                or name in {'.', '..'} or name in names or type(identifier) is not int or identifier <= 0
                or identifier in identifiers or type(asset.get('size')) is not int or asset['size'] <= 0
                or asset.get('state') != 'uploaded' or not isinstance(asset.get('digest'), str)
                or not re.fullmatch(r'sha256:[a-f0-9]{64}', asset['digest'])):
            raise ReleaseError('Published assets are incomplete, ambiguous or lack an exact SHA256')
        names.add(name)
        identifiers.add(identifier)
        assets.append({key: asset[key] for key in ('id', 'name', 'size', 'digest')})
    if not assets or expected_asset_count is not None and len(assets) != expected_asset_count:
        raise ReleaseError('Published asset count differs from the reviewed release')
    assets.sort(key=lambda item: item['id'])
    # Canonical identity is UTF-8 JSON, sorted keys, compact separators, assets sorted by numeric id.
    assets_hash = digest(json.dumps(assets, sort_keys=True, separators=(',', ':')).encode('utf-8'))
    return {
        'id': release['id'], 'tagName': release['tag_name'], 'targetCommitish': release['target_commitish'],
        'draft': False, 'prerelease': True, 'assetCount': len(assets), 'assetsSha256': assets_hash, 'assets': assets,
    }


def _manifest(release, platform, version, source_commit, fetch):
    repository, manifest_name = PLATFORMS[platform]
    asset = next((item for item in release['assets'] if item['name'] == manifest_name), None)
    if asset is None or asset['size'] > 1024 * 1024:
        raise ReleaseError('Published update manifest is missing or too large')
    url = f'https://github.com/{repository}/releases/download/v{version}/{manifest_name}'
    if asset.get('browser_download_url') != url:
        raise ReleaseError('Manifest download URL differs from its exact public release')
    data = fetch(url, 1024 * 1024)
    if len(data) != asset['size'] or 'sha256:' + digest(data) != asset['digest']:
        raise ReleaseError('Published manifest size/SHA256 differs from release metadata')
    manifest = json.loads(data)
    if (manifest.get('schemaVersion') != 1 or manifest.get('applicationId') != 'com.jim608.jms'
            or manifest.get('versionName') != version or manifest.get('sourceCommit') != source_commit
            or type(manifest.get('versionCode')) is not int or manifest['versionCode'] <= 0):
        raise ReleaseError('Published manifest differs from the expected candidate identity')
    if platform == 'android':
        expected_name = f'JMS-Android-{version}-release-arm64-test-signed.apk'
        if manifest.get('abis') != ['arm64-v8a'] or manifest.get('platform') not in (None, 'android-arm64'):
            raise ReleaseError('Published Android manifest has an unexpected platform/ABI')
        expected_build = r'JMS-' + re.escape(version) + r'-[a-f0-9]{12}'
        payload_key = 'apk'
        source_name = f'JMS-{version}-source.zip'
    else:
        if manifest.get('platform') != platform + '-x64':
            raise ReleaseError('Published desktop manifest has an unexpected platform')
        expected_build = re.escape(f'JMS-{version}-{platform}-{source_commit[:12]}')
        payload_key = 'installer'
        expected_name = (f'JMS-Windows-{version}-x64-setup.exe' if platform == 'windows'
                         else f'JMS-Linux-{version}-x86_64.pkg.tar.xz')
        source_name = f'JMS-Windows-{version}-source.zip' if platform == 'windows' else f'JMS-{version}-source.zip'
    if not re.fullmatch(expected_build, manifest.get('buildId', '')):
        raise ReleaseError('Published Build ID differs from the exact platform candidate')
    for key, name in ((payload_key, expected_name), ('source', source_name)):
        item = manifest.get(key, {})
        remote = next((value for value in release['assets'] if value['name'] == name), None)
        if (item.get('name') != name or type(item.get('size')) is not int or remote is None
                or not re.fullmatch('[a-f0-9]{64}', item.get('sha256', ''))
                or item['size'] != remote['size'] or 'sha256:' + item['sha256'] != remote['digest']):
            raise ReleaseError('Published candidate payload/source binding is inconsistent')
    return manifest, {'name': manifest_name, 'size': len(data), 'sha256': digest(data)}


def _readback(release, snapshot, version, body, title):
    if release_snapshot(release, version) != snapshot:
        raise ReleaseError('Release identity or exact immutable asset set changed unexpectedly')
    if release.get('name') != title or release.get('body') != body:
        raise ReleaseError('Release description was not saved or anonymous readback is stale')


def _save_receipt(directory, receipt, name):
    if directory is None:
        return
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    preview = directory / 'body-preview.md'
    if preview.exists() and preview.read_bytes() != receipt['body'].encode('utf-8'):
        raise ReleaseError('Correction preview already exists with different content')
    if not preview.exists():
        with preview.open('xb') as stream:
            stream.write(receipt['body'].encode('utf-8'))
    receipt['preview'] = {'path': str(preview.resolve()), 'sha256': receipt['bodySha256']}
    path = directory / name
    payload = json.dumps(receipt, indent=2, ensure_ascii=False).encode('utf-8')
    if path.exists():
        if path.read_bytes() != payload:
            raise ReleaseError('Correction receipt already exists; preserve it and use a new run directory')
    else:
        with path.open('xb') as stream:
            stream.write(payload)


def correct_description(github, version, notes, apply=False, *, platform, source_commit, notes_revision_commit,
                        expected_build_id=None, expected_asset_count=None, approved_body_sha256=None,
                        receipt_directory=None, fetch=anonymous_bytes):
    if platform not in PLATFORMS or getattr(github, 'repository', None) != PLATFORMS[platform][0]:
        raise ReleaseError('Description correction is limited to the selected native platform repository')
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._+-]*', version):
        raise ReleaseError('Unsafe release version')
    if not all(re.fullmatch('[a-f0-9]{40}', value) for value in (source_commit, notes_revision_commit)):
        raise ReleaseError('Complete App source and notes revision commits are required separately')
    validate_release_notes(notes, version, require_english=True)
    repository = PLATFORMS[platform][0]
    endpoint = f'repos/{repository}/releases/tags/v{version}'
    public_endpoint = 'https://api.github.com/' + endpoint
    release = github.api(endpoint)
    before = release_snapshot(release, version, expected_asset_count)
    public_before = json.loads(fetch(public_endpoint, MAX_JSON))
    _readback(public_before, before, version, release.get('body'), release.get('name'))
    manifest, manifest_proof = _manifest(public_before, platform, version, source_commit, fetch)
    build_id = manifest['buildId']
    if expected_build_id is not None and build_id != expected_build_id:
        raise ReleaseError('Published Build ID differs from the reviewed expected value')
    # Keep the original candidate identity, including Android's opaque build hash.
    body = release_body_for_candidate(notes, version, source_commit, build_id)
    title = 'JMS ' + version
    footer = body[body.index('\n\n來源：'):]
    if not (release.get('body') or '').endswith(footer):
        raise ReleaseError('Existing public source/Build ID footer differs from the candidate')
    body_hash = digest(body.encode('utf-8'))
    if len(body) >= 20000:
        raise ReleaseError('Bilingual body and candidate footer must fit the updater 20000-character limit')
    if apply and approved_body_sha256 != body_hash:
        raise ReleaseError('Apply requires the exact reviewed dry-run body SHA256')
    expected_url = f'https://github.com/{repository}/releases/tag/v{version}'
    if release.get('html_url') != expected_url or public_before.get('html_url') != expected_url:
        raise ReleaseError('Release page URL differs from the selected repository/tag')
    changed = release.get('name') != title or release.get('body') != body
    receipt = {
        'schemaVersion': 1, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'status': 'dry-run' if changed else 'already-current', 'platform': platform, 'repository': repository,
        'version': version, 'sourceCommit': source_commit, 'buildId': build_id,
        'notesRevisionCommit': notes_revision_commit, 'releaseUrl': expected_url,
        'title': title, 'body': body, 'bodySha256': body_hash, 'manifest': manifest_proof,
        'releaseBefore': before, 'releaseAfter': before, 'immutableAssetsUnchanged': True,
        'remoteReadback': {'authenticated': True, 'anonymous': True,
                           'bodySha256': digest((release.get('body') or '').encode('utf-8')),
                           'title': release.get('name'), 'sourceFooterVerified': True},
    }
    _save_receipt(receipt_directory, receipt, 'pre-apply.json' if apply else 'dry-run.json')
    if apply and changed:
        updated = github.api(f'repos/{repository}/releases/{before["id"]}', 'PATCH', {'name': title, 'body': body})
        _readback(updated, before, version, body, title)
        current = github.api(endpoint)
        _readback(current, before, version, body, title)
        public_after = json.loads(fetch(public_endpoint, MAX_JSON))
        _readback(public_after, before, version, body, title)
        receipt.update(status='applied', releaseAfter=release_snapshot(public_after, version))
        receipt['remoteReadback'].update(bodySha256=body_hash, title=title)
    if apply or not changed:
        _save_receipt(receipt_directory, receipt, 'applied.json' if apply else 'already-current.json')
    return receipt


def main():
    parser = argparse.ArgumentParser(description='Correct native prerelease title/body only; default is a read-only dry-run')
    parser.add_argument('--platform', required=True, choices=tuple(PLATFORMS))
    parser.add_argument('--version', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--expected-build-id')
    parser.add_argument('--expected-asset-count', type=int)
    parser.add_argument('--approved-body-sha256')
    parser.add_argument('--receipt-directory', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    notes = release_notes_for(ROOT / 'CHANGELOG.md', args.version, require_english=True)
    from check_jms_git_privacy import findings, load_policy
    if findings('release-description.md', notes.encode('utf-8'), load_policy()):
        raise ReleaseError('Release description does not pass the existing local privacy policy')
    revision = subprocess.check_output(['rtk', 'proxy', 'git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch('[a-f0-9]{40}', revision):
        raise ReleaseError('Notes revision must be the complete current commit')
    for name in ('CHANGELOG.md', 'CHANGELOG.en.md', 'config/jms_release_notes.json',
                 'scripts/jms_release_notes.py', 'scripts/correct_jms_release_description.py',
                 'docs/JMS_RELEASE_NOTES.zh-Hant.md'):
        committed = subprocess.check_output(['rtk', 'proxy', 'git', 'show', revision + ':' + name], cwd=ROOT)
        if (ROOT / name).read_bytes() != committed:
            raise ReleaseError('Notes correction requires the exact committed canonical notes and tooling')
    directory = args.receipt_directory or ROOT / 'artifacts/notes-corrections' / args.platform / args.version / (
        datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    github = Github(repository=PLATFORMS[args.platform][0])
    github.authenticate()
    receipt = correct_description(
        github, args.version, notes, args.apply, platform=args.platform, source_commit=args.source_commit,
        notes_revision_commit=revision, expected_build_id=args.expected_build_id,
        expected_asset_count=args.expected_asset_count, approved_body_sha256=args.approved_body_sha256,
        receipt_directory=directory,
    )
    print(f'{receipt["releaseUrl"]}\nDescription {receipt["status"]}; receipt: {directory}')


if __name__ == '__main__':
    main()
