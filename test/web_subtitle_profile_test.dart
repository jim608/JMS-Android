import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/profiles/web_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'Web negotiates external browser text delivery, never container selection',
      () {
    final subtitles = webProfile.subtitleProfiles!;
    expect(subtitles.map((profile) => profile.format).toSet(), {'vtt', 'srt'});
    expect(subtitles, hasLength(2));
    expect(
        subtitles.every(
            (profile) => profile.method == SubtitleDeliveryMethod.$external),
        isTrue);
  });
}
