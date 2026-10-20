class WebSubtitleTiming {
  WebSubtitleTiming({
    required void Function(String) onText,
    required void Function(bool) onAvailable,
  });

  bool get supported => false;
  bool get available => false;
  void attach(Object? platform) {}
  void clearTrack() {}
  void selectTrack() {}
  void refresh() {}
  Future<String> prepareSubtitle(String url) =>
      Future.error(UnsupportedError('Browser subtitles are unavailable'));
  Future<void> write(String property, String value) =>
      Future.error(UnsupportedError('Browser subtitle timing is unavailable'));
  Future<String> read(String property) async => '';
  void dispose() {}
}
