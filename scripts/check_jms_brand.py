import hashlib
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
old_brand = re.compile(r'fladder|tjilp', re.I)
exceptions = {
    'flatpak/com.jim608.jms.yaml': {'https://github.com/DonutWare/Fladder/raw/refs/heads/main/flatpak/uchardet-0.0.8.tar.xz': 'Original pinned third-party source archive URL; must not be replaced with an invented JMS URL'},
    'lib/util/brand.dart': {'https://github.com/DonutWare/Fladder': 'Original source link, displayed only under open-source attribution'},
    'lib/bootstrap/app_bootstrap.dart': {'JMS / Fladder (DonutWare and contributors)': 'GPL LicenseRegistry attribution'},
    'lib/fake/fake_jellyfin_open_api.dart': {'http://22b469df.fladder.nl': 'Upstream fake server fixture, not a JMS server setting'},
    'lib/providers/service_provider.dart': {'fladder': 'Existing Jellyfin user-settings namespace, retained for data compatibility'},
    'lib/background/update_notifications_worker.dart': {
        'nl.jknaapen.fladder.update_notifications_check': 'Existing registered worker identifier',
        'nl.jknaapen.fladder.update_notifications_check_debug': 'Existing registered worker identifier',
        'fladder_notification_update_worker_port': 'Internal worker isolate port'},
    'lib/util/notification_helpers.dart': {
        'nl.jknaapen.fladder.update_notifications_check': 'Must match existing registered worker identifier',
        'nl.jknaapen.fladder.update_notifications_check_debug': 'Must match existing registered worker identifier'},
    'lib/services/notification_service.dart': {'fladder_updates': 'Persistent notification channel id', 'fladder_group_$groupId': 'Internal notification grouping key'},
    'lib/wrappers/media_control_wrapper.dart': {'nl.jknaapen.fladder.channel.playback': 'Persistent playback notification channel id'},
    'lib/screens/shared/file_picker.dart': {'FladderFile(name: $name, path: $path, data: ${data?.length})': 'Diagnostic name of retained internal data type'},
    'android/app/build.gradle': {'nl.jknaapen.fladder': 'Kotlin namespace retained; applicationId is independently com.jim608.jms'},
    'android/app/src/main/AndroidManifest.xml': {'nl.jknaapen.fladder': 'Activity namespace, not applicationId or display label'},
}
failures = []
allowed = []
checked = 0
source_files = list((root / 'lib').rglob('*.dart')) + list((root / 'android/app/src').rglob('*.kt'))
for path in source_files:
    name = path.relative_to(root).as_posix()
    if any(marker in name for marker in ('/generated/', '.g.dart', '.freezed.dart', '.mapper.dart', '.gr.dart', '.swagger.dart', '.g.kt')):
        continue
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        for literal in re.findall(r'''["']([^"'\n]*)["']''', line):
            if not old_brand.search(literal):
                continue
            checked += 1
            reason = exceptions.get(name, {}).get(literal)
            if literal.startswith('package:fladder/'):
                reason = 'Retained Dart package import, not product UI; package name stays stable'
            if reason:
                allowed.append({'path': name, 'line': number, 'value': literal, 'reason': reason})
            else:
                failures.append({'path': name, 'line': number, 'value': literal})
for path in (root / 'lib/l10n').glob('*.arb'):
    entries = json.loads(path.read_text(encoding='utf-8'))
    for key, value in entries.items():
        if not isinstance(value, str) or not old_brand.search(value):
            continue
        record = {'path': path.relative_to(root).as_posix(), 'key': key, 'value': value}
        if key == 'jmsSourceAttribution':
            allowed.append({**record, 'reason': 'Open-source attribution label only'})
        else:
            failures.append(record)
platform_files = [
    'android/app/build.gradle', 'android/app/src/main/AndroidManifest.xml', 'web/index.html', 'web/manifest.json',
    'ios/Runner/Info.plist', 'ios/Runner.xcodeproj/project.pbxproj', 'macos/Runner/Configs/AppInfo.xcconfig',
    'macos/Runner.xcodeproj/project.pbxproj', 'windows/runner/main.cpp', 'windows/runner/Runner.rc',
    'windows/windows_setup.iss', 'windows/CMakeLists.txt', 'linux/CMakeLists.txt', 'linux/my_application.cc',
    'flatpak/JMS.desktop', 'flatpak/com.jim608.jms.yaml', 'flatpak/com.jim608.jms.metainfo.xml',
    'AppImageBuilder.yml', 'altstore.json', '.github/workflows/build.yml', 'icons_launcher-production.yaml', 'icons_launcher-development.yaml',
]
for name in platform_files:
    for number, line in enumerate((root / name).read_text(encoding='utf-8').splitlines(), 1):
        if not old_brand.search(line):
            continue
        exception = next(((value, reason) for value, reason in exceptions.get(name, {}).items() if value in line), None)
        record = {'path': name, 'line': number, 'value': line.strip()}
        if exception:
            allowed.append({**record, 'reason': exception[1]})
        else:
            failures.append(record)
artwork = []
for path in (root / 'android/app/src').rglob('*.png'):
    if path.name not in {'ic_launcher.png', 'ic_launcher_foreground.png', 'ic_launcher_monochrome.png', 'ic_notification.png', 'app_banner.png'}:
        continue
    name = path.relative_to(root).as_posix()
    current = hashlib.sha256(path.read_bytes()).hexdigest()
    previous = subprocess.run(['git', 'show', f'HEAD:{name}'], cwd=root, capture_output=True)
    if previous.returncode == 0 and current == hashlib.sha256(previous.stdout).hexdigest():
        failures.append({'path': name, 'reason': 'Active Android artwork is identical to upstream'})
    artwork.append({'path': name, 'sha256': current})
report = {'status': 'FAIL' if failures else 'PASS', 'scope': 'Dart and Kotlin product string literals, all ARB values, listed platform/release resources and active Android artwork; retained technical identifiers recorded individually', 'failures': failures, 'exceptions': allowed, 'android_artwork': artwork}
destination = root / 'artifacts/checks/brand.json'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
print(f"{report['status']}: {len(failures)} unexpected residues; {len(allowed)} individually recorded technical/source occurrences; {len(artwork)} Android assets")
for item in failures:
    print(json.dumps(item, ensure_ascii=False))
raise SystemExit(bool(failures))
