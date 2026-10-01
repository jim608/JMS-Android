"""Desktop platform gates using the shared draft/upload/verify publisher."""
import json
import io
import hashlib
import re
import subprocess
import tarfile
import zipfile
from pathlib import Path

from jms_publication import (ROOT, Github, ReleaseError, sha256, save_json,
                             upload_complete_release, anonymous_download)
from check_jms_git_privacy import load_policy, scan_packages_cached, tree_entries

REPOSITORIES = {'windows': 'jim608/JMS-Desktop', 'linux': 'jim608/JMS-Linux', 'web': 'jim608/JMS-Web'}


def validate_web_inventory(directory):
    record = json.loads((directory / 'web-publication.json').read_text(encoding='utf-8'))
    if record['repository'] != REPOSITORIES['web'] or record['platform'] != 'web':
        raise ReleaseError('Web repository/platform mismatch')
    if record['sourceRepository'] != 'jim608/JMS-Android' or not re.fullmatch('[a-f0-9]{40}', record['sourceCommit']):
        raise ReleaseError('Invalid Web source identity')
    version = re.search(r'^version:\s*([^+\s]+)\+(\d+)',
                       git('show', record['sourceCommit'] + ':pubspec.yaml'), re.M)
    if not version or (version[1], int(version[2])) != (record['versionName'], record['versionCode']):
        raise ReleaseError('Web version differs from source')
    expected_id = 'JMS-' + record['versionName'] + '-web-' + record['sourceCommit'][:12]
    if record['buildId'] != expected_id or record.get('validation', {}).get('container') is not True:
        raise ReleaseError('Web build identity or runtime evidence missing')
    files = {}
    for entry in record['assets']:
        name = entry['name']
        if Path(name).name != name or '/' in name or '\\' in name or name in files:
            raise ReleaseError('Invalid Web asset name')
        path = directory / name
        if not path.is_file() or path.stat().st_size != entry['size'] or sha256(path) != entry['sha256']:
            raise ReleaseError('Web asset differs from reviewed inventory')
        files[name] = {'path': str(path), 'size': entry['size'], 'sha256': entry['sha256']}
    required = {record['webArchive'], record['sourceArchive'], 'source.json', 'SHA256SUMS.txt', 'RELEASE_NOTES.md'}
    if not required.issubset(files):
        raise ReleaseError('Web release is incomplete')
    identity = json.loads((directory / 'source.json').read_text(encoding='utf-8'))
    for field in ('platform', 'versionName', 'versionCode', 'sourceCommit', 'sourceRepository', 'buildId'):
        if identity.get(field) != record[field]:
            raise ReleaseError('Web source record differs from release')
    with zipfile.ZipFile(directory / record['webArchive']) as bundle:
        if expected_id.encode() not in bundle.read('main.dart.js'):
            raise ReleaseError('Web executable has another build identity')
        for name in ('index.html', 'flutter_bootstrap.js', 'assets/NOTICES'):
            if name not in bundle.namelist():
                raise ReleaseError('Web runtime or dependency licenses missing')
    verify_source_archive(directory / record['sourceArchive'], record['sourceCommit'])
    privacy = scan_packages_cached([entry['path'] for entry in files.values()], load_policy(),
                                   ROOT / git('rev-parse', '--git-path', 'jms-privacy-cache'))
    if not privacy['accepted']:
        raise ReleaseError('Web release privacy review required')
    return record, files


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd, stderr=subprocess.PIPE).decode().strip()


def verify_source_archive(path, commit):
    entries = tree_entries(commit)
    blobs = [(name, oid) for name, (kind, oid) in entries.items() if kind == 'blob']
    result = subprocess.run(['git', 'cat-file', '--batch'], cwd=ROOT,
        input=('\n'.join(oid for _, oid in blobs) + '\n').encode(), capture_output=True, check=True)
    stream = io.BytesIO(result.stdout)
    with zipfile.ZipFile(path) as archive:
        for name, oid in blobs:
            header = stream.readline().split()
            if len(header) != 3 or header[0].decode() != oid or header[1] != b'blob':
                raise ReleaseError('Invalid source verification stream')
            data = stream.read(int(header[2]))
            stream.read(1)
            if hashlib.sha256(archive.read('JMS/' + name)).digest() != hashlib.sha256(data).digest():
                raise ReleaseError('Complete source archive differs from committed source')
        for name, (kind, oid) in entries.items():
            if kind == 'commit':
                marker = json.loads(archive.read('JMS/' + name + '/JMS_SUBMODULE_SOURCE.json'))
                if marker.get('commit') != oid or not any(member.startswith('JMS/' + name + '/') and not member.endswith('JMS_SUBMODULE_SOURCE.json') for member in archive.namelist()):
                    raise ReleaseError('Pinned submodule source missing')


