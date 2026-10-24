import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/profiles/web_profile.dart';
import 'package:fladder/util/web_video_capabilities.dart';

void main() {
  test('unverified browser output advertises SDR for each HDR-capable codec',
      () {
    expect(webAdvertisedVideoRangeTypes, 'SDR');
    for (final codec in ['hevc', 'vp9', 'av1']) {
      final profile = webProfile.codecProfiles!.singleWhere(
        (profile) => profile.type == CodecType.video && profile.codec == codec,
      );
      final range = profile.conditions!.singleWhere(
        (condition) =>
            condition.property == ProfileConditionValue.videorangetype,
      );
      expect(range.condition, ProfileConditionType.equalsany, reason: codec);
      expect(range.$Value, 'SDR', reason: codec);
    }
  });

  test('existing H264 SDR negotiation remains available', () {
    final h264 = webProfile.codecProfiles!.singleWhere(
      (profile) => profile.type == CodecType.video && profile.codec == 'h264',
    );
    final range = h264.conditions!.singleWhere(
      (condition) => condition.property == ProfileConditionValue.videorangetype,
    );
    expect(range.$Value, 'SDR');
    expect(
        webProfile.directPlayProfiles!
            .where((profile) => profile.type == DlnaProfileType.video),
        isNotEmpty);
  });

  test('serialized server capabilities do not claim HDR10 or HLG output', () {
    final encoded = jsonEncode(webProfile.toJson());
    expect(encoded, isNot(contains('HDR10')));
    expect(encoded, isNot(contains('HLG')));
    expect(encoded, contains('SDR'));
  });
}
