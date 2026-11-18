"""Collect exact corresponding sources for newly bundled Flatpak media libraries."""
import argparse
import hashlib
import io
import errno
import http.client
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import socket
import ssl
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import yaml
from package_jms_flatpak import ROOT, identity, item

BASELINE_COMMIT = '8ee653a242171c02d639a770a4965cf2bdc33e8d'
BASELINE_NAME = 'JMS-Third-Party-Sources-20261024.tar.gz'
BASELINE_SHA = '4674801f277f2b32b31f00248c1646da6106456aa5dc9aa512a1ea5b03877519'
BASELINE_SIZE = 310532681
BASELINE_URL = 'https://github.com/jim608/JMS-SteamDeck/releases/download/v0.11.1-jms.46-deck-test.20261024/' + BASELINE_NAME
UCHARDET_URL = 'https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz'
UCHARDET_SHA = 'e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0'
APP_SOURCE_REVIEW = Path(__file__).with_name('jms_flatpak_app_sources.json')
APP_SOURCE_INPUTS = ('pubspec.lock', 'Dockerfile.linux', 'linux/CMakeLists.txt',
                     'linux/flutter/generated_plugins.cmake')


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd)


def _transient_download_error(error):
    if isinstance(error, urllib.error.HTTPError):
        return error.code in {408, 429, 500, 502, 503, 504}
    if isinstance(error, urllib.error.URLError):
        error = error.reason
    if isinstance(error, ssl.SSLError):
        return False  # Never retry certificate/verification or TLS policy errors.
    if isinstance(error, socket.gaierror):
        return error.errno == socket.EAI_AGAIN
    return isinstance(error, (TimeoutError, ConnectionError, http.client.IncompleteRead)) or (
        isinstance(error, OSError) and error.errno in {
            errno.ETIMEDOUT, errno.ECONNRESET, errno.ECONNABORTED,
            errno.EHOSTUNREACH, errno.ENETUNREACH,
        })


def download(url, destination, expected, limit=256 * 1024 * 1024):
    if not url.startswith('https://') or not re.fullmatch('[a-f0-9]{64}', expected):
        raise ValueError('Pinned HTTPS source archive required')
    if not isinstance(limit, int) or isinstance(limit, bool) or limit <= 0:
        raise ValueError('Positive bounded source size required')
    # Retry only transient connect/read failures, at most three times, against
    # the identical pinned URL. Each attempt starts with an empty private file.
    for attempt in range(3):
        with tempfile.TemporaryDirectory(prefix='.jms-source-download-', dir=destination.parent) as temporary:
            partial = Path(temporary) / 'archive.partial'
            try:
                response = urllib.request.urlopen(url, timeout=60)
            except Exception as error:
                if attempt == 2 or not _transient_download_error(error):
                    raise
            else:
                retry = False
                with response:
                    final_url = response.geturl()
                    if not isinstance(final_url, str) or not final_url.startswith('https://'):
                        raise ValueError('Source archive response left pinned HTTPS transport')
                    with partial.open('wb') as stream:
                        count = 0
                        digest = hashlib.sha256()
                        while True:
                            try:
                                block = response.read(1024 * 1024)
                            except Exception as error:
                                if attempt == 2 or not _transient_download_error(error):
                                    raise
                                retry = True
                                break
                            if not block:
                                break
                            count += len(block)
                            if count > limit:
                                raise ValueError('Source archive exceeds bounded download size')
                            digest.update(block)
                            stream.write(block)
                if not retry:
                    # Integrity and local file failures are never retried.
                    if digest.hexdigest() != expected:
                        raise ValueError('Source archive SHA256 differs')
                    partial.replace(destination)
                    return
        # Discard the partial before waiting. Fixed delays total only 3 seconds.
        time.sleep(attempt + 1)


