import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy preferences default to automatic encoding without discarding styles', () {
    final settings = SubtitleSettingsModel.fromMap({'fontSize': 72.0, 'verticalOffset': 0.2});
    expect(settings.externalEncoding, SubtitleEncoding.automatic);
    expect(settings.fontSize, 72);
    expect(settings.verticalOffset, 0.2);
    expect(SubtitleSettingsModel.fromJson(settings.toJson()), settings);
  });
  test('every encoding persists and can be reset without rewriting subtitle content', () {
    for (final encoding in SubtitleEncoding.values) {
      final settings = const SubtitleSettingsModel().copyWith(externalEncoding: encoding);
      expect(SubtitleSettingsModel.fromJson(settings.toJson()).externalEncoding, encoding);
      expect(settings.copyWith(externalEncoding: SubtitleEncoding.automatic), const SubtitleSettingsModel());
    }
  });
}
