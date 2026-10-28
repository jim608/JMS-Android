"""Audit published Android version codes without changing historical releases.

Callers supply authenticated Github.releases() metadata and a trusted SDK. The
normal update.json path remains authoritative. Only a missing manifest permits
inspection of one unambiguous APK; names never establish its identity or code.
"""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from jms_publication import MAX_ASSET, SIGNER, ReleaseError, execute, sha256


APPLICATION_IDS = frozenset({'com.jim608.jms', 'com.jim608.jms.dev'})
MAX_VERSION_CODE = 2100000000
MAX_MANIFEST = 1024 * 1024


def _positive_integer(value, description, maximum=None):
    if type(value) is not int or value <= 0 or (maximum is not None and value > maximum):
        raise ReleaseError('Invalid historical ' + description)
    return value


def _asset_identity(asset, maximum):
    if not isinstance(asset, dict) or asset.get('state') != 'uploaded':
        raise ReleaseError('Historical asset is not completely uploaded')
    identity = _positive_integer(asset.get('id'), 'asset ID')
    size = _positive_integer(asset.get('size'), 'asset size', maximum)
    digest = asset.get('digest')
    if not isinstance(digest, str) or not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
        raise ReleaseError('Historical asset lacks an authenticated SHA256 digest')
    return identity, size, digest[7:].lower()


def history_asset_path(cache_directory, asset, *, apk=False):
    """Path for staging existing bytes; every use still verifies size and digest."""
    identity, _, digest = _asset_identity(asset, MAX_ASSET if apk else MAX_MANIFEST)
    return Path(cache_directory) / f'asset-{identity}-{digest}.{"apk" if apk else "json"}'


def _verified_asset(github, asset, cache_directory, *, apk=False):
    _, expected_size, expected_digest = _asset_identity(asset, MAX_ASSET if apk else MAX_MANIFEST)
    destination = history_asset_path(cache_directory, asset, apk=apk)

    def verify(path):
        if path.is_symlink() or not path.is_file():
            raise ReleaseError('Historical asset cache is not a regular file')
        if path.stat().st_size != expected_size or sha256(path) != expected_digest:
            raise ReleaseError('Historical asset size or SHA256 differs from authenticated metadata')

    try:
        if destination.exists() or destination.is_symlink():
            verify(destination)
            return destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.history-',
                                         suffix='.pending', delete=False) as output:
            pending = Path(output.name)
        try:
            # Github.asset_bytes is repository-bound, authenticated and bounded.
            github.asset_bytes(asset, pending)
            verify(pending)
            pending.replace(destination)
        finally:
            pending.unlink(missing_ok=True)
        return destination
    except OSError as error:
        raise ReleaseError('Historical asset cache or download is unavailable') from error


def _tool_text(command, timeout):
    try:
        return execute(command, timeout=timeout).decode('utf-8', errors='strict')
    except (OSError, subprocess.SubprocessError, UnicodeError, ReleaseError) as error:
        raise ReleaseError('Historical APK SDK inspection failed') from error


def inspect_historical_apk(apk, sdk):
    """Inspect the legacy package variants; production candidate rules stay separate."""
    sdk = Path(sdk)
    aapt, apksigner = sdk / 'aapt.exe', sdk / 'apksigner.bat'
    if not sdk.is_dir() or not aapt.is_file() or not apksigner.is_file():
        raise ReleaseError('Trusted historical APK SDK tools are unavailable')
    badging = _tool_text([aapt, 'dump', 'badging', Path(apk)], 60)
    packages = re.findall(r'^package: (.+)$', badging, re.MULTILINE)
    package = (re.fullmatch(r"name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'(?: .*)?",
                            packages[0]) if len(packages) == 1 else None)
    minimum = re.findall(r"^sdkVersion:'(\d+)'\s*$", badging, re.MULTILINE)
    abis = re.findall(r'^native-code: (.+)$', badging, re.MULTILINE)
    if (not package or re.search(r'(?:^|\s)(?:split|versionCodeMajor)=', packages[0])
            or package[1] not in APPLICATION_IDS or len(minimum) != 1
            or len(abis) != 1 or abis[0].strip() != "'arm64-v8a'"):
        raise ReleaseError('Historical APK is not a complete supported JMS ARM64 package')
    if len(package[2]) > len(str(MAX_VERSION_CODE)):
        raise ReleaseError('Invalid historical APK versionCode')
    code = _positive_integer(int(package[2]), 'APK versionCode', MAX_VERSION_CODE)
    _positive_integer(int(minimum[0]), 'APK minimum SDK')
    try:
        with zipfile.ZipFile(apk) as archive:
            names = archive.namelist()
            for name in ('AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libflutter.so',
                         'lib/arm64-v8a/libapp.so'):
                if names.count(name) != 1 or archive.getinfo(name).file_size <= 0:
                    raise ReleaseError('Historical APK required entries are missing or ambiguous')
    except (OSError, zipfile.BadZipFile) as error:
        raise ReleaseError('Historical APK archive is invalid') from error
    signature = _tool_text([apksigner, 'verify', '--verbose', '--print-certs', Path(apk)], 120)
    fingerprints = re.findall(r'^Signer #([0-9]+) certificate SHA-256 digest: ([a-fA-F0-9]{64})\s*$',
                              signature, re.MULTILINE)
    if (not re.search(r'^Verifies\s*$', signature, re.MULTILINE)
            or re.findall(r'^Number of signers: (\d+)\s*$', signature, re.MULTILINE) != ['1']
            or len(fingerprints) != 1 or fingerprints[0][0] != '1' or fingerprints[0][1].lower() != SIGNER):
        raise ReleaseError('Historical APK verified signer differs from the pinned JMS signer')
    return {'applicationId': package[1], 'versionCode': code, 'versionName': package[3],
            'signerSha256': fingerprints[0][1].lower()}


