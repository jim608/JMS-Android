import difflib
import hashlib
import json
import pathlib
import re
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
destination = root / 'artifacts/baseline/m8-ass'
destination.mkdir(parents=True, exist_ok=True)
previous = json.loads((root / 'artifacts/checks/build-0.11.1-jms.4-inputs.json').read_text(encoding='utf-8-sig'))
scope = {
    'lib/util/subtitle_delivery.dart', 'lib/util/mpv_subtitle_route.dart',
    'lib/util/mpv_subtitle_selection.dart', 'lib/wrappers/players/lib_mpv.dart', 'pubspec.yaml',
}
diff_scope = scope | {
    'test/subtitle_delivery_test.dart', 'test/subtitle_http_delivery_test.dart',
    'test/mpv_subtitle_selection_test.dart', 'test/mpv_subtitle_route_test.dart',
    'scripts/fetch_jms_ass_sample.ps1', 'scripts/check_jms_ass_sample.dart',
    'scripts/verify_jms_ass_revision.py',
}
artifacts = {
    'JMS-Android-0.11.1-jms.4-release-arm64-test-signed.apk': '2c75bae8dc3564acb5baf02a2f1d118c37f34974abe5620e9f25df603891229b',
    'JMS-0.11.1-jms.4-source.zip': 'f41808b352bf2e380b1e644a7251602f786bdd859e1e98bf26aeccc92585d5e6',
    'JMS-0.11.1-jms.4-verification.zip': '4f3558f1669d308540b8bf1a86640a6273748d42570c54520e97a43d73ffb775',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


for name, expected in artifacts.items():
    if digest(root / 'artifacts' / name) != expected:
        raise SystemExit(f'FAIL: accepted .4 baseline artifact changed: {name}')
old_inputs = {entry['path']: entry['sha256'] for entry in previous['inputs']}
drift = [name for name, expected in old_inputs.items() if digest(root / name) != expected]
if '--snapshot' in sys.argv:
    if drift:
        raise SystemExit(f'FAIL: source drift before ASS work: {drift}')
    with zipfile.ZipFile(destination / 'before.zip', 'x', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(scope):
            if (root / name).exists():
                archive.write(root / name, name)
    report = {
        'status': 'PASS', 'build_id': previous['buildId'], 'source_inputs': old_inputs,
        'preserved_artifacts': artifacts,
        'ambient_user_acceptance': 'PASS: effect normal and playback smooth on 0.11.1-jms.4',
        'quantitative_performance': 'NOT MEASURED',
    }
    (destination / 'before.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('PASS: preserved .4 APK/source/evidence and all 1005 app input hashes; no source drift')
else:
    unexpected = sorted(set(drift) - scope)
    if unexpected:
        raise SystemExit(f'FAIL: changes outside ASS scope: {unexpected}')
    with zipfile.ZipFile(destination / 'before.zip') as archive:
        old_sources = {name: archive.read(name).decode('utf-8') for name in archive.namelist()}
    with zipfile.ZipFile(root / 'artifacts/JMS-0.11.1-jms.4-source.zip') as archive:
        for name in diff_scope - old_sources.keys():
            if 'JMS/' + name in archive.namelist():
                old_sources[name] = archive.read('JMS/' + name).decode('utf-8')
    forward = []
    reverse = []
    for name in sorted(diff_scope):
        old_lines = old_sources.get(name, '').splitlines(keepends=True)
        new_lines = (root / name).read_bytes().decode('utf-8').splitlines(keepends=True)
        forward.extend(difflib.unified_diff(old_lines, new_lines, fromfile='a/' + name, tofile='b/' + name))
        reverse.extend(difflib.unified_diff(new_lines, old_lines, fromfile='a/' + name, tofile='b/' + name))
    (destination / 'forward.patch').write_text(''.join(forward), encoding='utf-8', newline='')
    (destination / 'reverse.patch').write_text(''.join(reverse), encoding='utf-8', newline='')
    version = re.search(r'(?m)^version:\s*([^\s+]+)\+\d+$', (root / 'pubspec.yaml').read_text(encoding='utf-8'))[1]
    record = json.loads((root / f'artifacts/checks/build-{version}-inputs.json').read_text(encoding='utf-8-sig'))
    current_inputs = {entry['path']: entry['sha256'] for entry in record['inputs']}
    if set(current_inputs) - set(old_inputs) - scope:
        raise SystemExit('FAIL: new app inputs outside ASS scope')
    if any(digest(root / name) != checksum for name, checksum in current_inputs.items()):
        raise SystemExit('FAIL: inputs changed after APK build')
    apk = root / f'artifacts/JMS-Android-{version}-release-arm64-test-signed.apk'
    with zipfile.ZipFile(apk) as archive, zipfile.ZipFile(root / 'artifacts' / next(iter(artifacts))) as baseline:
        if record['buildId'].encode() not in archive.read('lib/arm64-v8a/libapp.so'):
            raise SystemExit('FAIL: build ID missing from compiled application')
        if archive.read('lib/arm64-v8a/libmpv.so') != baseline.read('lib/arm64-v8a/libmpv.so'):
            raise SystemExit('FAIL: native MPV changed')
    report = {
        'status': 'PASS', 'ambient_source_unchanged': True, 'preserved_artifacts': artifacts,
        'build_id': record['buildId'], 'source_commit': record['sourceCommit'], 'uncommitted_changes': True,
        'changed_app_inputs': sorted(name for name in current_inputs if current_inputs[name] != old_inputs.get(name)),
        'apk': str(apk), 'bytes': apk.stat().st_size, 'sha256': digest(apk),
        'new_apk_phone_installation_and_ass': 'NOT TESTED; user verification required',
    }
    (root / 'artifacts/checks/ass-revision-m8.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
