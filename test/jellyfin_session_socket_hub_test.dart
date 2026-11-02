import 'dart:async';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/jellyfin_session_socket_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _uri = Uri.parse(
  'wss://synthetic.invalid/jellyfin/socket?ApiKey=synthetic&deviceId=demo',
);
final _closed = isA<JellyfinSessionSocketClosed>();

class _Socket implements JellyfinSessionSocket {
  _Socket({bool pending = false}) {
    if (!pending) handshake.complete();
  }
  final handshake = Completer<void>();
  final incoming = StreamController<Object?>(sync: true);
  final sent = <String>[];
  int closes = 0;
  bool failSend = false;
  @override
  Future<void> get ready => handshake.future;
  @override
  Stream<Object?> get messages => incoming.stream;
  @override
  void send(String message) {
    if (failSend) throw StateError('synthetic secret must be hidden');
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closes++;
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

class _Fixture {
  _Fixture({bool pending = false}) {
    hub = JellyfinSessionSocketHub(
      connector: (uri, capturedHeaders) {
        final socket = _Socket(pending: pending);
        sockets.add(socket);
        headers.add(capturedHeaders);
        return socket;
      },
    );
  }
  late final JellyfinSessionSocketHub hub;
  final sockets = <_Socket>[];
  final headers = <Map<String, String>>[];
  JellyfinSessionSocket lease({bool Function()? current, Uri? uri}) =>
      hub.factory(isCurrent: current ?? () => true)(uri ?? _uri);
}

class _FailListenSocket extends _Socket {
  _FailListenSocket() : super(pending: true);
  @override
  Stream<Object?> get messages => throw StateError('synthetic secret');
}

class _User extends User {
  _User(this.initial);
  final AccountModel initial;
  @override
  AccountModel? build() => initial;
  void change(AccountModel? next) => state = next;
}

AccountModel _account(String id) => AccountModel(
      name: 'Synthetic',
      id: id,
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
        token: 'synthetic',
        deviceId: 'demo',
        url: 'https://synthetic.invalid/jellyfin',
      ),
    );

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('Web consumers with different captured headers share the URI session',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.hub.dispose);
    JellyfinSessionSocketFactory factory(String label) =>
        jellyfinSessionSocketFactoryForPlatform(
          fixture.hub,
          account: _account('first'),
          isWeb: true,
          isCurrent: () => true,
          headers: {'authorization': 'synthetic device label=$label'},
        );
    final first = factory('before')(_uri);
    final second = factory('after')(_uri);
    final firstMessages = <Object?>[];
    final secondMessages = <Object?>[];
    first.messages.listen(firstMessages.add);
    second.messages.listen(secondMessages.add);
    await Future.wait([first.ready, second.ready]);
    expect(fixture.sockets, hasLength(1));
    expect(fixture.headers.single, isEmpty);
    fixture.sockets.single.incoming.add('shared event');
    expect(firstMessages, ['shared event']);
    expect(secondMessages, ['shared event']);
    await first.close();
    expect(fixture.sockets.single.closes, 0);
    await second.close();
    expect(fixture.sockets.single.closes, 1);
  });

  test('native factories retain header identity and stay inside their scope',
      () async {
    final fixture = _Fixture();
    final otherScope = _Fixture();
    addTearDown(fixture.hub.dispose);
    addTearDown(otherScope.hub.dispose);
    JellyfinSessionSocketFactory factory(
            JellyfinSessionSocketHub hub, String label) =>
        jellyfinSessionSocketFactoryForPlatform(
          hub,
          account: _account('first'),
          isWeb: false,
          isCurrent: () => true,
          headers: {'authorization': 'synthetic device label=$label'},
        );
    final first = factory(fixture.hub, 'before')(_uri);
    final changedHeaders = factory(fixture.hub, 'after')(_uri);
    final otherAccount = factory(otherScope.hub, 'before')(_uri);
    await Future.wait([first.ready, changedHeaders.ready, otherAccount.ready]);
    expect(fixture.sockets, hasLength(2));
    expect(otherScope.sockets, hasLength(1));
    expect(fixture.headers.first['authorization'],
        'synthetic device label=before');
    expect(
        fixture.headers.last['authorization'], 'synthetic device label=after');
    await fixture.hub.dispose();
    expect(fixture.sockets.every((socket) => socket.closes == 1), isTrue);
    expect(otherScope.sockets.single.closes, 0);
    otherAccount.send('still current');
    expect(otherScope.sockets.single.sent, ['still current']);
  });

  for (final isWeb in [true, false]) {
    test('${isWeb ? 'Web' : 'native'} rejects URIs outside captured account',
        () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      final factory = jellyfinSessionSocketFactoryForPlatform(
        fixture.hub,
        account: _account('first'),
        isWeb: isWeb,
        isCurrent: () => true,
        headers: {'authorization': 'synthetic captured authorization'},
      );
      final invalid = <String, Uri>{
        'origin': _uri.replace(host: 'other.invalid'),
        'scheme': _uri.replace(scheme: 'ws'),
        'port': _uri.replace(port: 8920),
        'base path': _uri.replace(path: '/other/socket'),
        'token': _uri.replace(queryParameters: {
          'ApiKey': 'other synthetic',
          'deviceId': 'demo',
        }),
        'device': _uri.replace(queryParameters: {
          'ApiKey': 'synthetic',
          'deviceId': 'other device',
        }),
        'extra query': _uri.replace(queryParameters: {
          'ApiKey': 'synthetic',
          'deviceId': 'demo',
          'extra': 'unexpected',
        }),
        'duplicate query':
            _uri.replace(query: 'ApiKey=synthetic&deviceId=demo&deviceId=demo'),
        'userinfo': _uri.replace(userInfo: 'synthetic-user'),
        'fragment': _uri.replace(fragment: 'unexpected'),
        'empty fragment': _uri.replace(fragment: ''),
      };
      for (final entry in invalid.entries) {
        expect(() => factory(entry.value), throwsA(_closed), reason: entry.key);
        expect(fixture.sockets, isEmpty, reason: entry.key);
      }
      final allowed = factory(_uri);
      await allowed.ready;
      expect(fixture.sockets, hasLength(1));
    });
  }

  test('captured URI preserves scheme, port and middle empty path segments',
      () async {
    final examples = <String, String>{
      'https://synthetic.invalid:8920/jellyfin//nested///':
          'wss://synthetic.invalid:8920/jellyfin//nested/socket?ApiKey=synthetic&deviceId=demo',
      'http://synthetic.invalid:8096/jellyfin%20demo/':
          'ws://synthetic.invalid:8096/jellyfin%20demo/socket?ApiKey=synthetic&deviceId=demo',
    };
    for (final entry in examples.entries) {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      final account = _account('first');
      final factory = jellyfinSessionSocketFactoryForPlatform(
        fixture.hub,
        account: account.copyWith(
            credentials: account.credentials.copyWith(url: entry.key)),
        isWeb: true,
        isCurrent: () => true,
      );
      final uri = Uri.parse(entry.value);
      expect(() => factory(uri.replace(port: uri.port + 1)), throwsA(_closed));
      expect(fixture.sockets, isEmpty);
      if (uri.path.contains('//')) {
        expect(() => factory(uri.replace(path: '/jellyfin/nested/socket')),
            throwsA(_closed));
        expect(fixture.sockets, isEmpty);
      }
      final lease = factory(uri);
      await lease.ready;
      expect(fixture.sockets, hasLength(1));
    }
  });

  test('invalid captured account fails safely before physical factory creation',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.hub.dispose);
    final account = _account('first');
    final invalidCredentials = [
      account.credentials.copyWith(url: 'not an absolute URI'),
      account.credentials.copyWith(url: 'ftp://synthetic.invalid'),
      account.credentials.copyWith(url: 'https://synthetic@synthetic.invalid'),
      account.credentials
          .copyWith(url: 'https://synthetic.invalid?extra=value'),
      account.credentials.copyWith(url: 'https://synthetic.invalid#fragment'),
      account.credentials.copyWith(token: ''),
      account.credentials.copyWith(deviceId: ''),
    ];
    for (final credentials in invalidCredentials) {
      expect(
          () => jellyfinSessionSocketFactoryForPlatform(fixture.hub,
              account: account.copyWith(credentials: credentials),
              isWeb: false,
              isCurrent: () => true,
              headers: {'authorization': 'synthetic captured authorization'}),
          throwsA(_closed));
      expect(fixture.sockets, isEmpty);
    }
  });

  test(
    'two leases share one physical socket and each event arrives once',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      final first = fixture.lease();
      final second = fixture.lease();
      final firstMessages = <Object?>[];
      final secondMessages = <Object?>[];
      final a = first.messages.listen(firstMessages.add);
      final b = second.messages.listen(secondMessages.add);
      await Future.wait([first.ready, second.ready]);
      expect(fixture.sockets, hasLength(1));
      final physical = fixture.sockets.single;
      physical.incoming.add('one');
      physical.incoming.add('two');
      expect(firstMessages, ['one', 'two']);
      expect(secondMessages, ['one', 'two']);
      first.send('first mutation');
      second.send('second mutation');
      expect(physical.sent, ['first mutation', 'second mutation']);
      await first.close();
      expect(physical.closes, 0);
      physical.incoming.add('three');
      expect(firstMessages, ['one', 'two']);
      expect(secondMessages, ['one', 'two', 'three']);
      expect(() => first.send('forbidden'), throwsA(_closed));
      await second.close();
      await second.close();
      await first.close();
      expect(physical.closes, 1);
      await a.cancel();
      await b.cancel();
    },
  );

  test(
    'factory is lazy and captures immutable headers for exact identity',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      final headers = {'authorization': 'synthetic first'};
      final factory = fixture.hub.factory(
        isCurrent: () => true,
        headers: headers,
      );
      headers['authorization'] = 'synthetic changed';
      expect(fixture.sockets, isEmpty);
      final first = factory(_uri);
      final same = fixture.hub.factory(
        isCurrent: () => true,
        headers: {'authorization': 'synthetic first'},
      )(_uri);
      final changedHeader = fixture.hub.factory(
        isCurrent: () => true,
        headers: headers,
      )(_uri);
      final changedUri = factory(_uri.replace(path: '/other/socket'));
      await Future.wait([
        first.ready,
        same.ready,
        changedHeader.ready,
        changedUri.ready,
      ]);
      expect(fixture.sockets, hasLength(3));
      expect(fixture.headers.first['authorization'], 'synthetic first');
      expect(
        () => fixture.headers.first['authorization'] = 'bad',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'last release removes entry and a later explicit lease connects anew',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      final first = fixture.lease();
      await first.ready;
      await first.close();
      final second = fixture.lease();
      await second.ready;
      expect(fixture.sockets, hasLength(2));
      expect(fixture.sockets.first.closes, 1);
      expect(fixture.sockets.last.closes, 0);
    },
  );

  test(
    'handshake errors safely invalidate every lease without retry',
    () async {
      final fixture = _Fixture(pending: true);
      addTearDown(fixture.hub.dispose);
      final first = fixture.lease();
      final second = fixture.lease();
      final errors = <Object>[];
      final a = first.messages.listen((_) {}, onError: errors.add);
      final b = second.messages.listen((_) {}, onError: errors.add);
      final ready = Future.wait([
        expectLater(first.ready, throwsA(_closed)),
        expectLater(second.ready, throwsA(_closed)),
      ]);
      fixture.sockets.single.handshake.completeError(
        StateError('synthetic secret must be hidden'),
      );
      await ready;
      await _flush();
      expect(errors, hasLength(2));
      expect(
        errors.every((error) => error is JellyfinSessionSocketClosed),
        isTrue,
      );
      expect(errors.join(), isNot(contains('synthetic secret')));
      expect(fixture.sockets, hasLength(1));
      expect(fixture.sockets.single.closes, 1);
      expect(() => first.send('forbidden'), throwsA(_closed));
      await a.cancel();
      await b.cancel();
    },
  );

  for (final error in [false, true]) {
    test(
      'physical ${error ? 'error' : 'close'} invalidates all leases',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.hub.dispose);
        final first = fixture.lease();
        final second = fixture.lease();
        var ended = 0;
        final errors = <Object>[];
        first.messages.listen(
          (_) {},
          onError: errors.add,
          onDone: () => ended++,
        );
        second.messages.listen(
          (_) {},
          onError: errors.add,
          onDone: () => ended++,
        );
        await Future.wait([first.ready, second.ready]);
        final physical = fixture.sockets.single;
        if (error) {
          physical.incoming.addError(StateError('synthetic secret'));
        } else {
          unawaited(physical.incoming.close());
        }
        await _flush();
        expect(ended, 2);
        expect(errors, hasLength(2));
        expect(physical.closes, 1);
        expect(() => first.send('forbidden'), throwsA(_closed));
        expect(() => second.send('forbidden'), throwsA(_closed));
        expect(fixture.sockets, hasLength(1));
        await first.close();
        await second.close();
      },
    );
  }

  test('send failure ends every lease without replaying a mutation', () async {
    final fixture = _Fixture();
    addTearDown(fixture.hub.dispose);
    final first = fixture.lease();
    final second = fixture.lease();
    await Future.wait([first.ready, second.ready]);
    fixture.sockets.single.failSend = true;
    expect(() => first.send('mutation'), throwsA(_closed));
    expect(() => second.send('mutation'), throwsA(_closed));
    expect(fixture.sockets.single.sent, isEmpty);
    expect(fixture.sockets, hasLength(1));
  });

  test(
    'stale lease cannot send or receive while current lease survives',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      var current = true;
      final first = fixture.lease(current: () => current);
      final second = fixture.lease();
      final firstMessages = <Object?>[];
      final secondMessages = <Object?>[];
      first.messages.listen(firstMessages.add);
      second.messages.listen(secondMessages.add);
      await Future.wait([first.ready, second.ready]);
      current = false;
      fixture.sockets.single.incoming.add('new event');
      expect(firstMessages, isEmpty);
      expect(secondMessages, ['new event']);
      expect(() => first.send('forbidden'), throwsA(_closed));
      second.send('allowed');
      expect(fixture.sockets.single.sent, ['allowed']);
      expect(fixture.sockets.single.closes, 0);
      await second.close();
    },
  );

  test(
    'scope disposal is immediate and cannot revive after switching back',
    () async {
      final old = _Fixture(pending: true);
      final replacement = _Fixture();
      addTearDown(old.hub.dispose);
      addTearDown(replacement.hub.dispose);
      final oldFactory = old.hub.factory(isCurrent: () => true);
      final lease = oldFactory(_uri);
      final ready = expectLater(lease.ready, throwsA(_closed));
      final disposing = old.hub.dispose();
      expect(() => lease.send('forbidden'), throwsA(_closed));
      expect(() => oldFactory(_uri), throwsA(_closed));
      final next = replacement.lease();
      await next.ready;
      old.sockets.single.handshake.complete();
      await ready;
      await disposing;
      expect(old.sockets.single.closes, 1);
      expect(replacement.sockets.single.closes, 0);
      expect(old.sockets, hasLength(1));
    },
  );

  test(
    'late handshake and duplicate lease/dispose close only captured socket',
    () async {
      final fixture = _Fixture(pending: true);
      final lease = fixture.lease();
      final ready = expectLater(lease.ready, throwsA(_closed));
      await lease.close();
      await lease.close();
      fixture.sockets.single.handshake.complete();
      await ready;
      await fixture.hub.dispose();
      await fixture.hub.dispose();
      expect(fixture.sockets.single.closes, 1);
      expect(() => lease.send('forbidden'), throwsA(_closed));
      await expectLater(lease.ready, throwsA(_closed));
    },
  );

  test('releasing one pending lease leaves the other handshake alive',
      () async {
    final fixture = _Fixture(pending: true);
    addTearDown(fixture.hub.dispose);
    final first = fixture.lease();
    final second = fixture.lease();
    final endedReady = expectLater(first.ready, throwsA(_closed));
    await first.close();
    expect(fixture.sockets.single.closes, 0);
    fixture.sockets.single.handshake.complete();
    await second.ready;
    await endedReady;
    second.send('allowed');
    expect(fixture.sockets.single.sent, ['allowed']);
  });

  test('pending handshake checks the lease owner generation again', () async {
    final fixture = _Fixture(pending: true);
    addTearDown(fixture.hub.dispose);
    var current = true;
    final lease = fixture.lease(current: () => current);
    final ready = expectLater(lease.ready, throwsA(_closed));
    current = false;
    fixture.sockets.single.handshake.complete();
    await ready;
    expect(fixture.sockets.single.closes, 1);
    expect(() => lease.send('forbidden'), throwsA(_closed));
  });

  test('connector failure exposes no credential/error details', () async {
    final hub = JellyfinSessionSocketHub(
      connector: (_, __) {
        throw StateError('synthetic secret');
      },
    );
    addTearDown(hub.dispose);
    expect(() => hub.factory(isCurrent: () => true)(_uri), throwsA(_closed));
  });

  test(
    'a socket returned after scope disposal is closed and never leased',
    () async {
      final physical = _Socket(pending: true);
      late final JellyfinSessionSocketHub hub;
      hub = JellyfinSessionSocketHub(
        connector: (_, __) {
          unawaited(hub.dispose());
          return physical;
        },
      );
      expect(() => hub.factory(isCurrent: () => true)(_uri), throwsA(_closed));
      physical.handshake.completeError(StateError('synthetic secret'));
      await _flush();
      expect(physical.closes, 1);
    },
  );

  test(
    'listen failure still observes and sanitizes a late handshake error',
    () async {
      final physical = _FailListenSocket();
      final hub = JellyfinSessionSocketHub(connector: (_, __) => physical);
      addTearDown(hub.dispose);
      final lease = hub.factory(isCurrent: () => true)(_uri);
      await expectLater(lease.ready, throwsA(_closed));
      physical.handshake.completeError(StateError('synthetic secret'));
      await _flush();
      expect(physical.closes, 1);
    },
  );

  test('a synchronous listener may release its own lease', () async {
    final fixture = _Fixture();
    addTearDown(fixture.hub.dispose);
    final first = fixture.lease();
    final second = fixture.lease();
    final received = <Object?>[];
    var firstEnded = false;
    first.messages.listen(
      (_) => unawaited(first.close()),
      onDone: () => firstEnded = true,
    );
    second.messages.listen(received.add);
    await Future.wait([first.ready, second.ready]);
    fixture.sockets.single.incoming.add('one');
    fixture.sockets.single.incoming.add('two');
    await _flush();
    expect(firstEnded, isTrue);
    expect(received, ['one', 'two']);
    expect(fixture.sockets.single.closes, 0);
  });

  for (final sendFailure in [false, true]) {
    test(
      'synchronous listener can ${sendFailure ? 'fail send' : 'dispose hub'}',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.hub.dispose);
        final first = fixture.lease();
        final second = fixture.lease();
        var ended = 0;
        final errors = <Object>[];
        first.messages.listen(
          (_) {
            if (sendFailure) {
              fixture.sockets.single.failSend = true;
              expect(() => first.send('mutation'), throwsA(_closed));
            } else {
              unawaited(fixture.hub.dispose());
            }
          },
          onError: errors.add,
          onDone: () => ended++,
        );
        second.messages.listen(
          (_) {},
          onError: errors.add,
          onDone: () => ended++,
        );
        await Future.wait([first.ready, second.ready]);
        fixture.sockets.single.incoming.add('one');
        await _flush();
        expect(ended, 2);
        expect(errors, hasLength(sendFailure ? 2 : 0));
        expect(fixture.sockets.single.closes, 1);
        expect(() => second.send('forbidden'), throwsA(_closed));
      },
    );
  }

  test(
    'throwing or stale owner guard fails closed before opening a socket',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.hub.dispose);
      expect(() => fixture.lease(current: () => false), throwsA(_closed));
      expect(
        () => fixture.lease(current: () => throw StateError('hidden')),
        throwsA(_closed),
      );
      expect(fixture.sockets, isEmpty);
    },
  );

  test(
    'provider retires each credential/account generation synchronously',
    () async {
      final account = _account('first');
      final user = _User(account);
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(() => user)],
      );
      addTearDown(container.dispose);
      final original = container.read(jellyfinSessionSocketHubProvider);
      user.change(account.copyWith(name: 'Profile-only change'));
      expect(container.read(jellyfinSessionSocketHubProvider), same(original));
      user.change(
        account.copyWith(
          credentials: account.credentials.copyWith(token: 'replacement'),
        ),
      );
      expect(
        () => original.factory(isCurrent: () => true)(_uri),
        throwsA(_closed),
      );
      final credentialGeneration = container.read(
        jellyfinSessionSocketHubProvider,
      );
      expect(credentialGeneration, isNot(same(original)));
      user.change(_account('second'));
      expect(
        () => credentialGeneration.factory(isCurrent: () => true)(_uri),
        throwsA(_closed),
      );
      final second = container.read(jellyfinSessionSocketHubProvider);
      user.change(account);
      expect(
        () => second.factory(isCurrent: () => true)(_uri),
        throwsA(_closed),
      );
      expect(
        container.read(jellyfinSessionSocketHubProvider),
        isNot(same(original)),
      );
    },
  );
}
