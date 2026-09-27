import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/services/notification_service.dart';

void main() {
  test('Linux startup does not call unsupported notification launch API', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await NotificationService.getInitialNotificationPayload(), isNull);
  });
}
