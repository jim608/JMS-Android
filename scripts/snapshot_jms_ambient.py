import difflib
import hashlib
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
destination = root / 'artifacts/baseline/m7-ambient'
destination.mkdir(parents=True, exist_ok=True)
paths = [
    'lib/widgets/shared/ambient_blur.dart', 'lib/widgets/shared/ambient_geometry.dart',
    'lib/widgets/shared/ambient_controls.dart', 'lib/widgets/shared/ambient_sample_preview.dart',
    'lib/screens/video_player/video_player.dart', 'lib/screens/video_player/components/playback_diagnostics.dart',
    'lib/screens/settings/player_settings_page.dart', 'lib/models/settings/video_player_settings.dart',
    'lib/models/settings/video_player_settings.g.dart', 'lib/models/settings/video_player_settings.freezed.dart',
    'lib/providers/settings/video_player_settings_provider.dart',
    'lib/l10n/app_en.arb', 'lib/l10n/app_zh.arb', 'lib/l10n/app_zh_Hant.arb',
    'test/ambient_blur_test.dart', 'test/ambient_visibility_test.dart', 'test/ambient_settings_test.dart',
    'pubspec.yaml', 'pubspec.lock', 'build.jms_ambient.yaml',
]
archive_path = destination / 'before.zip'
if '--delta' not in sys.argv:
    if archive_path.exists():
        raise SystemExit('Baseline already exists; refusing to overwrite')
    record = json.loads((root / 'artifacts/checks/build-0.11.1-jms.3-inputs.json').read_text(encoding='utf-8-sig'))
    expected = {entry['path']: entry['sha256'] for entry in record['inputs']}
    hashes = {}
    differences = []
    with zipfile.ZipFile(archive_path, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name in paths:
            path = root / name
            if not path.exists():
                continue
            content = path.read_bytes()
            archive.writestr(name, content)
            hashes[name] = hashlib.sha256(content).hexdigest()
            if name in expected and hashes[name] != expected[name]:
                differences.append(name)
    metadata = {
        'build_id': record['buildId'], 'app_input_differences_from_apk': differences, 'sha256': hashes,
        'user_report': 'Playback no longer stutters, ambient visibility failed; NOT quantitative performance acceptance',
        'source_defaults_not_phone_readback': {'mode': 'direct', 'max_capture_px': 192, 'interval_seconds': 4,
                                             'sigma': 64, 'opacity': 0.5, 'vignette_alpha_factor': 0.49},
    }
    (destination / 'before.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    print(f'Preserved {len(hashes)} files; scoped app differences from delivered .3 APK: {differences}')
else:
    forward = []
    reverse = []
    with zipfile.ZipFile(archive_path) as archive:
        previous = {name: archive.read(name) for name in archive.namelist()}
    changed = []
    for name in paths:
        before = previous.get(name, b'')
        after = (root / name).read_bytes() if (root / name).exists() else b''
        if before == after:
            continue
        changed.append(name)
        old_lines = before.decode('utf-8').splitlines(keepends=True)
        new_lines = after.decode('utf-8').splitlines(keepends=True)
        forward.extend(difflib.unified_diff(old_lines, new_lines, fromfile='a/' + name, tofile='b/' + name))
        reverse.extend(difflib.unified_diff(new_lines, old_lines, fromfile='a/' + name, tofile='b/' + name))
    (destination / 'forward.patch').write_text(''.join(forward), encoding='utf-8', newline='')
    (destination / 'reverse.patch').write_text(''.join(reverse), encoding='utf-8', newline='')
    (destination / 'changed.json').write_text(json.dumps(changed, indent=2), encoding='utf-8')
    print(f'Saved forward/reverse diff for {len(changed)} files; NOT applied')