def validate_inventory(directory, platform):
    record = json.loads((directory / 'desktop-publication.json').read_text(encoding='utf-8-sig'))
    if record['repository'] != REPOSITORIES[platform] or record['platform'] != platform + '-x64':
        raise ReleaseError('Desktop repository/platform mismatch')
    if not re.fullmatch(r'[a-f0-9]{40}', record['sourceCommit']):
        raise ReleaseError('Invalid shared source commit')
    if record['sourceRepository'] != 'jim608/JMS-Android':
        raise ReleaseError('Unexpected shared source repository')
    review = record['nativeReview']
    if review['platform'] != record['platform'] or review.get('missing') != []:
        raise ReleaseError('Platform native materials are incomplete')
    if not review.get('materials') or not record.get('validation', {}).get('launch'):
        raise ReleaseError('Native materials and actual launch verification are required')
    files = {}
    policy = load_policy()
    for entry in record['assets']:
        name = entry['name']
        if Path(name).name != name or '/' in name or '\\' in name or name in files:
            raise ReleaseError('Unsafe or duplicate asset name')
        path = directory / name
        if not path.is_file() or path.stat().st_size != entry['size'] or sha256(path) != entry['sha256']:
            raise ReleaseError('Prepared asset changed: ' + name)
        files[name] = {'path': str(path), 'size': entry['size'], 'sha256': entry['sha256']}
    privacy = scan_packages_cached([entry['path'] for entry in files.values()], policy,
                                   ROOT / git('rev-parse', '--git-path', 'jms-privacy-cache'))
    if not privacy['accepted']:
        raise ReleaseError('Release asset privacy review required')
    update_name = 'update.json' if platform == 'windows' else 'update-linux.json'
    if update_name not in files or 'SHA256SUMS.txt' not in files:
        raise ReleaseError('Missing platform update metadata/checksums')
    update = json.loads((directory / update_name).read_text(encoding='utf-8-sig'))
    for field in ('platform', 'versionName', 'versionCode', 'sourceCommit', 'buildId'):
        if update[field] != record[field]:
            raise ReleaseError('Update metadata differs from build: ' + field)
    for field in ('installer', 'source'):
        item = update[field]
        if item['name'] not in files or any(files[item['name']][key] != item[key] for key in ('size', 'sha256')):
            raise ReleaseError('Update asset binding mismatch')
    if not all(name in files for name in review['materials']):
        raise ReleaseError('Native material archive missing from release')
    portable = f'JMS-Windows-{record["versionName"]}-x64-portable.zip' if platform == 'windows' else f'JMS-Linux-{record["versionName"]}-x64.tar.gz'
    if portable not in files:
        raise ReleaseError('Portable package is required')
    if platform == 'linux':
        with tarfile.open(directory / portable, 'r:gz') as archive:
            binaries = {member.name.removeprefix('JMS/'): hashlib.sha256(archive.extractfile(member).read()).hexdigest()
                        for member in archive if member.isfile() and member.name.endswith('.so')}
    else:
        with zipfile.ZipFile(directory / portable) as archive:
            binaries = {name.split('/', 1)[-1]: hashlib.sha256(archive.read(name)).hexdigest()
                        for name in archive.namelist() if name.lower().endswith('.dll')}
    if not binaries or binaries != review.get('binaries'):
        raise ReleaseError('Native review is not bound to the actual portable binary set')
    if platform == 'linux':
        with tarfile.open(directory / update['installer']['name'], 'r:xz') as archive:
            info = archive.extractfile('.PKGINFO').read().decode()
            for field, value in {'pkgname': 'jms', 'arch': 'x86_64', 'pkgver': update['packageVersion']}.items():
                if re.findall(r'^' + field + r' = (.+)$', info, re.M) != [value]:
                    raise ReleaseError('Actual pacman identity differs from update metadata')
            built = json.load(archive.extractfile('opt/jms/JMS_BUILD_INFO.json'))
        for field in ('versionName', 'versionCode', 'platform', 'sourceCommit', 'buildId'):
            if built[field] != record[field]:
                raise ReleaseError('Actual Linux package differs from release record')
    with zipfile.ZipFile(directory / update['source']['name']) as archive:
        if archive.read('JMS/lib/main.dart') != subprocess.check_output(
                ['git', 'show', record['sourceCommit'] + ':lib/main.dart'], cwd=ROOT):
            raise ReleaseError('Complete shared source archive is missing or mismatched')
        version = re.search(rb'^version:\s*(\S+)', archive.read('JMS/pubspec.yaml'), re.M)
        if not version or version[1].decode() != record['versionName'] + '+' + str(record['versionCode']):
            raise ReleaseError('Source version differs from release')
    verify_source_archive(directory / update['source']['name'], record['sourceCommit'])
    checksums = (directory / 'SHA256SUMS.txt').read_text(encoding='ascii').splitlines()
    expected_checksums = {entry['sha256'] + '  ' + name for name, entry in files.items() if name != 'SHA256SUMS.txt'}
    if set(checksums) != expected_checksums or len(checksums) != len(expected_checksums):
        raise ReleaseError('Checksum inventory is incomplete or ambiguous')
    return record, files


