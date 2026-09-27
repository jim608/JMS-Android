import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import time
from pathlib import Path


def package_version(version, code):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version) or code < 1:
        raise ValueError('Invalid Linux version')
    return version.replace('-', '_', 1) + '-' + str(code)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--build-id', required=True)
    parser.add_argument('--output', type=Path, default=Path('/output'))
    args = parser.parse_args()
    if not re.fullmatch('[a-f0-9]{40}', args.source_commit):
        raise ValueError('Exact source commit required')
    match = re.search(r'^version:\s*(\S+)\+(\d+)\s*$', Path('pubspec.yaml').read_text(), re.M)
    version, code = match.group(1), int(match.group(2))
    if args.build_id != f'JMS-{version}-linux-{args.source_commit[:12]}':
        raise ValueError('Build identity differs')
    native_version = package_version(version, code)
    bundle = Path('build/linux/x64/release/bundle')
    if not (bundle / 'jms').is_file():
        raise ValueError('Linux executable missing')
    for path in bundle.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError('Bundle contains escaping symlink')
        if any(part in path.name.lower() for part in ('mdk', 'fvp', 'libmpv', 'libass', 'libavcodec')):
            raise ValueError('System media libraries must not be bundled')
    args.output.mkdir(parents=True, exist_ok=True)
    stage = args.output / 'package-root'
    stage.mkdir()
    install = stage / 'opt/jms'
    install.parent.mkdir(parents=True)
    shutil.copytree(bundle, install, symlinks=True)
    shutil.copy2('LICENSE', install / 'LICENSE')
    metadata = {
        'applicationId': 'com.jim608.jms', 'platform': 'linux-x64',
        'versionName': version, 'versionCode': code, 'packageVersion': native_version,
        'packageFormat': 'arch',
        'buildId': args.build_id, 'sourceCommit': args.source_commit,
        'signing': 'unsigned', 'minGlibcMinor': 36,
        'systemMediaLibraries': True,
    }
    (install / 'JMS_BUILD_INFO.json').write_text(json.dumps(metadata, indent=2) + '\n')
    binary = stage / 'usr/bin'
    binary.mkdir(parents=True)
    (binary / 'jms').symlink_to('/opt/jms/jms')
    desktop = stage / 'usr/share/applications'
    desktop.mkdir(parents=True)
    (desktop / 'com.jim608.jms.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=JMS\nComment=Jim608 Media Server\n'
        'Exec=/opt/jms/jms\nIcon=com.jim608.jms\nTerminal=false\nCategories=AudioVideo;Video;\n')
    icons = stage / 'usr/share/icons/hicolor/512x512/apps'
    icons.mkdir(parents=True)
    shutil.copy2('icons/jms/icon.png', icons / 'com.jim608.jms.png')
    (stage / '.PKGINFO').write_text(
        f'pkgname = jms\npkgbase = jms\npkgver = {native_version}\n'
        f'builddate = {int(time.time())}\npackager = JMS maintainers\n'
        f'size = {sum(path.stat().st_size for path in stage.rglob("*") if path.is_file())}\n'
        'pkgdesc = Jim608 Media Server desktop client\n'
        'url = https://github.com/jim608/JMS-Desktop\n'
        'arch = x86_64\nlicense = GPL-3.0-only\n'
        + ''.join(f'depend = {dependency}\n' for dependency in
                  ['glibc>=2.36', 'gcc-libs', 'gtk3', 'mpv', 'alsa-lib', 'sqlite', 'polkit', 'libarchive']))
    package = args.output / f'JMS-Linux-{version}-x86_64.pkg.tar.xz'
    subprocess.run(['tar', '--owner=0', '--group=0', '-cJf', str(package), '-C', str(stage), '.PKGINFO', 'opt', 'usr'], check=True)
    portable = args.output / f'JMS-Linux-{version}-x64.tar.gz'
    with tarfile.open(portable, 'w:gz') as archive:
        archive.add(install, arcname='JMS')
    outputs = []
    for path in [package, portable]:
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        outputs.append({'name': path.name, 'size': path.stat().st_size, 'sha256': digest})
    (args.output / 'build-manifest.json').write_text(json.dumps({'build': metadata, 'outputs': outputs}, indent=2) + '\n')
    (args.output / 'SHA256SUMS.txt').write_text(''.join(f"{item['sha256']}  {item['name']}\n" for item in outputs))
    package_records = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\n']).decode()
    (args.output / 'build-packages.tsv').write_text(package_records)


if __name__ == '__main__':
    main()
