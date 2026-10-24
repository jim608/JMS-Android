import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/discovery_provider.dart';
import 'package:fladder/services/local_network_permission.dart';

class _SyntheticSocket extends Fake implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>();
  var closes = 0;
  var sends = 0;

  @override
  set broadcastEnabled(bool value) {}

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sends++;
    throw const SocketException('synthetic disconnected network');
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void close() {
    closes++;
    unawaited(events.close());
  }
}

ProviderContainer _container(
  Future<RawDatagramSocket> Function() bindSocket, {
  LocalNetworkPermissionStatus permission =
      LocalNetworkPermissionStatus.granted,
}) {
  return ProviderContainer(
    overrides: [
      serverDiscoveryProvider.overrideWith(
        () => ServerDiscovery(
          bindSocket: bindSocket,
          checkPermission: () async => permission,
        ),
      ),
    ],
  );
}

void main() {
  test('offline discovery returns empty and closes the socket once', () async {
    final socket = _SyntheticSocket();
    final container = _container(() async => socket);
    final subscription = container.listen(serverDiscoveryProvider, (_, __) {});
    expect(await container.read(serverDiscoveryProvider.future), isEmpty);
    expect(socket.sends, 1);
    expect(socket.closes, 1);
    subscription.close();
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(socket.closes, 1);
  });

  test(
    'bind failure returns empty while denied permission remains an error',
    () async {
      var binds = 0;
      Future<RawDatagramSocket> bind() async {
        binds++;
        throw const SocketException('synthetic bind failure');
      }

      final offline = _container(bind);
      final offlineSubscription = offline.listen(
        serverDiscoveryProvider,
        (_, __) {},
      );
      expect(await offline.read(serverDiscoveryProvider.future), isEmpty);
      expect(binds, 1);
      offlineSubscription.close();
      offline.dispose();

      final denied = _container(
        bind,
        permission: LocalNetworkPermissionStatus.denied,
      );
      final deniedSubscription = denied.listen(
        serverDiscoveryProvider,
        (_, __) {},
      );
      await expectLater(
        denied.read(serverDiscoveryProvider.future),
        throwsA(isA<LocalNetworkPermissionDeniedException>()),
      );
      expect(binds, 1);
      deniedSubscription.close();
      denied.dispose();
    },
  );

  test('disposal during bind closes the late socket without sending', () async {
    final pending = Completer<RawDatagramSocket>();
    final socket = _SyntheticSocket();
    var binds = 0;
    final container = _container(() {
      binds++;
      return pending.future;
    });
    container.listen(serverDiscoveryProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);
    expect(binds, 1);
    container.dispose();
    pending.complete(socket);
    await Future<void>.delayed(Duration.zero);
    expect(socket.sends, 0);
    expect(socket.closes, 1);
  });
}
