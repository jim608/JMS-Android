import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import time
from pathlib import Path


LINUX_DEPENDENCIES = (
    'glibc>=2.36', 'gcc-libs', 'gtk3', 'mpv', 'alsa-lib', 'sqlite', 'polkit',
    'libarchive', 'xdg-user-dirs', 'libsecret', 'gnome-keyring', 'networkmanager',
)


def package_version(version, code):
    if (not isinstance(version, str) or
            not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version) or
            type(code) is not int or code < 1):
        raise ValueError('Invalid Linux version')
    return version.replace('-', '_', 1) + '-' + str(code)


def write_aur_recipe(output, metadata, installer, release_tag=None):
    """Generate a local/AUR binary recipe from the exact reviewed pacman asset."""
    version, code = metadata['versionName'], metadata['versionCode']
    native_version = package_version(version, code)
    if (metadata.get('platform') != 'linux-x64' or
            metadata.get('applicationId') != 'com.jim608.jms' or
            metadata.get('packageVersion') != native_version or
            not re.fullmatch(r'[a-f0-9]{40}', metadata.get('sourceCommit', '')) or
            metadata.get('buildId') != f'JMS-{version}-linux-{metadata["sourceCommit"][:12]}'):
        raise ValueError('AUR recipe requires the exact Linux build identity')
    tag = release_tag or 'v' + version
    if tag not in ('v' + version, 'v' + version + '+' + str(code)):
        raise ValueError('AUR recipe release tag differs from application version')
    expected_name = f'JMS-Linux-{version}-x86_64.pkg.tar.xz'
    if (installer.get('name') != expected_name or
            not re.fullmatch(r'[a-f0-9]{64}', installer.get('sha256', '')) or
            type(installer.get('size')) is not int or installer['size'] < 1):
        raise ValueError('AUR recipe requires a bound x86_64 installer')
    installed = output / expected_name
    if (not installed.is_file() or installed.stat().st_size != installer['size'] or
            hashlib.sha256(installed.read_bytes()).hexdigest() != installer['sha256']):
        raise ValueError('AUR installer differs from its bound size/SHA256')
    with tarfile.open(installed, 'r:xz') as package:
        actual_build = json.load(package.extractfile('opt/jms/JMS_BUILD_INFO.json'))
        info = package.extractfile('.PKGINFO').read().decode()
        for name in ('opt/jms/jms', 'opt/jms/LICENSE',
                     'usr/bin/jms', 'usr/share/applications/com.jim608.jms.desktop',
                     'usr/share/icons/hicolor/512x512/apps/com.jim608.jms.png'):
            package.getmember(name)
    if actual_build != metadata:
        raise ValueError('AUR installer contains a different build identity')
    for field, expected in {'pkgname': ['jms'], 'arch': ['x86_64'], 'pkgver': [native_version],
                            'depend': list(LINUX_DEPENDENCIES), 'conflict': ['jms-bin']}.items():
        if re.findall(r'^' + field + r' = (.+)$', info, re.M) != expected:
            raise ValueError('AUR installer package metadata differs: ' + field)
    recipe = output / 'aur/jms-bin'
    recipe.mkdir(parents=True)
    pkgver = version.replace('-', '_', 1)
    source = f'https://github.com/jim608/JMS-Linux/releases/download/{tag}/{expected_name}'
    depends = ' '.join(repr(item) for item in LINUX_DEPENDENCIES)
    script = f'''# 完整相應來源、原生材料與授權隨此固定版本的 GitHub Release 提供。
# 共用來源：https://github.com/jim608/JMS-Android/commit/{metadata['sourceCommit']}
pkgname=jms-bin
pkgver={pkgver}
pkgrel={code}
pkgdesc='Jim608 Media Server desktop client (official binary)'
arch=('x86_64')
url='https://github.com/jim608/JMS-Linux'
license=('GPL-3.0-only')
depends=({depends})
makedepends=('python')
provides=("jms=$pkgver-$pkgrel")
conflicts=('jms')
options=('!strip' '!debug')
_app_version='{version}'
_source_commit='{metadata['sourceCommit']}'
_build_id='{metadata['buildId']}'
source=('{source}')
sha256sums=('{installer['sha256']}')

package() {{
  python - "$srcdir/opt/jms/JMS_BUILD_INFO.json" "$_app_version" "$pkgrel" "$_source_commit" "$_build_id" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {{'applicationId': 'com.jim608.jms', 'platform': 'linux-x64',
            'versionName': sys.argv[2], 'versionCode': int(sys.argv[3]),
            'sourceCommit': sys.argv[4], 'buildId': sys.argv[5], 'packageFormat': 'arch',
            'packageVersion': sys.argv[2].replace('-', '_', 1) + '-' + sys.argv[3]}}
if any(record.get(key) != value for key, value in expected.items()):
    raise SystemExit('Linux package build identity mismatch')
PY
  cp -a "$srcdir/opt" "$srcdir/usr" "$pkgdir/"
  install -Dm644 "$srcdir/opt/jms/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}}
'''
    (recipe / 'PKGBUILD').write_text(script, encoding='utf-8', newline='\n')
    fields = [('pkgdesc', 'Jim608 Media Server desktop client (official binary)'),
              ('pkgver', pkgver), ('pkgrel', str(code)),
              ('url', 'https://github.com/jim608/JMS-Linux'), ('arch', 'x86_64'),
              ('license', 'GPL-3.0-only'), ('makedepends', 'python')]
    fields += [('depends', item) for item in LINUX_DEPENDENCIES]
    fields += [('provides', 'jms=' + native_version), ('conflicts', 'jms'),
               ('options', '!strip'), ('options', '!debug'), ('source', source),
               ('sha256sums', installer['sha256'])]
    srcinfo = 'pkgbase = jms-bin\n' + ''.join(f'\t{key} = {value}\n' for key, value in fields)
    srcinfo += '\npkgname = jms-bin\n'
    (recipe / '.SRCINFO').write_text(srcinfo, encoding='utf-8', newline='\n')
    (recipe / 'README.zh-Hant.md').write_text(
        '# JMS Linux 二進位套件配方\n\n'
        f'此配方固定使用 JMS {version}+{code}、來源提交 `{metadata["sourceCommit"]}` 的官方 x86_64 套件。\n\n'
        '在 EndeavourOS／Arch x86_64 使用一般使用者執行 `yay -Bi ./jms-bin`；'
        '也可進入配方目錄執行 `makepkg -si`。先閱讀 PKGBUILD，並核對 Release 的 SHA256SUMS.txt。\n\n'
        '配方支援本機建置，並不表示已刊登 AUR；尚未刊登時不能使用 `yay -S jms-bin`。'
        '僅在固定 GitHub Release 已公開且全部附件完成校驗後使用。\n\n'
        '`jms-bin` 與官方 pacman 套件 `jms` 互斥；切換須明確確認移除原套件，使用者設定不隨套件移除。'
        '使用本機配方時，後續更新需下載新版配方重新執行；App 更新器使用官方 `jms` 套件，'
        '不能視為 AUR 自動更新。\n\n'
        '套件未提供正式發行者簽章，遵循本機 pacman 的簽章政策，不降低檢查。'
        '保留 GPLv3、上游署名與原生依賴材料；完整相應來源見同一 Release 的額外 source ZIP，'
        '不是 GitHub 自動產生的發布倉庫 Source code.zip。\n', encoding='utf-8', newline='\n')
    archive = output / f'JMS-Linux-{version}-jms-bin-aur.tar.gz'
    with tarfile.open(archive, 'w:gz') as container:
        container.add(recipe, arcname='jms-bin')
    return archive


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
        'url = https://github.com/jim608/JMS-Linux\n'
        'arch = x86_64\nlicense = GPL-3.0-only\nconflict = jms-bin\n'
        + ''.join(f'depend = {dependency}\n' for dependency in
                  LINUX_DEPENDENCIES), encoding='utf-8', newline='\n')
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
    recipe_archive = write_aur_recipe(args.output, metadata, outputs[0])
    with recipe_archive.open('rb') as stream:
        recipe_sha = hashlib.file_digest(stream, 'sha256').hexdigest()
    outputs.append({'name': recipe_archive.name, 'size': recipe_archive.stat().st_size, 'sha256': recipe_sha})
    (args.output / 'build-manifest.json').write_text(json.dumps({'build': metadata, 'outputs': outputs}, indent=2) + '\n')
    (args.output / 'SHA256SUMS.txt').write_text(''.join(f"{item['sha256']}  {item['name']}\n" for item in outputs))
    package_records = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\n']).decode()
    (args.output / 'build-packages.tsv').write_text(package_records)


if __name__ == '__main__':
    main()