def pinned_archive(source, destination, manifest_directory):
    """Reuse the exact reviewed source already committed with the application."""
    url, expected = source['url'], source['sha256']
    if url != UCHARDET_URL or expected != UCHARDET_SHA:
        download(url, destination, expected)
        return
    committed = manifest_directory / 'uchardet-0.0.8.tar.xz'
    if (not committed.is_file() or committed.stat().st_size > 256 * 1024 * 1024
            or hashlib.sha256(committed.read_bytes()).hexdigest() != expected):
        raise ValueError('Committed pinned uchardet archive differs')
    shutil.copyfile(committed, destination)


def export_git(repository, commit, archive, prefix, depth=0):
    if depth > 8 or not re.fullmatch('[a-f0-9]{40}', commit):
        raise ValueError('Invalid pinned source revision')
    with tarfile.open(fileobj=io.BytesIO(git('archive', '--format=tar', commit, cwd=repository))) as source:
        for member in source:
            if member.name.startswith('/') or '..' in Path(member.name).parts:
                raise ValueError('Unsafe native source member')
            member.name = prefix + member.name
            archive.addfile(member, source.extractfile(member) if member.isfile() else None)
    for raw in git('ls-tree', '-rz', commit, cwd=repository).split(b'\0'):
        if not raw:
            continue
        meta, path = raw.split(b'\t', 1)
        _, kind, revision = meta.decode().split()
        if kind == 'commit':
            relative = path.decode()
            export_git(repository / relative, revision, archive, prefix + relative + '/', depth + 1)


def modules(manifest):
    for module in manifest.get('modules', []):
        if not isinstance(module, dict):
            raise ValueError('External modules must be included in the reviewed manifest')
        yield from modules(module)
        yield module



def prove_baseline_lock_metadata(before, current):
    """Accept only the reviewed dbus classification change, never new sources."""
    if before == current:
        return None
    before_sha = hashlib.sha256(before).hexdigest()
    current_sha = hashlib.sha256(current).hexdigest()
    if (before_sha, current_sha) != (
            'fe711da11c425511a3f9532f1844eca7f61cde55236ec417daf503e5d46fe279',
            '8b9731738677e4d0cd18e7592210f7b0eaf37a711052d5d78b66b5d43856ad19'):
        raise ValueError('Native baseline source changed: pubspec.lock')
    baseline = yaml.safe_load(before)
    changed = yaml.safe_load(current)
    if (baseline['packages']['dbus']['dependency'] != 'transitive'
            or changed['packages']['dbus']['dependency'] != 'direct main'):
        raise ValueError('Reviewed dbus classification differs')
    changed['packages']['dbus']['dependency'] = 'transitive'
    if changed != baseline:
        raise ValueError('Resolved package versions, hashes or sources differ')
    return {'baselineLockSHA256': before_sha, 'currentLockSHA256': current_sha,
            'onlyChangedField': 'packages.dbus.dependency',
            'before': 'transitive', 'after': 'direct main',
            'resolvedPackageVersionsHashesSourcesAndSdksIdentical': True,
            'currentExactLockLocation': 'full-corresponding-application-source-zip'}


def reviewed_application_sources(commit, build, output):
    review = json.loads(APP_SOURCE_REVIEW.read_bytes())
    if build['versionName'] != review['versionName']:
        return None

    for path in APP_SOURCE_INPUTS:
        digest = hashlib.sha256(git('show', commit + ':' + path)).hexdigest()
        if digest != review['inputs'].get(path):
            raise ValueError('Reviewed Flatpak source changed: ' + path)

    installed = json.loads((output / 'flatpak-build-manifest.json').read_bytes())
    application_prefix = 'files/lib/jms/lib/'
    binaries = {name.removeprefix(application_prefix) for name in installed['binaries']
                if name.startswith(application_prefix)}
    if installed['build'] != build or binaries != set(review['binaries']):
        raise ValueError('Unreviewed installed Flatpak application libraries')
    return review


