import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import zipfile

from jms_publication import (
    ROOT, REPOSITORY, SIGNER, BASELINE_CODE, Github, ReleaseError, anonymous_download,
    evidence_file, execute, native_hashes, publication_gates, read_json, release_lock,
    save_json, sha256, source_files, source_fingerprint, upload_complete_release,
)
from jms_release_notes import require_current_notes
from prepare_jms_release import apk_info, require_bound_sources
from verify_jms_snapshot import verify_snapshot

PUBLICATION = ROOT / 'artifacts/publication'
SDK = ROOT / '.jms-tools/android-sdk/build-tools/35.0.0'
FLUTTER = ROOT / '.jms-tools/flutter/bin/flutter.bat'


def version_info():
    match = re.search(r'^version:\s*([A-Za-z0-9._-]+)\+(\d+)\s*$',
                      (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
    if not match:
        raise ReleaseError('pubspec version must declare versionName+integer base code')
    return match[1], int(match[2]) + 2000


def verify_legacy_checker(policy):
    path = ROOT / policy['baselineBuildRecord']
    if sha256(path) != policy['baselineBuildRecordSha256']:
        raise ReleaseError('Frozen .8 build record changed')
    baseline = read_json(path)
    if baseline['version'] != '0.11.1-jms.8' or baseline['baseVersionCode'] != 8:
        raise ReleaseError('Legacy baseline is not installed .8')
    with zipfile.ZipFile(ROOT / policy['baselineApk']) as archive:
        if baseline['buildId'].encode() not in archive.read('lib/arm64-v8a/libapp.so'):
            raise ReleaseError('.8 source record is not bound to baseline APK build ID')
    files = {entry['path']: entry['sha256'] for entry in baseline['inputs']}
    names = ['lib/util/update_checker.dart', 'lib/util/update_source.dart', 'lib/util/brand.dart']
    for name in names:
        if name not in files or sha256(ROOT / name) != files[name]:
            raise ReleaseError('.8 checker dependency changed; preserve/test a frozen legacy verifier before publishing: ' + name)


def quality_checks(files):
    quality_path = PUBLICATION / 'quality.json'
    previous = read_json(quality_path) if quality_path.exists() else {}
    logs = []
    commands = [
        ('flutter-tests', [FLUTTER, 'test', '--no-pub']),
        ('flutter-analyze', [FLUTTER, 'analyze', '--no-pub']),
        ('publication-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_jms*.py']),
    ]
    for name, command in commands:
        path = PUBLICATION / (name + '.log')
        scopes = ('scripts/', 'config/') if name == 'publication-tests' else ('lib/', 'test/', 'integration_test/', 'assets/', 'icons/', 'android/', 'third_party/')
        inputs = {entry: checksum for entry, checksum in files.items()
                  if entry.startswith(scopes) or entry in ('pubspec.yaml', 'pubspec.lock', '.fvmrc', 'analysis_options.yaml', 'l10n.yaml', 'config/config.json', 'config/jms_updates.json')}
        fingerprint = source_fingerprint(inputs)
        prior = next((log for log in previous.get('logs', []) if log.get('name') == name), {})
        reused = prior.get('status') == 'PASS' and prior.get('fingerprint') == fingerprint and path.exists() and prior.get('sha256') == sha256(path)
        if not reused:
            execute(command, log=path, timeout=1200)
        logs.append({'name': name, 'status': 'PASS', 'fingerprint': fingerprint, 'path': path.relative_to(ROOT).as_posix(), 'sha256': sha256(path), 'reused': reused})
        save_json(quality_path, {'status': 'PARTIAL', 'logs': logs})
    record = {'status': 'PASS', 'logs': logs}
    save_json(quality_path, record)
    return record


def bind_candidate_record(record, commit, apk, original_path):
    if record.get('mode') != 'release' or not record.get('inputs'):
        raise ReleaseError('Local candidate is not a recorded release build')
    require_bound_sources(record)
    verify_snapshot(commit, record['inputs'])
    with zipfile.ZipFile(apk) as archive:
        if record['buildId'].encode() not in archive.read('lib/arm64-v8a/libapp.so'):
            raise ReleaseError('Local candidate build ID differs from recorded source')
    if record.get('publicationSnapshot') and record['sourceCommit'] != commit:
        raise ReleaseError('Candidate already belongs to another immutable publication snapshot')
    return dict(record, sourceCommit=commit, publicationSnapshot=True,
                originalBuildSourceCommit=record['sourceCommit'], originalBuildRecordSha256=sha256(original_path),
                publicationBinding='Snapshot verified against every actual build input; original local build record retained')


def remote_refs():
    output = execute(['git', 'ls-remote', 'https://github.com/' + REPOSITORY + '.git'], timeout=60).decode()
    return {line.split()[1]: line.split()[0] for line in output.splitlines() if line.strip()}


def snapshot_source(files, parent, state_directory, version):
    index = state_directory / 'snapshot.index'
    environment = dict(os.environ, GIT_INDEX_FILE=str(index), GIT_AUTHOR_NAME='jim608',
                       GIT_AUTHOR_EMAIL='jim608@users.noreply.github.com', GIT_COMMITTER_NAME='jim608',
                       GIT_COMMITTER_EMAIL='jim608@users.noreply.github.com')
    execute(['git', 'read-tree', '--empty'], environment=environment)
    entries = []
    for name, digest in files.items():
        path = ROOT / name
        if sha256(path) != digest:
            raise ReleaseError('Source changed while preparing snapshot: ' + name)
        blob = execute(['git', 'hash-object', '-w', '--stdin'], data=path.read_bytes()).decode().strip()
        mode = '100755' if name.endswith('.sh') or name == 'android/gradlew' else '100644'
        entries.append(f'{mode} {blob}\t{name}\0')
    execute(['git', 'update-index', '-z', '--index-info'], environment=environment, data=''.join(entries).encode())
    tree = execute(['git', 'write-tree'], environment=environment).decode().strip()
    arguments = ['git', 'commit-tree', tree]
    if parent:
        execute(['git', 'fetch', '--no-tags', 'https://github.com/' + REPOSITORY + '.git', parent], timeout=120)
        arguments.extend(['-p', parent])
    commit = execute(arguments, environment=environment,
                     data=f'JMS {version}: reviewed release source snapshot\n\nUpstream base: a30343a30754114ca66fcae921a0949003761344\n'.encode()).decode().strip()
    verify_snapshot(commit)
    return commit


def verify_package(directory, record, apk):
    metadata = read_json(directory / 'update.json')
    if metadata['sourceCommit'] != record['sourceCommit'] or metadata['buildId'] != record['buildId']:
        raise ReleaseError('Release package source/build binding differs')
    if metadata['apk']['sha256'] != sha256(apk) or metadata['apk']['size'] != apk.stat().st_size:
        raise ReleaseError('Release package APK hash/size differs')
    source = directory / metadata['source']['name']
    if source.stat().st_size != metadata['source']['size'] or sha256(source) != metadata['source']['sha256']:
        raise ReleaseError('Source archive changed')
    with zipfile.ZipFile(source) as archive:
        manifest = json.loads(archive.read('JMS/source-manifest.json'))
        if manifest['sourceCommit'] != record['sourceCommit']:
            raise ReleaseError('Source ZIP commit differs')
        for name, digest in manifest['files'].items():
            if hashlib.sha256(archive.read('JMS/' + name)).hexdigest() != digest:
                raise ReleaseError('Source ZIP file differs: ' + name)
        if any(manifest['files'].get(entry['path']) != entry['sha256'] for entry in record['inputs']):
            raise ReleaseError('Source ZIP does not cover actual App inputs')
    return metadata


def release_files(directory, native):
    materials = directory / 'JMS-native-materials.zip'
    if not materials.exists():
        pending = materials.with_suffix('.zip.part')
        try:
            with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as archive:
                names = set()
                for reference in native['materials']:
                    path = evidence_file(reference)
                    archive_name = Path(reference['path']).as_posix()
                    if archive_name in names:
                        raise ReleaseError('Native materials have duplicate names')
                    names.add(archive_name)
                    archive.write(path, archive_name)
                archive.writestr('source-manifest.json', json.dumps(native, indent=2))
            os.replace(pending, materials)
        finally:
            pending.unlink(missing_ok=True)
    with zipfile.ZipFile(materials) as archive:
        for reference in native['materials']:
            path = evidence_file(reference)
            if hashlib.sha256(archive.read(Path(reference['path']).as_posix())).hexdigest() != reference['sha256']:
                raise ReleaseError('Native material archive drift')
        if json.loads(archive.read('source-manifest.json')) != native:
            raise ReleaseError('Native material review changed')
    names = [name for name in directory.iterdir() if name.is_file() and name.name != 'SHA256SUMS.txt']
    sums = ''.join(f'{sha256(path)}  {path.name}\n' for path in sorted(names))
    (directory / 'SHA256SUMS.txt').write_text(sums, encoding='utf-8')
    return {path.name: {'path': str(path), 'size': path.stat().st_size, 'sha256': sha256(path)}
            for path in directory.iterdir() if path.is_file()}


def verify_remote(github, state, files, state_directory, policy):
    anonymous = state_directory / 'anonymous'
    anonymous.mkdir(exist_ok=True)
    environment = dict(os.environ)
    for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
        environment.pop(name, None)
    for attempt in range(3):
        try:
            execute([ROOT / '.jms-tools/flutter/bin/dart.bat', 'run', 'scripts/check_jms_feed.dart',
                     '--prerelease' if state['prerelease'] else '--stable', f'--expected-code={state["versionCode"]}'],
                    environment=environment, log=state_directory / 'anonymous-check.log', timeout=120)
            release = github.api(f'repos/{REPOSITORY}/releases/{state["releaseId"]}')
            if release['draft']:
                raise ReleaseError('Release is still a draft')
            assets = {asset['name']: asset for asset in release['assets']}
            downloaded = []
            reused = []
            for name, expected in files.items():
                fresh = anonymous_download(assets[name]['browser_download_url'], anonymous / name, expected['size'], expected['sha256'])
                (downloaded if fresh else reused).append(name)
            info, signer, _, _, _ = apk_info(anonymous / state['apkName'], SDK)
            if info['versionCode'] != state['versionCode'] or signer != SIGNER:
                raise ReleaseError('Anonymous APK identity/version/signature mismatch')
            report = {'authentication': 'none', 'legacyInstalledVersionCode': BASELINE_CODE,
                      'versionCode': info['versionCode'], 'signerSha256': signer, 'verifiedAssets': list(files),
                      'downloadedAssets': downloaded, 'reusedVerifiedDownloads': reused,
                      'status': 'PASS', 'phoneInstalled': False, 'releaseUrl': release['html_url']}
            save_json(state_directory / 'anonymous-verification.json', report)
            return report
        except (ReleaseError, OSError, KeyError) as error:
            if attempt == 2:
                raise ReleaseError('Published, but anonymous verification failed; resume without republishing') from error
            time.sleep((3, 10)[attempt])


def publish(args):
    PUBLICATION.mkdir(parents=True, exist_ok=True)
    with release_lock(PUBLICATION / 'publisher.lock'):
        policy = read_json(ROOT / 'config/jms_publication.json')
        baseline = ROOT / policy['baselineApk']
        if sha256(baseline) != policy['baselineSha256']:
            raise ReleaseError('Installed .8 baseline APK changed')
        info, signer, _, _, _ = apk_info(baseline, SDK)
        if info['versionCode'] != BASELINE_CODE or signer != SIGNER:
            raise ReleaseError('Installed .8 trust baseline differs')
        verify_legacy_checker(policy)
        github = Github()
        repository = github.authenticate()
        files = source_files()
        fingerprint = source_fingerprint({name: digest for name, digest in files.items() if name != 'docs/JMS_STATUS.md'})
        version, code = version_info()
        candidate = ROOT / f'artifacts/JMS-Android-{version}-release-arm64-test-signed.apk'
        quality = quality_checks(files)
        review_apk = candidate if candidate.exists() else baseline
        if not candidate.exists() and policy.get('nativeEvidence'):
            native_review = read_json(evidence_file(policy['nativeEvidence']))
            if native_review.get('artifact'):
                review_apk = evidence_file(native_review['artifact'])
        failures = publication_gates(policy, review_apk)
        if code <= BASELINE_CODE:
            failures.append('VERSION: select an unused actual pubspec versionCode greater than 2008 after other gates pass')
        if args.channel == 'stable':
            try:
                stable = read_json(evidence_file(policy.get('stableEvidence')))
                if stable.get('status') != 'PASS' or stable.get('versionCode') != code or not stable.get('deviceAcceptance'):
                    raise ReleaseError('Stable channel requires version-specific device acceptance')
            except (ValueError, OSError, KeyError) as error:
                failures.append('STABLE: ' + str(error))
        preflight = {'repository': REPOSITORY, 'account': 'jim608', 'writePermission': True, 'version': version,
                     'versionCode': code, 'channel': args.channel, 'dryRun': args.dry_run,
                     'quality': quality, 'sourceFingerprint': fingerprint, 'sourceFiles': files,
                     'blockers': failures, 'status': 'BLOCKED' if failures else 'PASS'}
        save_json(PUBLICATION / 'preflight.json', preflight)
        if failures:
            raise ReleaseError('\n'.join(failures))
        if args.dry_run:
            print('Dry-run PASS; no commit, build, push, tag or release was created')
            return
        tag = 'v' + version
        state_directory = PUBLICATION / tag
        state_directory.mkdir(exist_ok=True)
        state_path = state_directory / 'state.json'
        state = read_json(state_path) if state_path.exists() else {}
        if state and (state['sourceFingerprint'] != fingerprint or state['prerelease'] != (args.channel == 'prerelease')):
            raise ReleaseError('Version source/channel changed after preparation; use a new actual version')
        releases = github.releases()
        matching = [release for release in releases if release['tag_name'] == tag]
        if len(matching) > 1:
            raise ReleaseError('Duplicate release tag')
        if not state:
            if matching:
                raise ReleaseError('Existing remote version has no local immutable state; do not overwrite it')
            for previous in releases:
                if previous['draft']:
                    continue
                manifests = [asset for asset in previous['assets'] if asset['name'] == 'update.json']
                if len(manifests) != 1:
                    raise ReleaseError('Existing published release has incomplete metadata')
                path = state_directory / 'previous-update.json'
                github.asset_bytes(manifests[0], path)
                if read_json(path)['versionCode'] >= code:
                    raise ReleaseError('VersionCode is not newer than all published versions')
            for path in (ROOT / 'artifacts/checks').glob('build-*-inputs.json'):
                previous = read_json(path)
                if path.name == f'build-{version}-inputs.json' and candidate.is_file() and previous.get('version') == version:
                    require_bound_sources(previous)
                    continue
                if 2000 + previous['baseVersionCode'] >= code:
                    raise ReleaseError('VersionCode already used by a local build; use a new version')
            refs = remote_refs()
            parent = refs.get('refs/heads/main')
            if refs and not parent:
                raise ReleaseError('Remote history is not the expected JMS main branch')
            if parent:
                prior_states = [read_json(path) for path in PUBLICATION.glob('v*/state.json')]
                if not any(previous.get('published') and previous.get('sourceCommit') == parent for previous in prior_states):
                    raise ReleaseError('Unreviewed remote history; inspect it before extending main')
            notes = require_current_notes(ROOT / 'CHANGELOG.md', ROOT / 'docs/JMS_RELEASE_NOTES.zh-Hant.md', version)
            state = {'tag': tag, 'version': version, 'versionCode': code, 'prerelease': args.channel == 'prerelease',
                     'sourceFingerprint': fingerprint, 'parent': parent, 'notes': notes, 'published': False}
            state['sourceCommit'] = snapshot_source(files, parent, state_directory, version)
            save_json(state_path, state)
        save = lambda: save_json(state_path, state)
        apk = ROOT / f'artifacts/JMS-Android-{version}-release-arm64-test-signed.apk'
        record_path = ROOT / f'artifacts/checks/build-{version}-inputs.json'
        try:
            if not apk.exists():
                execute(['powershell', '-NoProfile', '-File', 'scripts/build_jms_android.ps1',
                         '-SourceCommit', state['sourceCommit']], log=state_directory / 'build.log', timeout=2400)
            record = read_json(record_path)
            if not record.get('publicationSnapshot'):
                record = bind_candidate_record(record, state['sourceCommit'], apk, record_path)
            elif record['sourceCommit'] != state['sourceCommit']:
                raise ReleaseError('Existing APK belongs to another reviewed source commit; do not rebuild over it')
            publication_record = state_directory / 'publication-build-inputs.json'
            save_json(publication_record, record)
            require_bound_sources(record)
            verify_snapshot(state['sourceCommit'], record['inputs'])
            info, signer, _, _, _ = apk_info(apk, SDK)
            if info['versionCode'] != code or info['versionName'] != version or signer != SIGNER:
                raise ReleaseError('Built APK version or signature differs from planned upgrade')
            failures = publication_gates(policy, apk, signer)
            if failures:
                raise ReleaseError('; '.join(failures))
            if args.channel == 'stable' and stable.get('apkSha256') != sha256(apk):
                raise ReleaseError('Stable acceptance is not bound to this exact APK')
            state.update(buildId=record['buildId'], apkName=apk.name, apkSha256=sha256(apk))
            save()
            directory = ROOT / 'artifacts/releases' / record['buildId']
            if not directory.exists():
                execute(['powershell', '-NoProfile', '-File', 'scripts/prepare_jms_release.ps1', '-Apk', apk,
                         '-BuildRecord', publication_record, '-RequirePublicationReady'], log=state_directory / 'prepare.log', timeout=600)
            verify_package(directory, record, apk)
            native = read_json(evidence_file(policy['nativeEvidence']))
            assets = release_files(directory, native)
            if state.get('assets') and state['assets'] != assets:
                raise ReleaseError('Prepared assets changed; published content cannot be replaced')
            state['assets'] = assets
            save()
            refs = remote_refs()
            if refs.get('refs/heads/main') not in (state['parent'], state['sourceCommit']):
                raise ReleaseError('Remote main advanced outside this run; no force-push')
            if refs.get('refs/tags/' + tag) not in (None, state['sourceCommit']):
                raise ReleaseError('Remote tag already points elsewhere')
            if refs.get('refs/tags/' + tag) != state['sourceCommit']:
                helper = '!"' + str(github.executable).replace('\\', '/') + '" auth git-credential'
                execute(['git', '-c', 'credential.helper=', '-c', 'credential.https://github.com.helper=' + helper,
                         'push', '--atomic', 'https://github.com/' + REPOSITORY + '.git',
                         state['sourceCommit'] + ':refs/heads/main', state['sourceCommit'] + ':refs/tags/' + tag],
                        environment=github.environment, log=state_directory / 'push.log', timeout=600)
            if not state.get('releaseId'):
                current = [release for release in github.releases() if release['tag_name'] == tag]
                if current:
                    release = current[0]
                else:
                    release = github.api(f'repos/{REPOSITORY}/releases', 'POST', {
                        'tag_name': tag, 'target_commitish': state['sourceCommit'], 'name': 'JMS ' + version,
                        'body': state['notes'], 'draft': True, 'prerelease': state['prerelease'], 'make_latest': 'false'})
                state['releaseId'] = release['id']
                save()
            verification = state_directory / 'draft-verification'
            verification.mkdir(exist_ok=True)
            upload_complete_release(github, state, assets, save, verification)
            report = verify_remote(github, state, assets, state_directory, policy)
            state['anonymousVerified'] = True
            state['releaseUrl'] = report['releaseUrl']
            state.pop('lastError', None)
            save()
            print(json.dumps(report, indent=2))
        except Exception as error:
            state['lastError'] = type(error).__name__ + ': ' + str(error) if isinstance(error, ReleaseError) else type(error).__name__
            save()
            raise


def main():
    parser = argparse.ArgumentParser(description='Explicit, gated JMS release entry; default publishes when all checks pass')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--channel', choices=['prerelease', 'stable'], default='prerelease')
    args = parser.parse_args()
    try:
        publish(args)
    except (ReleaseError, OSError, KeyError, ValueError) as error:
        print('PUBLICATION STOPPED: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
