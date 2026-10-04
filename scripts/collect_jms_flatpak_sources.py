"""Collect exact corresponding sources for newly bundled Flatpak media libraries."""
import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

import yaml
from package_jms_flatpak import ROOT, identity, item

BASELINE_COMMIT = '6cb548f1814e4700676aca63c7789b906c847ad3'
BASELINE_NAME = 'JMS-Linux-0.11.1-jms.33-native-materials.zip'
BASELINE_SHA = '25cc8cb9ed1f8123328bbad3fda5c69ecae4a6cbb59d038e260c0a079edaee0c'
BASELINE_URL = 'https://github.com/jim608/JMS-Linux/releases/download/v0.11.1-jms.33/' + BASELINE_NAME


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd)


def download(url, destination, expected, limit=256 * 1024 * 1024):
    if not url.startswith('https://') or not re.fullmatch('[a-f0-9]{64}', expected):
        raise ValueError('Pinned HTTPS source archive required')
    with urllib.request.urlopen(url, timeout=60) as response, destination.open('wb') as stream:
        count = 0
        digest = hashlib.sha256()
        while block := response.read(1024 * 1024):
            count += len(block)
            if count > limit:
                raise ValueError('Source archive exceeds bounded download size')
            digest.update(block)
            stream.write(block)
    if digest.hexdigest() != expected:
        raise ValueError('Source archive SHA256 differs')


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


def collect(manifest_path, output, commit):
    build = identity(commit)
    # Only unchanged native plugin/toolchain inputs can reuse the fixed prior sources.
    for path in ('pubspec.lock', 'Dockerfile.linux', 'linux/CMakeLists.txt'):
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
        download(BASELINE_URL, baseline, BASELINE_SHA)
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
            records.append({'module': 'unchanged-native-plugins', 'url': BASELINE_URL, 'sha256': BASELINE_SHA,
                            'sourceCommit': BASELINE_COMMIT, 'unchangedInputs': ['pubspec.lock', 'Dockerfile.linux', 'linux/CMakeLists.txt']})
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
