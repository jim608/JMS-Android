"""Desktop platform gates using the shared draft/upload/verify publisher."""
import configparser
import json
import io
import hashlib
import re
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from jms_publication import (ROOT, Github, ReleaseError, sha256, save_json,
                             upload_complete_release, anonymous_download)
from check_jms_git_privacy import load_policy, scan_packages_cached, tree_entries
from jms_release_notes import release_notes_for, release_body_for_candidate

REPOSITORIES = {'windows': 'jim608/JMS-Desktop', 'linux': 'jim608/JMS-Linux', 'web': 'jim608/JMS-Web'}
FLATPAK_WORKFLOW = '.github/workflows/jms-flatpak.yml'
MAX_CI_ARCHIVE_BYTES = 512 * 1024 * 1024
FLATPAK_REQUIRED_LICENSES = (
    'jms/LICENSE', 'ffmpeg/COPYING.GPLv3', 'ffmpeg/LICENSE.md', 'libass/COPYING',
    'libplacebo/LICENSE', 'mpv/Copyright', 'mpv/LICENSE.GPL', 'mpv/LICENSE.LGPL',
    'uchardet/COPYING', 'ffnvcodec/nvEncodeAPI.h',
)


def release_tag(record):
    version = record.get('versionName')
    code = record.get('versionCode')
    if not isinstance(version, str) or not version or type(code) is not int or code < 0:
        raise ReleaseError('Invalid release version identity')
    default = 'v' + version
    tag = record.get('releaseTag', default)
    if tag not in (default, default + '+' + str(code)):
        raise ReleaseError('Release tag must match the exact application version')
    return tag


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
    if platform == 'linux' and record.get('packageFormat') == 'flatpak':
        return validate_flatpak_inventory(directory, record)
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


def prepared_assets(directory, record):
    files = {}
    for entry in record['assets']:
        name = entry['name']
        if (not isinstance(name, str) or not name or Path(name).name != name
                or '/' in name or '\\' in name or name in files):
            raise ReleaseError('Unsafe or duplicate asset name')
        path = directory / name
        if (not path.is_file() or path.stat().st_size != entry['size']
                or sha256(path) != entry['sha256']):
            raise ReleaseError('Prepared asset changed: ' + name)
        files[name] = {'path': str(path), 'size': entry['size'], 'sha256': entry['sha256']}
    return files


