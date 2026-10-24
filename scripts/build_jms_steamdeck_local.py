"""Build a fingerprinted Steam Deck TEST bundle using an existing Linux SDK only.

No package installation, SDK download, WSL/service startup, publication or app launch.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

FLUTTER_REVISION = 'adc901062556672b4138e18a4dc62a4be8f4b3c2'
TOOLS = ('python3', 'flutter', 'clang++', 'cmake', 'ninja', 'pkg-config')
PACKAGES = ('gtk+-3.0', 'mpv', 'alsa', 'libsecret-1')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_source(root, manifest):
    root = Path(root).resolve(strict=True)
    files = manifest['files']
    if not files:
        raise ValueError('Empty source manifest')
    actual = {}
    for name, expected in files.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or '\\' in name or ':' in name:
            raise ValueError('Unsafe source member')
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError('Missing or escaping source member: ' + name)
        actual[name] = digest(path)
        if actual[name] != expected:
            raise ValueError('Source SHA mismatch: ' + name)
    fingerprint = hashlib.sha256(json.dumps(actual, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if fingerprint != manifest['source_fingerprint']:
        raise ValueError('Source fingerprint mismatch')
    return fingerprint


def isolated_network():
    try:
        return {p.name for p in Path('/sys/class/net').iterdir()} == {'lo'}
    except OSError:
        return False


def preflight():
    report = {'host': platform.system(), 'machine': platform.machine(), 'ready': False,
              'install_attempted': False, 'app_launched': False, 'missing': []}
    if platform.system() != 'Linux' or platform.machine().lower() not in ('x86_64', 'amd64'):
        report['missing'].append('existing Linux x86-64 build environment')
        return report
    report['existing_network_namespace_isolated'] = isolated_network()
    if not report['existing_network_namespace_isolated']:
        report['missing'].append('existing network-isolated Linux builder (loopback only); no network changes are performed')
        return report
    missing_tools = [tool for tool in TOOLS if not shutil.which(tool)]
    report['missing'].extend(missing_tools)
    if missing_tools:
        return report
    flutter = Path(shutil.which('flutter')).resolve()
    sdk = flutter.parent.parent
    cache = sdk / 'bin/cache'
    # Read existing cache metadata before invoking any Flutter wrapper/tool.
    # The wrapper can bootstrap/download its Dart SDK if cache files are absent.
    required = ['bin/cache/dart-sdk/bin/dart', 'bin/cache/flutter_tools.snapshot',
                'packages/flutter_tools/.dart_tool/package_config.json',
                'bin/cache/flutter.version.json',
                'bin/cache/artifacts/engine/linux-x64-release/gen_snapshot',
                'bin/cache/artifacts/engine/linux-x64-release/libflutter_linux_gtk.so',
                'bin/cache/artifacts/engine/linux-x64/icudtl.dat',
                'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']
    for name in required:
        if not (sdk / name).is_file() or not (sdk / name).stat().st_size:
            report['missing'].append('cached SDK file: ' + name)
    headers = [cache / f'artifacts/engine/{mode}/flutter_linux/flutter_linux.h'
               for mode in ('linux-x64', 'linux-x64-release')]
    if not any(path.is_file() and path.stat().st_size for path in headers):
        report['missing'].append('cached Flutter Linux embedder headers')
    if report['missing']:
        return report
    try:
        version = json.loads((cache / 'flutter.version.json').read_text(encoding='utf-8'))
    except (ValueError, OSError):
        report['missing'].append('readable existing Flutter SDK metadata')
        return report
    report['flutter_revision'] = version.get('frameworkRevision')
    if version.get('frameworkRevision') != FLUTTER_REVISION:
        report['missing'].append('pinned existing Flutter 3.35.7 (' + FLUTTER_REVISION + ')')
    report['dart'] = str(cache / 'dart-sdk/bin/dart')
    report['flutter_tools'] = str(cache / 'flutter_tools.snapshot')
    report['linux_release_engine_cached'] = True
    for package in PACKAGES:
        result = subprocess.run(['pkg-config', '--exists', package], capture_output=True)
        if result.returncode:
            report['missing'].append('pkg-config: ' + package)
    report['ready'] = not report['missing']
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--verify-only', action='store_true')
    modes.add_argument('--preflight-only', action='store_true')
    args = parser.parse_args(argv)
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    fingerprint = verify_source(args.source, manifest)
    if args.verify_only:
        print(json.dumps({'source_verified': True, 'files': len(manifest['files']), 'source_fingerprint': fingerprint}))
        return 0
    if any((args.source / 'build/linux').glob('**/CMakeCache.txt')):
        raise ValueError('Existing Linux CMake cache is preserved; use a fresh source copy for offline toolchain settings')
    if args.output is None or args.output.exists():
        raise ValueError('A new output directory is required; previous attempts are preserved')
    if not re.fullmatch(r'[a-f0-9]{40}', manifest['base_commit']):
        raise ValueError('Expected full base commit identity')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-[a-zA-Z0-9.-]+', manifest['version']):
        raise ValueError('An explicit local TEST version is required')
    args.output.mkdir(parents=True)
    report = preflight()
    (args.output / 'preflight.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    if not report['ready'] or args.preflight_only:
        print(json.dumps(report))
        return 0 if report['ready'] else 2
    env = os.environ.copy()
    env.update({'FLUTTER_SUPPRESS_ANALYTICS': 'true', 'CARGO_NET_OFFLINE': 'true'})
    toolchain = args.output.resolve() / 'offline-toolchain.cmake'
    toolchain.write_text('set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "Existing local cache only" FORCE)\n', encoding='utf-8')
    env['CMAKE_TOOLCHAIN_FILE'] = str(toolchain)
    flutter_tool = [report['dart'], report['flutter_tools']]
    commands = [
        [*flutter_tool, 'pub', 'get', '--offline', '--enforce-lockfile'],
        [*flutter_tool, 'build', 'linux', '--release', '--no-pub', '--target=lib/main.dart',
         '--build-name=' + manifest['version'], '--build-number=' + str(manifest['build_number']),
         '--dart-define=JMS_BUILD_ID=' + manifest['build_id'],
         '--dart-define=JMS_SOURCE_COMMIT=' + manifest['base_commit']],
    ]
    results = []
    for index, command in enumerate(commands):
        with (args.output / f'build-{index}.log').open('w', encoding='utf-8') as log:
            result = subprocess.run(command, cwd=args.source.resolve(), env=env, stdout=log, stderr=subprocess.STDOUT)
        results.append({'command': command, 'exit_code': result.returncode})
        (args.output / 'commands.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
        if result.returncode:
            return result.returncode
    verify_source(args.source, manifest)
    command = [sys.executable, str(args.source / 'scripts/package_jms_steamdeck.py'),
               '--bundle', str(args.source / 'build/linux/x64/release/bundle'),
               '--output', str(args.output / 'package'), '--version', manifest['version'],
               '--build-number', str(manifest['build_number']), '--source-commit', manifest['base_commit'],
               '--source-fingerprint', fingerprint, '--license', str(args.source / 'LICENSE'),
               '--notices', str(args.source / 'assets/licenses/JMS_NATIVE_NOTICES.txt')]
    result = subprocess.run(command, env=env)
    print(json.dumps({'package_exit': result.returncode, 'source_verified_after_build': True,
                      'app_launched': False, 'hardware_verified': False}))
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
