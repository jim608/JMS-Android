import hashlib
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
path = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(path) as archive:
    names = archive.namelist()
    architectures = sorted({name.split('/')[1] for name in names if name.startswith('lib/') and name.endswith('.so')})
    if architectures != ['arm64-v8a']:
        raise SystemExit(f'FAIL: unexpected ABI set {architectures}')
    for name in ('lib/arm64-v8a/libapp.so', 'lib/arm64-v8a/libflutter.so'):
        if name not in names:
            raise SystemExit(f'FAIL: missing {name}')
    verified = {}
    for source in ('assets/subtitle_fonts/NotoSansCJKtc-Regular.otf', 'assets/subtitle_fonts/OFL.txt', 'LICENSE', 'icons/jms/mark.svg'):
        packaged = archive.read('assets/flutter_assets/' + source)
        if packaged != (root / source).read_bytes():
            raise SystemExit(f'FAIL: packaged source differs: {source}')
        verified[source] = hashlib.sha256(packaged).hexdigest()
    old_assets = [name for name in names if name.startswith('assets/flutter_assets/') and 'fladder' in name.lower()]
    if old_assets:
        raise SystemExit(f'FAIL: upstream artwork paths included: {old_assets}')
report = {'status': 'PASS', 'apk': str(path.resolve()), 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'architectures': architectures, 'verified_assets': verified, 'install_status': 'NOT TESTED for this APK; no installation performed by this verification script'}
(root / 'artifacts/checks/apk-assets.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