def verify_flatpak_ci(record, files):
    """Read the registered CI artifact independently before trusting deployment exports."""
    ci = record['flatpak']['ci']
    run_id = ci.get('runId')
    if (type(run_id) is not int or run_id <= 0
            or ci.get('artifactName') != 'jms-flatpak-' + record['sourceCommit']):
        raise ReleaseError('Invalid Flatpak CI identity')
    github = Github(repository='jim608/JMS-Android')
    prefix = 'repos/jim608/JMS-Android/actions/'
    run = github.api(prefix + 'runs/' + str(run_id))
    if (run.get('id') != run_id or run.get('status') != 'completed'
            or run.get('conclusion') != 'success' or run.get('head_branch') != 'jms'
            or run.get('head_sha') != record['sourceCommit']
            or run.get('path') != FLATPAK_WORKFLOW
            or run.get('event') not in ('push', 'workflow_dispatch')
            or run.get('repository', {}).get('full_name') != 'jim608/JMS-Android'
            or run.get('head_repository', {}).get('full_name') != 'jim608/JMS-Android'):
        raise ReleaseError('Flatpak CI run is not a successful pinned JMS build')
    listing = github.api(prefix + 'runs/' + str(run_id) + '/artifacts?per_page=100')
    if listing.get('total_count', 101) > 100:
        raise ReleaseError('Flatpak CI artifact inventory exceeds inspection limit')
    matches = [entry for entry in listing.get('artifacts', [])
               if entry.get('name') == ci['artifactName']]
    if len(matches) != 1:
        raise ReleaseError('Flatpak CI artifact is missing or ambiguous')
    artifact = matches[0]
    digest = artifact.get('digest', '')
    identity = artifact.get('workflow_run', {})
    if (artifact.get('expired') is not False or type(artifact.get('id')) is not int
            or not 0 < artifact.get('size_in_bytes', 0) <= MAX_CI_ARCHIVE_BYTES
            or not re.fullmatch(r'sha256:[a-f0-9]{64}', digest)
            or identity.get('id') != run_id or identity.get('head_branch') != 'jms'
            or identity.get('head_sha') != record['sourceCommit']):
        raise ReleaseError('Flatpak CI artifact provenance is incomplete')
    required = {record['flatpak'][field] for field in
                ('bundle', 'payload', 'receipt', 'buildManifest', 'nativeSources', 'source')}
    required.update(record['nativeReview']['materials'])
    with tempfile.TemporaryDirectory(prefix='jms-flatpak-ci-') as temporary:
        downloaded = Path(temporary) / 'artifact.zip'
        with downloaded.open('wb') as output:
            try:
                result = subprocess.run(['rtk', 'proxy', str(github.executable), 'api',
                    prefix + 'artifacts/' + str(artifact['id']) + '/zip'], cwd=ROOT,
                    env=github.environment, stdout=output, stderr=subprocess.PIPE, timeout=600)
            except subprocess.TimeoutExpired as error:
                raise ReleaseError('Flatpak CI artifact download timed out') from error
        if result.returncode != 0:
            raise ReleaseError('Flatpak CI artifact download failed')
        if (downloaded.stat().st_size > MAX_CI_ARCHIVE_BYTES
                or sha256(downloaded) != digest.removeprefix('sha256:')):
            raise ReleaseError('Flatpak CI artifact digest differs from GitHub metadata')
        with zipfile.ZipFile(downloaded) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)) or len(names) > 200000:
                raise ReleaseError('Flatpak CI archive has duplicate or excessive members')
            if any('\\' in name or PurePosixPath(name).is_absolute()
                   or '..' in PurePosixPath(name).parts for name in names):
                raise ReleaseError('Unsafe Flatpak CI archive member')
            if sum(item.file_size for item in archive.infolist()) > 4 * 1024**3:
                raise ReleaseError('Flatpak CI archive expansion limit exceeded')
            for name in required:
                if name not in files or name not in names:
                    raise ReleaseError('Flatpak asset missing from pinned CI artifact: ' + name)
                member = archive.getinfo(name)
                if member.file_size != files[name]['size'] or member.file_size > MAX_CI_ARCHIVE_BYTES:
                    raise ReleaseError('Flatpak CI asset size differs: ' + name)
                with archive.open(member) as stream:
                    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
                if actual != files[name]['sha256']:
                    raise ReleaseError('Flatpak candidate differs from pinned CI artifact: ' + name)
    return digest.removeprefix('sha256:')


