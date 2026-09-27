# JMS Android and Windows exclusion

Original: fvp 0.35.0, https://pub.dev/api/archives/fvp-0.35.0.tar.gz
Archive SHA-256: 33e34a78d3e4bd3ab87af7279d7bc88ff6025291574edc7e8592abea91e04cb4

The Android and Windows plugin declarations are removed from pubspec.yaml. Flutter therefore does not register or build fvp on these platforms, and does not fetch or package their MDK SDK. Remaining platform declarations are unchanged. Ten positional override parameter names in video_player_mdk.dart are aligned with the locked video_player_platform_interface (textureId to playerId); their operations are unchanged. This fixes upstream lint findings without suppressing any analyzer rule. Original LICENSE and copyright statements are retained. Examples, tests and upstream GitHub workflows are not vendored.

JMS Android removes the MDK selection and resolves a saved MDK preference to MPV without deleting that preference. This does not grant any new MDK license or approve redistribution on other platforms. Android Native subtitles use the original, locked ass-kt 0.3.0 AAR libass provider, not the conflicting MDK SDK provider.

Windows additionally removes both plugin registration declarations. Windows offers MPV only and resolves saved MDK preferences to MPV without deleting them. Android retains MPV and Native. The Windows packaging script rejects leftover MDK SDK libraries; incremental build leftovers must not enter a release.

Rollback requires explicitly restoring the dependency and the affected platform backend selection; it would also restore the MDK licensing blocker. Do not publish a rollback without a renewed artifact audit.
