class WebSubtitleTiming {
  WebSubtitleTiming({
    required void Function(String) onText,
    required void Function(bool) onAvailable,
  });

  bool get supported => false;
  bool get available => false;
  String? get appliedSourceUrl => null;
  void attach(Object? platform) {}
  void cancelPendingSelection() {}
  void clearTrack() {}
  void selectTrack() {}
  void refresh() {}
  Future<String> prepareSubtitle(String url) =>
      Future.error(UnsupportedError('Browser subtitles are unavailable'));
  Future<void> replaceSubtitle(String url,
          {required bool Function() isCurrent}) =>
      Future.error(UnsupportedError('Browser subtitles are unavailable'));
  Future<void> write(String property, String value) =>
      Future.error(UnsupportedError('Browser subtitle timing is unavailable'));
  Future<String> read(String property) async => '';
  void dispose() {}
}