def reviewed_media_archives(baseline, manifest, work):
    reviewed = {(entry['module'], entry['url'], entry['commit']): entry for entry in baseline['archives']}
    selected = {(module['name'], source['url'], source['commit']) for module in modules(manifest)
                for source in module.get('sources', []) if source['type'] == 'git'}
    if (selected != reviewed.keys() or len(reviewed) != len(baseline['archives'])
            or any(not url.startswith('https://') or not re.fullmatch('[a-f0-9]{40}', commit)
                   or entry['member'] != f'components/{module}-{commit}.tar.gz'
                   for (module, url, commit), entry in reviewed.items())):
        raise ValueError('Reviewed Flatpak media source inputs differ')

    prior = work / 'previous-native-materials.tar.gz'
    download(baseline['url'], prior, baseline['sha256'], limit=512 * 1024 * 1024)
    if prior.stat().st_size != baseline['size']:
        raise ValueError('Reviewed Flatpak media archive size differs')
    pending = {entry['member']: entry for entry in reviewed.values()}
    with tarfile.open(prior, 'r|gz') as archive:
        for member in archive:
            if member.name not in pending:
                continue
            if not member.isfile() or member.size > 256 * 1024 * 1024:
                raise ValueError('Invalid reviewed Flatpak media source member')
            target = work / Path(member.name).name
            with archive.extractfile(member) as source, target.open('wb') as destination:
                shutil.copyfileobj(source, destination)
            with target.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            if digest != pending.pop(member.name)['sha256']:
                raise ValueError('Reviewed Flatpak media source member differs: ' + member.name)
            if not pending:
                break
    if pending:
        raise ValueError('Required reviewed Flatpak media sources are missing')
    return reviewed