def resume_publication_state(path, planned):
    if not path.exists():
        return planned
    saved = json.loads(path.read_text(encoding='utf-8'))
    if any(saved.get(field) != value for field, value in planned.items()):
        raise ReleaseError('Saved desktop publication identity differs; mutation refused')
    return saved


def publish_desktop(args):
    if not args.artifact_directory:
        raise ReleaseError('Desktop publication requires a prepared artifact directory')
    directory = Path(args.artifact_directory).resolve()
    record, files = (validate_web_inventory(directory) if args.platform == 'web'
                     else validate_inventory(directory, args.platform))
    # The source SHA is a shared-source commit; the release tag belongs to the release repository.
    remote_source = git('ls-remote', 'https://github.com/jim608/JMS-Android.git', 'refs/heads/jms').split()[0]
    git('merge-base', '--is-ancestor', record['sourceCommit'], remote_source)
    checkout = ROOT / 'artifacts/release-repositories' / REPOSITORIES[args.platform].split('/')[1]
    if git('status', '--porcelain', cwd=checkout):
        raise ReleaseError('Release repository record must be committed before publication')
    release_commit = git('rev-parse', 'HEAD', cwd=checkout)
    if git('remote', 'get-url', 'origin', cwd=checkout).removesuffix('.git') != 'https://github.com/' + record['repository']:
        raise ReleaseError('Release repository checkout mismatch')
    expected = json.loads((checkout / 'releases' / (record['versionName'] + '.json')).read_text(encoding='utf-8'))
    if expected != record:
        raise ReleaseError('Committed release record differs from prepared inventory')
    notes = (directory / 'RELEASE_NOTES.md').read_text(encoding='utf-8').strip()
    if args.dry_run:
        print(json.dumps({'repository': record['repository'], 'sourceCommit': record['sourceCommit'],
                          'releaseCommit': release_commit, 'assets': len(files)}))
        return
    tag = 'v' + record['versionName']
    github = Github(repository=record['repository'])
    github.authenticate()
    existing = git('ls-remote', 'origin', 'refs/tags/' + tag, cwd=checkout)
    if existing and existing.split()[0] != release_commit:
        raise ReleaseError('Release tag exists at another commit; mutation refused')
    if not existing:
        subprocess.run(['git', 'push', '--atomic', 'origin', 'HEAD:refs/heads/jms',
                        'HEAD:refs/tags/' + tag], cwd=checkout, check=True)
    history = github.releases()
    releases = [item for item in history if item['tag_name'] == tag]
    if len(releases) > 1:
        raise ReleaseError('Ambiguous release tag')
    release = releases[0] if releases else github.api('repos/' + record['repository'] + '/releases', 'POST', {
        'tag_name': tag, 'target_commitish': release_commit, 'name': 'JMS ' + record['versionName'],
        'body': notes, 'draft': True, 'prerelease': args.channel == 'prerelease'})
    state = {'releaseId': release['id'], 'tag': tag, 'version': record['versionName'],
             'notes': notes, 'prerelease': args.channel == 'prerelease', 'sourceCommit': record['sourceCommit'],
             'releaseCommit': release_commit}
    state_path = directory / 'publication-state.json'
    state = resume_publication_state(state_path, state)
    verification = directory / 'verification'
    verification.mkdir(exist_ok=True)
    upload_complete_release(github, state, files,
        lambda: save_json(state_path, state), verification)
    public = github.api('repos/' + record['repository'] + '/releases/' + str(release['id']))
    anonymous = directory / 'anonymous-verification'
    anonymous.mkdir(exist_ok=True)
    for asset in public['assets']:
        expected = files[asset['name']]
        anonymous_download(asset['browser_download_url'], anonymous / asset['name'],
            expected['size'], expected['sha256'], repository=record['repository'])
    state['anonymousVerified'] = True
    save_json(state_path, state)
    print(public['html_url'])