def verify_flatpak_payload(directory, record, files):
    flatpak = record['flatpak']
    receipt = json.loads((directory / flatpak['receipt']).read_text(encoding='utf-8'))
    identity = ('platform', 'packageFormat', 'versionName', 'versionCode', 'sourceCommit', 'buildId')
    if (receipt.get('schemaVersion') != 1 or receipt.get('applicationId') != 'com.jim608.jms'
            or receipt.get('architecture') != 'x86_64' or receipt.get('branch') != 'stable'
            or not re.fullmatch(r'[a-f0-9]{64}', receipt.get('ostreeCommit', ''))
            or any(receipt.get(field) != record[field] for field in identity)
            or any(receipt.get('validation', {}).get(field) is not True for field in ('install', 'launch'))):
        raise ReleaseError('Flatpak installed deployment identity or runtime verification is incomplete')
    for field in ('bundle', 'payload'):
        binding = receipt.get(field, {})
        name = flatpak[field]
        if (binding.get('name') != name
                or any(binding.get(key) != files[name][key] for key in ('size', 'sha256'))):
            raise ReleaseError('Flatpak installed deployment is not bound to candidate assets')
    manifest = json.loads((directory / flatpak['buildManifest']).read_text(encoding='utf-8'))
    built = manifest.get('build', {})
    if any(built.get(field) != record[field] for field in identity):
        raise ReleaseError('Flatpak build manifest differs from candidate identity')
    if (manifest.get('runtime') != receipt.get('runtime')
            or manifest.get('ostreeCommit') != receipt['ostreeCommit']
            or not re.fullmatch(r'org\.gnome\.Platform/x86_64/\d+', receipt.get('runtime', ''))
            or manifest.get('binaries') != record['nativeReview'].get('binaries')
            or manifest.get('outputs') != [receipt['bundle'], receipt['payload']]):
        raise ReleaseError('Flatpak manifest outputs, runtime or native binaries differ from installed receipt')
    expected = receipt.get('members')
    if not isinstance(expected, dict) or not expected:
        raise ReleaseError('Flatpak installed member inventory missing')
    actual = {}
    regular_sizes = {}
    binaries = {}
    names = set()
    built = None
    metadata = None
    applications = []
    total = 0
    with tarfile.open(directory / flatpak['payload'], 'r:gz') as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if (member.name in names or path.is_absolute() or '..' in path.parts
                    or path.as_posix() != member.name
                    or '\\' in member.name or member.islnk() or len(names) >= 200000):
                raise ReleaseError('Unsafe or duplicate Flatpak deployment member')
            names.add(member.name)
            if member.issym():
                target = PurePosixPath(member.linkname)
                if (target.is_absolute() or '\\' in member.linkname
                        or len(path.parent.parts) < sum(part == '..' for part in target.parts)):
                    raise ReleaseError('Flatpak deployment symlink escapes the application')
            elif member.isfile():
                total += member.size
                if member.size > MAX_CI_ARCHIVE_BYTES or total > 4 * 1024**3:
                    raise ReleaseError('Flatpak deployment expansion limit exceeded')
                with archive.extractfile(member) as stream:
                    data = stream.read()
                actual[member.name] = hashlib.sha256(data).hexdigest()
                regular_sizes[member.name] = member.size
                if re.search(r'\.so(?:\.\d+)*$', member.name):
                    binaries[member.name] = actual[member.name]
                if member.name == 'files/share/jms/JMS_BUILD_INFO.json':
                    built = json.loads(data)
                if member.name == 'metadata':
                    metadata = data.decode('utf-8')
                if path.name == 'libapp.so':
                    applications.append(record['buildId'].encode() in data)
            elif not member.isdir():
                raise ReleaseError('Unsupported Flatpak deployment member type')
    if actual != expected:
        raise ReleaseError('Flatpak deployment member hashes differ from verified installation')
    for notice in FLATPAK_REQUIRED_LICENSES:
        name = 'files/share/licenses/' + notice
        if regular_sizes.get(name, 0) < 100:
            raise ReleaseError('Installed Flatpak corresponding license/notice is missing or incomplete: ' + notice)
    with zipfile.ZipFile(directory / flatpak['source']) as archive:
        source_license = hashlib.sha256(archive.read('JMS/LICENSE')).hexdigest()
    if actual['files/share/licenses/jms/LICENSE'] != source_license:
        raise ReleaseError('Installed Flatpak JMS license differs from complete committed source')
    if not binaries or binaries != record['nativeReview'].get('binaries'):
        raise ReleaseError('Flatpak native review differs from actual bundled libraries')
    if not isinstance(built, dict) or any(built.get(field) != record[field] for field in identity):
        raise ReleaseError('Installed Flatpak build identity differs from release')
    if applications != [True]:
        raise ReleaseError('Installed Flatpak AOT binary is not bound to the candidate build ID')
    parsed = configparser.ConfigParser(interpolation=None)
    if metadata:
        parsed.read_string(metadata)
    if ('Application' not in parsed or parsed['Application'].get('name') != 'com.jim608.jms'
            or parsed['Application'].get('runtime') != receipt['runtime']):
        raise ReleaseError('Installed Flatpak metadata has another application identity')
    return receipt


