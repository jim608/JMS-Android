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
from pathlib import Path

import yaml
from package_jms_flatpak import ROOT, identity, item

BASELINE_COMMIT = '8ee653a242171c02d639a770a4965cf2bdc33e8d'
BASELINE_NAME = 'JMS-Third-Party-Sources-20261024.tar.gz'
BASELINE_SHA = '4674801f277f2b32b31f00248c1646da6106456aa5dc9aa512a1ea5b03877519'
BASELINE_SIZE = 310532681
BASELINE_URL = 'https://github.com/jim608/JMS-SteamDeck/releases/download/v0.11.1-jms.46-deck-test.20261024/' + BASELINE_NAME


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


def collect(manifest_path, output, commit):
    build = identity(commit)
    # Only unchanged native plugin/toolchain inputs can reuse the fixed prior sources.
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
        baseline = work / BASELINE_NAME
        download(BASELINE_URL, baseline, BASELINE_SHA, limit=512 * 1024 * 1024)
        if baseline.stat().st_size != BASELINE_SIZE:
            raise ValueError('Pinned corresponding-source baseline size differs')
        with tarfile.open(destination, 'w:gz') as materials:
            materials.add(baseline, arcname='unchanged-native-plugins/' + BASELINE_NAME)
            for module in modules(manifest):
                for index, source in enumerate(module.get('sources', [])):
                    kind = source['type']
                    if kind in ('dir', 'file', 'patch', 'shell') and 'url' not in source:
                        continue  # Covered by exact full JMS source ZIP.
                    name = module['name']
                    if kind == 'archive':
                        target = work / f'{name}-{index}.source'
                        download(source['url'], target, source['sha256'])
                        archived = f'components/{name}/' + source['url'].rsplit('/', 1)[-1]
                        materials.add(target, arcname=archived)
                        records.append({'module': name, 'url': source['url'], 'sha256': source['sha256'], 'member': archived})
                    elif kind == 'git':
                        revision = source.get('commit', '')
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
            baseline_record = {'module': 'unchanged-native-plugins', 'url': BASELINE_URL, 'sha256': BASELINE_SHA,
                               'sourceCommit': BASELINE_COMMIT,
                               'unchangedInputs': ['Dockerfile.linux', 'linux/CMakeLists.txt']}
            if lock_proof is None:
                baseline_record['unchangedInputs'].insert(0, 'pubspec.lock')
            else:
                baseline_record['lockMetadataEquivalence'] = lock_proof
            records.append(baseline_record)
            evidence = json.dumps({'build': build, 'sources': records,
                                   'runtime': {'id': manifest['runtime'], 'branch': manifest['runtime-version'],
                                               'sourceProject': 'https://gitlab.gnome.org/GNOME/gnome-build-meta'}}, indent=2).encode()
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
