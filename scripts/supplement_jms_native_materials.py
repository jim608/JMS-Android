import hashlib
import json
from pathlib import Path
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MATERIALS = ROOT / 'artifacts/native-materials-m10'
NOTICES = ROOT / 'docs/native-notices'
HOME = Path.home()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    MATERIALS.mkdir(parents=True, exist_ok=True)
    NOTICES.mkdir(parents=True, exist_ok=True)
    manifest_path = MATERIALS / 'supplement-manifest.json'
    manifest = []
    sources = [
        ('mpv', 'mpv-player/mpv', '78d43740f52db817d98bcf24fb30a76ab6fa13ff'),
        ('jellyfin-ffmpeg', 'FFmpeg/FFmpeg', 'd388c347d41e4eb516dec05910551c5461e65615'),
        ('ass-cmake', 'peerless2012/libass-cmake', 'd3f00a43ca66e42a2c34de964b1a7dbbfa9dbc8b'),
        ('media-kit-helper', 'media-kit/media-kit-android-helper', '42054e5d479f39ccbb0ae604862e2bcaf59b74c2'),
        ('mdk-ffmpeg-base', 'FFmpeg/FFmpeg', '5b614efc7e6134274fa5d05e240736be2dc203cc'),
    ]
    for label, repository, commit in sources:
        url = 'https://codeload.github.com/' + repository + '/zip/' + commit
        destination = MATERIALS / (label + '-' + commit[:12] + '.zip')
        record = {'file': destination.name, 'url': url, 'sourceCommit': commit}
        try:
            if not destination.exists():
                temporary = destination.with_suffix('.part')
                try:
                    request = urllib.request.Request(url, headers={'User-Agent': 'JMS-native-source-audit'})
                    with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
                        total = 0
                        while chunk := response.read(1024 * 1024):
                            total += len(chunk)
                            if total > 192 * 1024 * 1024:
                                raise ValueError('Archive exceeds bounded audit size')
                            output.write(chunk)
                    temporary.rename(destination)
                finally:
                    temporary.unlink(missing_ok=True)
            record.update(bytes=destination.stat().st_size, sha256=digest(destination.read_bytes()),
                          status='downloaded pinned root; recursively bundled source still requires coverage audit')
            print(label, record['bytes'], 'downloaded')
        except Exception as error:
            record.update(status='BLOCKED', error=type(error).__name__)
            print(label, 'BLOCKED', type(error).__name__)
        manifest.append(record)
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')

    notices = []
    media_commit = 'b7bbc6e2bc3e45ff3ed99884c114c50f03bba5c9'
    media_materials = MATERIALS / ('androidx-media-' + media_commit[:12])
    for name in ['LICENSE', 'libraries/decoder_ffmpeg/src/main/jni/CMakeLists.txt',
                 'libraries/decoder_ffmpeg/src/main/jni/build_ffmpeg.sh',
                 'libraries/decoder_ffmpeg/src/main/jni/ffmpeg_jni.cc']:
        destination = media_materials / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        url = 'https://raw.githubusercontent.com/androidx/media/' + media_commit + '/' + name
        if not destination.exists():
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise ValueError('Native source file exceeds audit limit')
            destination.write_bytes(data)
        manifest.append({'file': destination.relative_to(MATERIALS).as_posix(), 'url': url,
                         'sourceCommit': media_commit, 'sha256': digest(destination.read_bytes()),
                         'bytes': destination.stat().st_size, 'status': 'exact pinned native JNI source / build recipe'})
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    for archive_path in sorted(MATERIALS.glob('*.zip')):
        with zipfile.ZipFile(archive_path) as archive:
            for entry in archive.infolist():
                relative = Path(entry.filename)
                if len(relative.parts) != 2 or not relative.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'COPYRIGHT')):
                    continue
                data = archive.read(entry)
                target = NOTICES / (archive_path.stem + '-' + relative.name + '.txt')
                target.write_bytes(data)
                notices.append({'file': target.name, 'source': archive_path.name + '!' + entry.filename,
                                'sha256': digest(data)})
    package_cache = HOME / 'AppData/Local/Pub/Cache/hosted/pub.dev'
    local = {
        'fvp-0.35.0-LICENSE.txt': package_cache / 'fvp-0.35.0/LICENSE',
        'mdk-cached-sdk-README.txt': package_cache / 'fvp-0.35.0/android/mdk-sdk/README.md',
        'sqlite3_flutter_libs-0.5.40-LICENSE.txt': package_cache / 'sqlite3_flutter_libs-0.5.40/LICENSE',
        'flutter-3.35.7-LICENSE.txt': ROOT / '.jms-tools/flutter/LICENSE',
        'androidx-media-1.8.0-LICENSE.txt': media_materials / 'LICENSE',
        'NDK-27.0.12077973-NOTICE.txt': ROOT / '.jms-tools/android-sdk/ndk/27.0.12077973/NOTICE',
        'NDK-27.0.12077973-NOTICE.toolchain.txt': ROOT / '.jms-tools/android-sdk/ndk/27.0.12077973/NOTICE.toolchain',
    }
    for name, path in local.items():
        if not path.is_file():
            continue
        shutil.copyfile(path, NOTICES / name)
        notices.append({'file': name, 'source': str(path).replace(str(HOME), '%USERPROFILE%').replace(str(ROOT), '%PROJECT%'),
                        'sha256': digest(path.read_bytes())})
    (NOTICES / 'provenance.json').write_text(json.dumps(notices, indent=2), encoding='utf-8')
    print('Collected notices:', len(notices))


if __name__ == '__main__':
    main()
