# JMS development

Use the version in `.fvmrc` (Flutter 3.35.7 / Dart 3.9.2) and `pubspec.lock`; do not run a blanket upgrade. Android requires JDK 21 and `platforms;android-37.0`, build-tools 35.0.0, NDK 27.0.12077973 and CMake 3.22.1. SDK tools are installed locally for this workspace under `.jms-tools`.

```powershell
rtk proxy .\.jms-tools\flutter\bin\flutter.bat pub get --enforce-lockfile
rtk proxy .\.jms-tools\flutter\bin\flutter.bat gen-l10n
rtk proxy .\.jms-tools\flutter\bin\flutter.bat analyze
rtk proxy .\.jms-tools\flutter\bin\flutter.bat test
rtk proxy powershell -NoProfile -File scripts/build_jms_android.ps1
```

Generate artwork from `icons/jms/mark.svg` using `scripts/generate_jms_artwork.py` (Pillow 11.3.0). Then run `dart run icons_launcher:create --path icons_launcher-production.yaml`, `dart run icons_launcher:create --flavors production,development`, and `dart run flutter_native_splash:create`. Both Android flavor directories must be regenerated: main-only resources do not override them. Localization is generated from ARB sources. Generate model code only after changing corresponding annotated models using `dart run build_runner build`.

The Android build and source-packaging scripts read the version from `pubspec.yaml`. The APK uses `--split-per-abi --target-platform android-arm64`. Flutter adds 2000 to the base build number for ARM64: `--build-number=2` produces APK versionCode 2002. Keep this convention for subsequent JMS updates and verify the actual APK metadata. The default is an explicitly test-signed, optimized release APK, not a production signing identity. `-ProductionSigning` requires the existing authorized release keystore configuration; keys are never included in the source archive.

Run `scripts/generate_jms_subtitle_fixtures.py` with FFmpeg available to create legal, original test clips and libass reference images. This does not validate Android rendering. See `docs/JMS_STATUS.md` for device tests and open blockers.

For the fixed-duration device performance matrix, run `scripts/generate_jms_performance_fixture.py`. It generates a six-minute 1280x720/24fps H264/AAC MKV with general and complex ASS tracks plus a font attachment. Use seconds 0–120 for warmup and 120–300 for the measurement; the 12-second visual fixture alone is not long enough. The generator validates duration, 8640 video packets and the two ASS streams, without claiming any device performance result.

`scripts/check_jms_web_startup.js` runs through Playwright CLI against a local server on port 8765. Use a fresh isolated browser session for each newly built bundle so that an older service worker does not serve a previous build. It checks the login route/title and uncaught startup errors; it is not a server-login or playback test.
