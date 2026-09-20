import hashlib
import base64
import json
from pathlib import Path
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
COMMIT = '8a05a22af450d589ef911d772a001a49dcb05b71'
COMPONENT = 'graphics/graphics-path'


def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'JMS-native-source-audit'})
    with urllib.request.urlopen(request, timeout=40) as response:
        data = response.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('Component source exceeds bound')
    return data


def main():
    destination = ROOT / 'artifacts/native-materials-m13/graphics-path-1.0.1-native.zip'
    manifest = destination.with_suffix('.json')
    if destination.exists():
        record = json.loads(manifest.read_text(encoding='utf-8'))
        if hashlib.sha256(destination.read_bytes()).hexdigest() != record['sha256']:
            raise ValueError('Existing component archive changed')
        print('Verified existing graphics-path component')
        return
    base = 'https://android.googlesource.com/platform/frameworks/support/+/' + COMMIT + '/'
    names = [COMPONENT + '/build.gradle']
    directories = [COMPONENT + '/src/main/cpp']
    while directories:
        directory = directories.pop()
        payload = get(base + directory + '/?format=JSON')
        tree = json.loads(payload.split(b'\n', 1)[1])
        for entry in tree['entries']:
            name = directory + '/' + entry['name']
            if entry['type'] == 'blob':
                names.append(name)
            elif entry['type'] == 'tree':
                directories.append(name)
    if len(names) > 180:
        raise ValueError('Unexpected component size')
    sources = []
    pending = destination.with_suffix('.part')
    try:
        with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name in names:
                url = base + urllib.parse.quote(name) + '?format=TEXT'
                data = base64.b64decode(get(url), validate=True)
                archive.writestr(name, data)
                sources.append({'path': name, 'url': url, 'sha256': hashlib.sha256(data).hexdigest()})
        record = {'sourceCommit': COMMIT, 'releaseEvidence': 'https://developer.android.com/jetpack/androidx/releases/graphics#graphics-path-1.0.1',
                  'sources': sources, 'sha256': hashlib.sha256(pending.read_bytes()).hexdigest()}
        manifest.write_text(json.dumps(record, indent=2), encoding='utf-8')
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    print('Pinned graphics-path component files:', len(sources))


if __name__ == '__main__':
    main()
