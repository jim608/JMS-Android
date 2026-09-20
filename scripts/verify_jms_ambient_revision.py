import hashlib
import json
import pathlib
import re
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
version = re.search(r'(?m)^version:\s*([^\s+]+)\+(\d+)$', (root / 'pubspec.yaml').read_text(encoding='utf-8'))
record = json.loads((root / f'artifacts/checks/build-{version[1]}-inputs.json').read_text(encoding='utf-8-sig'))
previous = json.loads((root / 'artifacts/checks/build-0.11.1-jms.3-inputs.json').read_text(encoding='utf-8-sig'))
current_inputs = {entry['path']: entry['sha256'] for entry in record['inputs']}
previous_inputs = {entry['path']: entry['sha256'] for entry in previous['inputs']}


def digest(content):
    return hashlib.sha256(content).hexdigest()


drift = [name for name, checksum in current_inputs.items() if digest((root / name).read_bytes()) != checksum]
if drift:
    raise SystemExit(f'FAIL: sources changed after build: {drift}')
changed = [name for name in sorted(current_inputs.keys() | previous_inputs.keys())
           if current_inputs.get(name) != previous_inputs.get(name)]
allowed = json.loads((root / 'artifacts/baseline/m7-ambient/changed.json').read_text(encoding='utf-8'))
unexpected = sorted(set(changed) - set(allowed))
if unexpected:
    raise SystemExit(f'FAIL: app changes outside recorded ambient scope: {unexpected}')
if current_inputs['pubspec.lock'] != previous_inputs['pubspec.lock']:
    raise SystemExit('FAIL: dependencies changed')

apk_path = root / f'artifacts/JMS-Android-{version[1]}-release-arm64-test-signed.apk'
previous_apk = root / 'artifacts/JMS-Android-0.11.1-jms.3-release-arm64-test-signed.apk'
if digest(previous_apk.read_bytes()) != 'e77fc2b4b57c6188a1cb839c9a7d57dec8e350efb114bcfebf926c3282f53443':
    raise SystemExit('FAIL: previous APK identity changed')
with zipfile.ZipFile(apk_path) as archive, zipfile.ZipFile(previous_apk) as older:
    if record['buildId'].encode() not in archive.read('lib/arm64-v8a/libapp.so'):
        raise SystemExit('FAIL: build ID absent from compiled application')
    native_name = 'lib/arm64-v8a/libmpv.so'
    native = archive.read(native_name)
    if native != older.read(native_name):
        raise SystemExit('FAIL: native MPV differs from preserved baseline')
    native_sha256 = digest(native)

report = {
    'status': 'PASS', 'build_id': record['buildId'], 'version_name': version[1],
    'base_version_code': int(version[2]), 'source_commit': record['sourceCommit'],
    'uncommitted_changes': True, 'app_input_count': len(current_inputs), 'post_build_drift': drift,
    'changed_app_inputs_from_jms3': changed, 'changes_outside_ambient_scope': unexpected,
    'dependency_lock_unchanged': True, 'native_mpv_unchanged_sha256': native_sha256,
    'apk': str(apk_path), 'apk_bytes': apk_path.stat().st_size, 'apk_sha256': digest(apk_path.read_bytes()),
    'phone_installation_visibility_and_performance': 'NOT TESTED; manual installation required',
    'ass_user_report': 'Prior FAIL remains pending; routing tests do not establish visual acceptance',
}
destination = root / 'artifacts/checks/ambient-revision-m7.json'
destination.write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