def validate_flatpak_inventory(directory, record):
    if (record.get('repository') != REPOSITORIES['linux'] or record.get('platform') != 'linux-x64'
            or record.get('sourceRepository') != 'jim608/JMS-Android'
            or not re.fullmatch(r'[a-f0-9]{40}', record.get('sourceCommit', ''))):
        raise ReleaseError('Flatpak shared source/repository identity mismatch')
    release_tag(record)
    expected_id = 'JMS-' + record['versionName'] + '-flatpak-' + record['sourceCommit'][:12]
    review = record.get('nativeReview', {})
    if (record.get('buildId') != expected_id or review.get('platform') != 'linux-x64'
            or review.get('missing') != [] or not review.get('materials')
            or any(record.get('validation', {}).get(field) is not True for field in ('install', 'launch'))):
        raise ReleaseError('Flatpak build identity, native materials or installed launch proof missing')
    files = prepared_assets(directory, record)
    flatpak = record['flatpak']
    required = {flatpak[field] for field in
                ('bundle', 'payload', 'receipt', 'buildManifest', 'nativeSources', 'source')}
    required.update(review['materials'])
    required.update(('RELEASE_NOTES.md', 'SHA256SUMS.txt'))
    if not required.issubset(files) or not flatpak['bundle'].endswith('.flatpak'):
        raise ReleaseError('Flatpak release asset inventory is incomplete')
    if ('update-linux.json' in files or any(name.endswith(('.pkg.tar.xz', '.pkg.tar.zst')) for name in files)
            or len([name for name in files if name.endswith('.flatpak')]) != 1):
        raise ReleaseError('Flatpak-only release must not supply pacman update metadata or packages')
    provenance = verify_flatpak_ci(record, files)
    verify_flatpak_payload(directory, record, files)
    native = json.loads((directory / flatpak['nativeSources']).read_text(encoding='utf-8'))
    if (not native.get('sources') or any(native.get('build', {}).get(field) != record[field]
            for field in ('platform', 'packageFormat', 'versionName', 'versionCode', 'sourceCommit', 'buildId'))
            or review.get('evidence') != flatpak['nativeSources']):
        raise ReleaseError('Flatpak native source evidence differs from the candidate')
    if len(review['materials']) != 1:
        raise ReleaseError('Flatpak exact corresponding source material archive required')
    with tarfile.open(directory / review['materials'][0], 'r:gz') as archive:
        if json.load(archive.extractfile('source-materials.json')) != native:
            raise ReleaseError('Flatpak native source archive differs from evidence manifest')
    privacy = scan_packages_cached([entry['path'] for entry in files.values()], load_policy(),
        ROOT / git('rev-parse', '--git-path', 'jms-privacy-cache'),
        flatpak_bindings={flatpak['bundle']: {
            'payloadPath': files[flatpak['payload']]['path'],
            'payloadSha256': files[flatpak['payload']]['sha256'],
            'provenanceSha256': provenance}})
    if not privacy.get('complete') or not privacy.get('accepted'):
        raise ReleaseError('Flatpak release asset privacy review required')
    with zipfile.ZipFile(directory / flatpak['source']) as archive:
        version = re.search(rb'^version:\s*(\S+)', archive.read('JMS/pubspec.yaml'), re.M)
        if not version or version[1].decode() != record['versionName'] + '+' + str(record['versionCode']):
            raise ReleaseError('Flatpak complete source version differs from release')
        with tempfile.TemporaryDirectory(prefix='jms-flatpak-notes-') as temporary:
            changelog = Path(temporary) / 'CHANGELOG.md'
            changelog.write_bytes(archive.read('JMS/CHANGELOG.md'))
            canonical = release_notes_for(changelog, record['versionName'])
    if (record.get('canonicalNotes') != canonical
            or record.get('canonicalNotesCommit') != record['sourceCommit']
            or (directory / 'RELEASE_NOTES.md').read_text(encoding='utf-8') != release_body_for_candidate(
                canonical, record['versionName'], record['sourceCommit'], record['buildId'])):
        raise ReleaseError('Flatpak release notes differ from canonical candidate source/identity')
    verify_source_archive(directory / flatpak['source'], record['sourceCommit'])
    checksums = (directory / 'SHA256SUMS.txt').read_text(encoding='ascii').splitlines()
    expected = {entry['sha256'] + '  ' + name for name, entry in files.items() if name != 'SHA256SUMS.txt'}
    if set(checksums) != expected or len(checksums) != len(expected):
        raise ReleaseError('Flatpak checksum inventory is incomplete or ambiguous')
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
    tag = release_tag(record)
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
                          'releaseCommit': release_commit, 'tag': tag, 'assets': len(files)}))
        return
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
