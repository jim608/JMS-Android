@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/providers/sync/sync_provider_media.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

class _Sync extends Fake implements SyncNotifier {}

void main() {
  final sync = _Sync();
  final logo = ImageData(path: 'https://media.example.invalid/logo');
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('jms-artwork-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('failed artwork does not replace a previously cached poster or create a bad logo', () async {
    final file = File(path.join(dir.path, 'primary.jpg'));
    await file.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
    final result = await http.runWithClient(
      () => sync.saveImageData(ImagesData(primary: logo, logo: logo), dir),
      () => MockClient((_) async => http.Response('Not found', 404)),
    );
    expect(result?.primary?.path, 'primary.jpg');
    expect(await file.readAsBytes(), [0xff, 0xd8, 0xff, 0xd9]);
    expect(result?.logo, isNull);
    expect(await File(path.join(dir.path, 'logo.jpg')).exists(), isFalse);
  });

  test('a stalled optional image finishes without preventing item sync', () async {
    final request = Completer<http.Response>();
    final result = await http.runWithClient(
      () => sync.urlDataToFileData(logo, dir, 'logo.jpg'),
      () => MockClient((_) => request.future),
    );
    expect(result, isNull);
    expect(await File(path.join(dir.path, 'logo.jpg')).exists(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 22)));

  test('valid artwork is saved and a login page is omitted', () async {
    final result = await http.runWithClient(
      () => sync.saveImageData(
        ImagesData(
          primary: logo,
          logo: logo.copyWith(path: '${logo.path}/missing'),
        ),
        dir,
      ),
      () => MockClient(
        (r) async => r.url.path.endsWith('/missing')
            ? http.Response('<html>Login</html>', 200, headers: {'content-type': 'text/html'})
            : http.Response.bytes([0xff, 0xd8, 0xff, 0xd9], 200, headers: {'content-type': 'image/jpeg'}),
      ),
    );
    expect(result?.primary?.path, 'primary.jpg');
    expect(await File(path.join(dir.path, 'primary.jpg')).readAsBytes(), [0xff, 0xd8, 0xff, 0xd9]);
    expect(result?.logo, isNull);
  });
}
