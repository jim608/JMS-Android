import hashlib
import json
from pathlib import Path
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LICENSE_NAMES = ('LICENSE', 'COPYING', 'NOTICE', 'COPYRIGHT', 'FTL.TXT')


def selected(name):
    path = Path(name)
    return path.name.upper().startswith(LICENSE_NAMES) and len(path.parts) <= 4


def notices(path):
    if path.suffix in ('.zip', '.jar'):
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if not entry.is_dir() and selected(entry.filename) and entry.file_size < 4 * 1024 * 1024:
                    yield entry.filename, archive.read(entry)
                elif (path.suffix == '.jar' and entry.filename.endswith('.kt')) or (path.name == 'graphics-path-1.0.1-native.zip' and entry.filename.endswith(('.cpp', '.h'))):
                    data = archive.read(entry)
                    end = data.find(b'*/')
                    if data.startswith(b'/*') and 0 < end < 4096 and b'Copyright' in data[:end]:
                        yield entry.filename + ' copyright header', data[:end + 2]
    elif '.tar.' in path.name:
        with tarfile.open(path) as archive:
            for entry in archive.getmembers():
                if entry.isfile() and selected(entry.name) and entry.size < 4 * 1024 * 1024:
                    yield entry.name, archive.extractfile(entry).read()


def main():
    sources = [path for path in (ROOT / 'artifacts/native-materials-m10').glob('*.zip')
               if not path.name.startswith('mdk-')]
    sources += [path for path in (ROOT / 'artifacts/native-materials-m13').iterdir()
                if path.name.endswith(('.zip', '.jar', '.tar.gz', '.tar.xz')) and not path.name.startswith('fvp-')]
    sections = []
    manifest = []
    seen = set()

    def append(origin, name, data):
        checksum = hashlib.sha256(data).hexdigest()
        manifest.append({'origin': origin, 'entry': name, 'sha256': checksum})
        if checksum not in seen:
            sections.append('\n\n===== ' + origin + ' ! ' + name + ' =====\n\n' + data.decode('utf-8', 'replace'))
            seen.add(checksum)

    for source in sorted(sources):
        for name, data in notices(source):
            append(source.name, name, data)
    for source in sorted((ROOT / 'docs/native-notices').glob('NDK*')):
        append('Android NDK 27.0.12077973', source.name, source.read_bytes())
    engine = ROOT / '.jms-tools/flutter/bin/cache/pkg/sky_engine/LICENSE'
    append('Flutter engine 035316565ad77281a75305515e4682e6c4c6f7ca', 'LICENSE', engine.read_bytes())
    destination = ROOT / 'assets/licenses/JMS_NATIVE_NOTICES.txt'
    destination.parent.mkdir(parents=True, exist_ok=True)
    preface = ('JMS Android native component copyright and license notices\n'
               'JMS application source is GPLv3; component-specific terms follow.\n'
               'This software is based in part on the work of the FreeType Team.\n'
               'Source/build material mapping: docs/JMS_SOURCES.md and the matching Release native-materials archive.\n'
               'These unmodified upstream notices may describe optional files/features not compiled in this Android build.\n'
               'They do not constitute permission to distribute MDK; MDK is excluded from JMS Android.\n')
    destination.write_text(preface + ''.join(sections), encoding='utf-8')
    (ROOT / 'docs/native-notices/android-manifest.json').write_text(json.dumps({
        'schemaVersion': 1, 'entries': manifest,
        'assetSha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
    }, indent=2), encoding='utf-8')
    print('Notice records:', len(manifest), 'unique texts:', len(seen), 'asset bytes:', destination.stat().st_size)


if __name__ == '__main__':
    main()
