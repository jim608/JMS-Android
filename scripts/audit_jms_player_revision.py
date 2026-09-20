import hashlib
import json
import pathlib
import re
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
checks = root / 'artifacts/checks'
baseline_apk = root / 'artifacts/JMS-Android-0.11.1-jms.2-release-arm64-test-signed.apk'
baseline_source = root / 'artifacts/JMS-0.11.1-jms.2-source.zip'
expected_hash = 'c8e5a47b36d5dc9c02b4daebed4cfdb6d2a20e03acded479b040a0707b023764'
actual_hash = hashlib.sha256(baseline_apk.read_bytes()).hexdigest()
assert actual_hash == expected_hash, 'Baseline APK has changed'
with zipfile.ZipFile(baseline_apk) as archive:
    native = archive.read('lib/arm64-v8a/libmpv.so')
    version = re.search(rb'mpv v0\.[\w.\-]+', native).group().decode()
with zipfile.ZipFile(baseline_source) as archive:
    previous = archive.read('JMS/lib/wrappers/players/lib_mpv.dart').decode('utf-8')
    previous_ambient = archive.read('JMS/lib/widgets/shared/ambient_blur.dart').decode('utf-8')
    assert 'libass: !kIsWeb && settings.useLibass' in previous
    assert 'return SubtitleText(' in previous
    assert 'Opacity(' in previous_ambient and 'MaskFilter.blur(' in previous_ambient
    assert 'widget.playing' not in previous_ambient
    assert archive.read('JMS/pubspec.lock') == (root / 'pubspec.lock').read_bytes(), 'Dependency lock changed'
    old_files = {name[4:]: archive.read(name) for name in archive.namelist() if not name.endswith('/')}
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
changes = []
for name in sorted(set(paths)):
    path = root / name
    if not name or not path.is_file():
        continue
    content = path.read_bytes()
    if old_files.get(name) != content:
        changes.append({'path': name, 'previous_sha256': hashlib.sha256(old_files[name]).hexdigest() if name in old_files else None,
                        'current_sha256': hashlib.sha256(content).hexdigest()})
report = {
    'baseline_apk_sha256': actual_hash,
    'baseline_native_binary_version_string': version,
    'baseline_installed_on_user_phone': 'unknown; user reported installation but not version or backend',
    'dependency_lock_unchanged': True,
    'media_kit_revision': 'cb56b5a6149f1e51086eba473c7e48041c54ab12',
    'confirmed_source_faults': [
        'Saved useLibass=false initializes sub-ass=no/sub-visibility=no and routes ASS sub-text into Flutter SubtitleText',
        'With native subtitles enabled, Android non-ASS also mounts Flutter text; duplicate ownership',
        'Ambient blur has no playing/buffering input and continues capture/composition during foreground pause',
    ],
    'structural_cost_not_device_timing': 'Baseline full-screen Opacity + FadeTransition + MaskFilter blurred vignette; new painter avoids these layers, keeps capture copies and bounded 192px images',
    'device_ass_effects_and_performance': 'USER FAILED / pending localization and retest; source tests are not visual or phone timing evidence',
    'changes_relative_to_delivered_m3_source': changes,
}
current_apk = root / 'artifacts/JMS-Android-0.11.1-jms.3-release-arm64-test-signed.apk'
input_record = checks / 'build-0.11.1-jms.3-inputs.json'
if current_apk.exists() and input_record.exists():
    build = json.loads(input_record.read_text(encoding='utf-8-sig'))
    drift = [entry['path'] for entry in build['inputs']
             if hashlib.sha256((root / entry['path']).read_bytes()).hexdigest() != entry['sha256']]
    assert not drift, f'Build input drift: {drift}'
    with zipfile.ZipFile(current_apk) as archive:
        assert build['buildId'].encode() in archive.read('lib/arm64-v8a/libapp.so'), 'Build ID not in AOT binary'
        assert archive.read('lib/arm64-v8a/libmpv.so') == native, 'Native mpv binary changed'
    report['new_apk'] = {
        'path': str(current_apk), 'build_id': build['buildId'],
        'sha256': hashlib.sha256(current_apk.read_bytes()).hexdigest(),
        'build_input_count': len(build['inputs']), 'build_input_drift': drift,
        'stamp_in_aot': True, 'native_mpv_identical_to_baseline': True,
    }
(checks / 'player-revision-m6.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
print(f'Baseline APK verified; native binary {version}; dependency lock unchanged; {len(changes)} changed/new files since delivered source')
