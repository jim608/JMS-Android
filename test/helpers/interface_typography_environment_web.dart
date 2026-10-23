import 'dart:ui_web' as ui_web;

/// Keeps browser widget-test behavior while using the actual pubspec fonts.
void Function() useBundledTypographyFonts() {
  final previous = ui_web.TestEnvironment.instance;
  ui_web.TestEnvironment.setUp(ui_web.TestEnvironment(
    ignorePlatformMessages: previous.ignorePlatformMessages,
    forceTestFonts: false,
    disableFontFallbacks: previous.disableFontFallbacks,
    keepSemanticsDisabledOnUpdate: previous.keepSemanticsDisabledOnUpdate,
    defaultToTestUrlStrategy: previous.defaultToTestUrlStrategy,
  ));
  return () => ui_web.TestEnvironment.setUp(previous);
}
