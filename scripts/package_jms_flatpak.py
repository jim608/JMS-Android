"""Stage and inventory the GitHub Flatpak distribution from an exact source build."""
import argparse
import configparser
import hashlib
import json
import re
import shutil
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_ID = 'com.jim608.jms'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def item(path):
    return {'name': path.name, 'size': path.stat().st_size, 'sha256': digest(path)}


def identity(commit):
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ValueError('Full committed source identity required')
    match = re.search(r'^version:\s*([^+\s]+)\+(\d+)', (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    version, code = match[1], int(match[2])
    return {'applicationId': APP_ID, 'platform': 'linux-x64', 'packageFormat': 'flatpak',
            'versionName': version, 'versionCode': code, 'sourceCommit': commit,
            'buildId': f'JMS-{version}-flatpak-{commit[:12]}'}


def stage(bundle, output, commit):
    build = identity(commit)
    if output.exists():
        raise ValueError('Staging directory exists; refusing replacement')
    if not (bundle / 'jms').is_file() or not (bundle / 'lib/libapp.so').is_file():
        raise ValueError('Actual Flutter release bundle required')
    for path in bundle.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError('Escaping source bundle symlink')
        if any(word in path.name.lower() for word in ('mdk', 'fvp')):
            raise ValueError('Excluded player dependency present')
    shutil.copytree(ROOT / 'flatpak', output, ignore=shutil.ignore_patterns('shared-modules'))
    shutil.copy2(ROOT / 'icons/jms/mark.svg', output / 'jms.svg')
    shutil.copy2(ROOT / 'LICENSE', output / 'LICENSE')
    # The manifest only receives the reviewed release bundle, never the workspace.
    shutil.copytree(bundle, output / 'payload', symlinks=True)
    (output / 'payload/JMS_BUILD_INFO.json').write_text(json.dumps(build, indent=2) + '\n', encoding='utf-8')
    return build


def inventory(deployment, bundle, output, commit, ostree_commit):
    build = identity(commit)
    if not re.fullmatch('[a-f0-9]{64}', ostree_commit):
        raise ValueError('Installed OSTree commit required')
    metadata = configparser.ConfigParser(interpolation=None)
    metadata.read(deployment / 'metadata', encoding='utf-8')
    if metadata['Application']['name'] != APP_ID:
        raise ValueError('Installed application ID differs')
    runtime = metadata['Application']['runtime']
    if not re.fullmatch(r'org\.gnome\.Platform/x86_64/\d+', runtime):
        raise ValueError('Unexpected Flatpak runtime/architecture')
    installed = json.loads((deployment / 'files/share/jms/JMS_BUILD_INFO.json').read_text(encoding='utf-8'))
    if installed != build:
        raise ValueError('Installed build identity differs')
    files = [deployment / 'metadata'] + sorted((deployment / 'files').rglob('*'))
    members = {}
    for path in files:
        relative = path.relative_to(deployment).as_posix()
        if path.is_symlink():
            target = path.readlink()
            if target.is_absolute() or not path.resolve().is_relative_to(deployment.resolve()):
                # OSTree's deployment lock is internal and not application data.
                if relative == 'files/.ref':
                    continue
                raise ValueError('Escaping installed payload symlink: ' + relative)
        elif path.is_file():
            members[relative] = digest(path)
    output.mkdir(parents=True, exist_ok=True)
    validation = json.loads((output / 'validation/runtime-validation.json').read_text(encoding='utf-8'))
    if validation.get('install') is not True or validation.get('launch') is not True:
        raise ValueError('Installed runtime verification required before inventory')
    payload = output / f'JMS-Linux-{build["versionName"]}-flatpak-payload.tar.gz'
    if payload.exists():
        raise ValueError('Payload evidence already exists')
    with tarfile.open(payload, 'w:gz', dereference=False) as archive:
        for path in files:
            relative = path.relative_to(deployment).as_posix()
            if relative == 'files/.ref':
                continue
            info = archive.gettarinfo(str(path), arcname=relative)
            if relative in members:
                # OSTree deployments often hardlink equal files. Evidence contains
                # complete regular bytes, with no dependency on extraction order.
                info.type = tarfile.REGTYPE
                info.linkname = ''
                info.size = path.stat().st_size
                with path.open('rb') as stream:
                    archive.addfile(info, stream)
            else:
                archive.addfile(info)
    verification = {
        'schemaVersion': 1, **build, 'architecture': 'x86_64', 'branch': 'stable',
        'runtime': runtime, 'ostreeCommit': ostree_commit,
        'bundle': item(bundle), 'payload': item(payload), 'members': members,
        'validation': validation,
    }
    (output / 'flatpak-verification.json').write_text(json.dumps(verification, indent=2) + '\n', encoding='utf-8')
    (output / 'flatpak-build-manifest.json').write_text(json.dumps({
        'build': build, 'runtime': runtime, 'ostreeCommit': ostree_commit,
        'outputs': [item(bundle), item(payload)],
        'binaries': {name: sha for name, sha in members.items()
                     if re.search(r'\.so(?:\.\d+)*$', name)},
    }, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-commit', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('stage')
    prepare.add_argument('--bundle', type=Path, required=True)
    prepare.add_argument('--output', type=Path, required=True)
    verify = commands.add_parser('inventory')
    verify.add_argument('--deployment', type=Path, required=True)
    verify.add_argument('--bundle', type=Path, required=True)
    verify.add_argument('--output', type=Path, required=True)
    verify.add_argument('--ostree-commit', required=True)
    args = parser.parse_args()
    if args.command == 'stage':
        stage(args.bundle, args.output, args.source_commit)
    else:
        inventory(args.deployment, args.bundle, args.output, args.source_commit, args.ostree_commit)


if __name__ == '__main__':
    main()
