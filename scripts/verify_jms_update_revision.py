import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
before = json.loads((root / "artifacts/baseline/m9-updates/before.json").read_text(encoding="utf-8-sig"))
allowed = {
    "lib/main.dart", "lib/util/brand.dart", "lib/util/update_checker.dart", "lib/providers/update_provider.dart",
    "lib/providers/update_provider.g.dart", "lib/providers/update_provider.freezed.dart",
    "lib/screens/settings/widgets/settings_update_information.dart",
    "lib/l10n/app_en.arb", "lib/l10n/app_zh.arb", "lib/l10n/app_zh_Hant.arb",
    "android/app/build.gradle", "android/app/src/main/AndroidManifest.xml",
    "android/app/src/main/kotlin/nl/jknaapen/fladder/MainActivity.kt",
    "pubspec.yaml", "scripts/build_jms_android.ps1",
}
changed = []
for entry in before["existingInputs"]:
    path = root / entry["path"]
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    if digest != entry["sha256"]:
        changed.append(entry["path"])
        if entry["path"] not in allowed:
            raise SystemExit("OUT OF SCOPE CHANGE: " + entry["path"])
preserved = {}
for version, expected in {
    "4": "2c75bae8dc3564acb5baf02a2f1d118c37f34974abe5620e9f25df603891229b",
    "5": "03fd3a9f17427edbcd96dfddbfef5807fd0125743e5601dc5099be9348b27fb4",
}.items():
    path = root / ("artifacts/JMS-Android-0.11.1-jms." + version + "-release-arm64-test-signed.apk")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise SystemExit("BASELINE APK CHANGED")
    preserved[path.name] = digest
for name, expected in {
    "JMS-0.11.1-jms.4-source.zip": "f41808b352bf2e380b1e644a7251602f786bdd859e1e98bf26aeccc92585d5e6",
    "JMS-0.11.1-jms.5-source.zip": "1a2f8879c5e8a56b79ba720d1b810ea8bfc9573b63cedd1b0b2996f66a0e8ab7",
}.items():
    digest = hashlib.sha256((root / "artifacts" / name).read_bytes()).hexdigest()
    if digest != expected:
        raise SystemExit("BASELINE SOURCE ARCHIVE CHANGED")
    preserved[name] = digest
apk = root / "artifacts/JMS-Android-0.11.1-jms.6-release-arm64-test-signed.apk"
with zipfile.ZipFile(apk) as archive:
    mpv = hashlib.sha256(archive.read("lib/arm64-v8a/libmpv.so")).hexdigest()
if mpv != "c0d797517822ac8e3006318cc5b80a5331a086282690043881448a9fbc843678":
    raise SystemExit("PLAYER BINARY CHANGED")
report = {"status": "PASS", "scope": "update-only", "existingInputs": len(before["existingInputs"]),
          "changedExistingInputs": changed, "preservedApks": preserved, "libmpvSha256": mpv,
          "ambient": "unchanged; user manual PASS on .4; quantitative metrics not measured",
          "ASS": "unchanged; user verification remains pending"}
(root / "artifacts/checks/update-revision-m9.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(json.dumps(report, indent=2))