def _manifest_code(path):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result

    def invalid_constant(_):
        raise ValueError('Invalid JSON constant')

    try:
        manifest = json.loads(path.read_text(encoding='utf-8-sig'),
                              object_pairs_hook=unique_object, parse_constant=invalid_constant)
        if not isinstance(manifest, dict):
            raise ValueError('Expected JSON object')
        return _positive_integer(manifest.get('versionCode'), 'manifest versionCode', MAX_VERSION_CODE)
    except (OSError, ValueError, UnicodeError) as error:
        raise ReleaseError('Existing published release has invalid update.json metadata') from error


def verify_published_version_codes(github, releases, candidate_version_code, cache_directory, sdk):
    """Require a newer code than every published release and return audit records.

    Drafts retain the publisher's existing treatment. Missing or invalid proof
    for any published release blocks publication; .dev codes are also compared.
    The only writes are verified local cache bytes, never GitHub mutations.
    """
    _positive_integer(candidate_version_code, 'candidate versionCode', MAX_VERSION_CODE)
    if not isinstance(releases, (list, tuple)) or len(releases) > 1000:
        raise ReleaseError('Historical release list is incomplete or unbounded')
    records, seen = [], set()
    for previous in releases:
        if not isinstance(previous, dict) or type(previous.get('draft')) is not bool:
            raise ReleaseError('Historical release metadata is invalid')
        identity = _positive_integer(previous.get('id'), 'release ID')
        if identity in seen:
            raise ReleaseError('Duplicate historical release metadata')
        seen.add(identity)
        if previous['draft']:
            continue
        assets, tag = previous.get('assets'), previous.get('tag_name')
        if not isinstance(assets, list) or not isinstance(tag, str) or not tag:
            raise ReleaseError('Historical release assets or tag are missing')
        asset_ids, asset_names = set(), set()
        for asset in assets:
            if (not isinstance(asset, dict) or type(asset.get('id')) is not int or asset['id'] <= 0
                    or not isinstance(asset.get('name'), str) or not asset['name']
                    or asset['id'] in asset_ids or asset['name'] in asset_names):
                raise ReleaseError('Historical release asset metadata is invalid or duplicated')
            asset_ids.add(asset['id'])
            asset_names.add(asset['name'])
        manifests = [asset for asset in assets if asset['name'] == 'update.json']
        record = {'releaseId': identity, 'tag': tag}
        if manifests:
            if len(manifests) != 1:
                raise ReleaseError('Existing published release has duplicate update.json metadata')
            asset = manifests[0]
            code = _manifest_code(_verified_asset(github, asset, cache_directory))
            record['proof'] = 'update.json'
        else:
            apks = [asset for asset in assets if asset['name'].lower().endswith('.apk')
                    or asset.get('content_type') == 'application/vnd.android.package-archive']
            if len(apks) != 1:
                raise ReleaseError('Missing update.json requires one unambiguous historical APK')
            asset = apks[0]
            info = inspect_historical_apk(_verified_asset(github, asset, cache_directory, apk=True), sdk)
            code = _positive_integer(info.get('versionCode'), 'APK versionCode', MAX_VERSION_CODE)
            record.update(info)
            record['proof'] = 'verified-apk'
        record.update(assetId=asset['id'], assetSha256=_asset_identity(asset, MAX_ASSET)[2],
                      versionCode=code)
        if code >= candidate_version_code:
            raise ReleaseError('VersionCode is not newer than all published versions')
        records.append(record)
    return records
