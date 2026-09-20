import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/util/deep_link_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a missing detail id does not crash the client', () {
    expect(payloadToRoute(Uri.parse('jms:///details')), isNull);
    expect(payloadToRoute(Uri.parse('jms:///details?id=')), isNull);
    expect(payloadToRoute(Uri.parse('jms:///details?id=test-id')), isA<DetailsRoute>());
  });
  test('JMS authentication links round trip without changing credentials', () {
    final data = AuthLinkData(serverUrl: 'https://example.invalid', userName: '測試', password: 'test-only');
    final url = buildAuthUrl(data);
    expect(url.startsWith('jms:///login?authLink='), isTrue);
    final restored = AuthLinkData.parse(url)!;
    expect(restored.serverUrl, data.serverUrl);
    expect(restored.userName, data.userName);
    expect(restored.password, data.password);
  });
}