def collect(manifest_path, output, commit):
    build = identity(commit)
    review = reviewed_application_sources(commit, build, output)
    if review is None:
        # Reuse the prior material only for its reviewed inputs.
        lock_proof = prove_baseline_lock_metadata(
            git('show', BASELINE_COMMIT + ':pubspec.lock'), git('show', commit + ':pubspec.lock'))
        for path in ('Dockerfile.linux', 'linux/CMakeLists.txt'):
            if git('show', BASELINE_COMMIT + ':' + path) != git('show', commit + ':' + path):
                raise ValueError('Native baseline source changed: ' + path)
    manifest = yaml.safe_load(manifest_path.read_text(encoding='utf-8'))
    material_name = f'JMS-Linux-{build["versionName"]}-flatpak-native-materials.tar.gz'
    destination = output / material_name
    if destination.exists():
        raise ValueError('Native source material already exists; refusing replacement')
    records = []
    with tempfile.TemporaryDirectory(prefix='jms-flatpak-sources-') as temporary:
        work = Path(temporary)
        prior_media = review.get('previousMediaMaterials') if review is not None else None
        reused = reviewed_media_archives(prior_media, manifest, work) if prior_media else {}
        with tarfile.open(destination, 'w:gz') as materials:
            if review is None:
                baseline = work / BASELINE_NAME
                download(BASELINE_URL, baseline, BASELINE_SHA, limit=512 * 1024 * 1024)
                if baseline.stat().st_size != BASELINE_SIZE:
                    raise ValueError('Pinned corresponding-source baseline size differs')
                materials.add(baseline, arcname='unchanged-native-plugins/' + BASELINE_NAME)
                baseline_record = {'module': 'unchanged-native-plugins', 'url': BASELINE_URL,
                                   'sha256': BASELINE_SHA, 'sourceCommit': BASELINE_COMMIT,
                                   'unchangedInputs': ['Dockerfile.linux', 'linux/CMakeLists.txt']}
                if lock_proof is None:
                    baseline_record['unchangedInputs'].insert(0, 'pubspec.lock')
                else:
                    baseline_record['lockMetadataEquivalence'] = lock_proof
            else:
                for source in review['archives']:
                    target = work / Path(source['member']).name
                    if 'archiveMember' in source:
                        archive_path = target.with_suffix('.zip')
                        download(source['url'], archive_path, source['archiveSha256'])
                        with zipfile.ZipFile(archive_path) as upstream:
                            member = upstream.getinfo(source['archiveMember'])
                            if member.file_size > 4 * 1024 * 1024:
                                raise ValueError('Flatpak upstream notice exceeds inspection limit')
                            payload = upstream.read(member)
                        if hashlib.sha256(payload).hexdigest() != source['sha256']:
                            raise ValueError('Flatpak upstream notice differs')
                        target.write_bytes(payload)
                    else:
                        download(source['url'], target, source['sha256'])
                    materials.add(target, arcname=source['member'])
                    records.append(source)
            for module in modules(manifest):
                for index, source in enumerate(module.get('sources', [])):
                    kind = source['type']
                    if kind in ('dir', 'file', 'patch', 'shell') and 'url' not in source:
                        continue  # Covered by exact full JMS source ZIP.
                    name = module['name']
                    if kind == 'archive':
                        target = work / f'{name}-{index}.source'
                        pinned_archive(source, target, manifest_path.parent)
                        archived = f'components/{name}/' + source['url'].rsplit('/', 1)[-1]
                        materials.add(target, arcname=archived)
                        records.append({'module': name, 'url': source['url'], 'sha256': source['sha256'], 'member': archived})
                    elif kind == 'git':
                        revision = source.get('commit', '')
                        pinned = reused.get((name, source['url'], revision))
                        if pinned is not None:
                            materials.add(work / Path(pinned['member']).name, arcname=pinned['member'])
                            records.append(pinned)
                            continue
                        if not re.fullmatch('[a-f0-9]{40}', revision) or not source['url'].startswith('https://'):
                            raise ValueError('Exact official Git source required')
                        repository = work / f'{name}-{index}-git'
                        subprocess.run(['git', 'clone', '--filter=blob:none', '--no-checkout', source['url'], str(repository)], check=True)
                        subprocess.run(['git', 'checkout', '--detach', revision], cwd=repository, check=True)
                        subprocess.run(['git', 'submodule', 'update', '--init', '--recursive'], cwd=repository, check=True)
                        if git('rev-parse', 'HEAD', cwd=repository).decode().strip() != revision:
                            raise ValueError('Native source revision differs')
                        source_archive = work / f'{name}-{revision}.tar.gz'
                        with tarfile.open(source_archive, 'w:gz') as archive:
                            export_git(repository, revision, archive, name + '/')
                        archived = 'components/' + source_archive.name
                        materials.add(source_archive, arcname=archived)
                        records.append({'module': name, 'url': source['url'], 'commit': revision,
                                        'sha256': item(source_archive)['sha256'], 'member': archived})
                    else:
                        raise ValueError('Unsupported external native source type: ' + kind)
            if review is None:
                records.append(baseline_record)
            receipt = {'build': build, 'sources': records,
                       'runtime': {'id': manifest['runtime'], 'branch': manifest['runtime-version'],
                                   'sourceProject': 'https://gitlab.gnome.org/GNOME/gnome-build-meta'}}
            if review is not None:
                receipt['application'] = {key: review[key] for key in ('inputs', 'binaries')}
            if prior_media:
                receipt['previousMediaMaterials'] = {key: prior_media[key] for key in ('url', 'sha256', 'size')}
            evidence = json.dumps(receipt, indent=2).encode()
            info = tarfile.TarInfo('source-materials.json')
            info.size = len(evidence)
            materials.addfile(info, io.BytesIO(evidence))
    (output / 'flatpak-native-sources.json').write_text(evidence.decode() + '\n', encoding='utf-8')
    print(json.dumps(item(destination)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    collect(args.manifest, args.output, args.source_commit)


if __name__ == '__main__':
    main()
