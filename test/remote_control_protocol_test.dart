import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_control_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _binding = RemotePlaybackBinding(
  itemId: 'movie-one',
  mediaSourceId: 'source-one',
  playbackId: 'jms-remote-occurrence-one',
);
final _now = DateTime.utc(2026, 11, 2, 12);

Map<String, dynamic> _message({
  String name = 'PlayState',
  Map<String, dynamic> arguments = const {},
}) =>
    {
      'Name': name,
      'ControllingUserId': 'user-one',
      'Arguments': <String, dynamic>{
        'JmsRemoteVersion': '1',
        'JmsTargetSessionId': 'target-session',
        'JmsItemId': 'movie-one',
        'JmsMediaSourceId': 'source-one',
        'JmsPlaybackId': 'jms-remote-occurrence-one',
        'JmsControllerId': 'controller-one',
        'JmsRequestId': 'request-one',
        'JmsSequence': '1',
        'JmsIssuedAt': '2026-11-02T12:00:00.000Z',
        'JmsExpiresAt': '2026-11-02T12:00:10.000Z',
        if (name == 'PlayState') 'Command': 'Pause',
        ...arguments,
      },
    };

RemoteControlCommand? _parse(
  Object? message, {
  DateTime? now,
  String userId = 'user-one',
  String sessionId = 'target-session',
  RemotePlaybackBinding binding = _binding,
}) =>
    RemoteControlProtocol.parse(
      message,
      userId: userId,
      sessionId: sessionId,
      binding: binding,
      now: now ?? _now,
    );

Map<String, dynamic> _encode({
  String userId = 'user-one',
  String sessionId = 'target-session',
  RemotePlaybackBinding binding = _binding,
  String controllerId = 'controller-one',
  String requestId = 'request-one',
  int sequence = 1,
  RemoteAction action = const RemoteAction.pause(),
}) =>
    RemoteControlProtocol.encode(
      userId: userId,
      sessionId: sessionId,
      binding: binding,
      action: action,
      controllerId: controllerId,
      requestId: requestId,
      sequence: sequence,
      now: _now,
    ).toJson();

RemoteControlCommand _guardCommand({
  String controller = 'controller-one',
  String request = 'request-one',
  int sequence = 1,
}) =>
    RemoteControlCommand(
      action: const RemoteAction.pause(),
      binding: _binding,
      sessionId: 'target-session',
      controllerId: controller,
      requestId: request,
      sequence: sequence,
      issuedAt: _now,
      expiresAt: _now.add(const Duration(seconds: 10)),
      controllingUserId: 'user-one',
    );

void main() {
  group('remote command protocol', () {
    test('accepts the direct command and complete GeneralCommand envelope', () {
      final direct = _parse(_message())!;
      expect(direct.action, const RemoteAction.pause());
      expect(direct.binding, _binding);
      expect(direct.sessionId, 'target-session');
      expect(direct.controllerId, 'controller-one');
      expect(direct.requestId, 'request-one');
      expect(direct.sequence, 1);
      expect(direct.controllingUserId, 'user-one');
      expect(direct.issuedAt, _now);
      expect(direct.expiresAt, _now.add(const Duration(seconds: 10)));
      expect(
        _parse({'MessageType': 'GeneralCommand', 'Data': _message()})?.action,
        const RemoteAction.pause(),
      );
    });

    test(
      'only accepts the explicitly supported playback and subtitle actions',
      () {
        expect(
          _parse(_message(arguments: {'Command': 'Unpause'}))?.action,
          const RemoteAction.play(),
        );
        expect(
          _parse(
            _message(
              arguments: {'Command': 'Seek', 'SeekPositionTicks': '123456780'},
            ),
          )?.action,
          const RemoteAction.seek(Duration(microseconds: 12345678)),
        );
        for (final index in ['-1', '0', '7']) {
          expect(
            _parse(
              _message(
                name: 'SetSubtitleStreamIndex',
                arguments: {'Index': index},
              ),
            )?.action,
            RemoteAction.subtitle(int.parse(index)),
          );
        }
        for (final name in ['Playstate', 'Shutdown', 'SetAudioStreamIndex']) {
          expect(_parse(_message(name: name)), isNull, reason: name);
        }
        for (final command in ['Stop', 'PlayPause', 'pause', '']) {
          expect(
            _parse(_message(arguments: {'Command': command})),
            isNull,
            reason: command,
          );
        }
      },
    );

    test('rejects account, session and playback occurrence mismatches', () {
      for (final field in [
        'JmsRemoteVersion',
        'JmsTargetSessionId',
        'JmsItemId',
        'JmsMediaSourceId',
        'JmsPlaybackId',
      ]) {
        final message = _message();
        (message['Arguments'] as Map)[field] = 'different';
        expect(_parse(message), isNull, reason: field);
      }
      for (final user in [null, '', 'user-two']) {
        expect(_parse(_message()..['ControllingUserId'] = user), isNull);
      }
      expect(_parse({'MessageType': 'Playstate', 'Data': _message()}), isNull);
    });

    test(
      'every metadata field is required and arguments must all be strings',
      () {
        final requiredFields = (_message()['Arguments'] as Map).keys.toList();
        for (final field in requiredFields) {
          final missing = _message();
          (missing['Arguments'] as Map).remove(field);
          expect(_parse(missing), isNull, reason: 'missing $field');
        }
        for (final value in [null, 1, true, <String>[], <String, String>{}]) {
          expect(_parse(_message(arguments: {'Extra': value})), isNull);
        }
        for (final field in ['JmsControllerId', 'JmsRequestId']) {
          for (final value in ['', ' padded ']) {
            expect(_parse(_message(arguments: {field: value})), isNull);
          }
        }
        for (final value in [null, false, [], 'not decoded']) {
          expect(_parse(value), isNull);
        }
      },
    );

    test('rejects malformed sequences, negative seeks and invalid indices', () {
      for (final sequence in [
        '0',
        '-1',
        '+1',
        '01',
        '1.0',
        '1e3',
        ' 1',
        '999999999999999999999999999999999',
      ]) {
        expect(
          _parse(_message(arguments: {'JmsSequence': sequence})),
          isNull,
          reason: sequence,
        );
      }
      for (final ticks in [null, '-1', '1.5', '1e3', ' 10', '+10']) {
        expect(
          _parse(
            _message(
              arguments: {'Command': 'Seek', 'SeekPositionTicks': ticks},
            ),
          ),
          isNull,
          reason: '$ticks',
        );
      }
      expect(
        _parse(
          _message(arguments: {'Command': 'Seek', 'SeekPositionTicks': '0'}),
        )?.action,
        const RemoteAction.seek(Duration.zero),
      );
      for (final index in [null, '-2', '1.0', ' 1', '+1']) {
        expect(
          _parse(
            _message(
              name: 'SetSubtitleStreamIndex',
              arguments: {'Index': index},
            ),
          ),
          isNull,
          reason: '$index',
        );
      }
    });

    test('enforces expiration, maximum TTL and bounded future clock skew', () {
      expect(
        _parse(_message(), now: _now.add(const Duration(seconds: 10))),
        isNull,
      );
      expect(
        _parse(_message(), now: _now.add(const Duration(seconds: 9))),
        isNotNull,
      );
      expect(
        _parse(_message(), now: _now.subtract(const Duration(seconds: 5))),
        isNotNull,
      );
      expect(
        _parse(_message(), now: _now.subtract(const Duration(seconds: 6))),
        isNull,
      );
      expect(
        _parse(
          _message(arguments: {'JmsExpiresAt': '2026-11-02T12:00:15.000Z'}),
        ),
        isNotNull,
      );
      for (final expiration in [
        '2026-11-02T12:00:15.000001Z',
        '2026-11-02T12:00:00.000Z',
        '2026-11-02T11:59:59.000Z',
      ]) {
        expect(
          _parse(_message(arguments: {'JmsExpiresAt': expiration})),
          isNull,
        );
      }
    });

    test(
      'rejects local dates, non-UTC offsets and normalized invalid dates',
      () {
        for (final timestamp in [
          '2026-11-02T12:00:00',
          '2026-11-02T12:00:00+00:00',
          '2026-11-02 12:00:00Z',
          '2026-10-33T12:00:00Z',
          '2026-11-02T11:60:00Z',
          '2026-11-02T11:59:60Z',
          '20261102T120000Z',
        ]) {
          expect(
            _parse(_message(arguments: {'JmsIssuedAt': timestamp})),
            isNull,
            reason: timestamp,
          );
        }
      },
    );

    test('encodes string-only wire arguments and each action round trips', () {
      for (final action in [
        const RemoteAction.play(),
        const RemoteAction.pause(),
        const RemoteAction.seek(Duration(milliseconds: 1234)),
        const RemoteAction.subtitle(-1),
        const RemoteAction.subtitle(2),
      ]) {
        final encoded = RemoteControlProtocol.encode(
          userId: 'user-one',
          sessionId: 'target-session',
          binding: _binding,
          action: action,
          controllerId: 'controller-one',
          requestId: 'request-one',
          sequence: 42,
          now: _now,
        );
        expect(encoded.arguments!.values, everyElement(isA<String>()));
        expect(encoded.arguments!['JmsSequence'], '42');
        expect(_parse(encoded.toJson())?.action, action);
        if (action.type == RemoteActionType.seek) {
          expect(encoded.arguments!['SeekPositionTicks'], '12340000');
        }
      }
    });

    test('rejects matching bindings that do not identify a JMS occurrence', () {
      for (final playbackId in ['', 'other-occurrence', 'jms-remote-']) {
        final binding = RemotePlaybackBinding(
          itemId: _binding.itemId,
          mediaSourceId: _binding.mediaSourceId,
          playbackId: playbackId,
        );
        expect(
          _parse(_message(arguments: {'JmsPlaybackId': playbackId}),
              binding: binding),
          isNull,
        );
        expect(() => _encode(binding: binding), throwsArgumentError);
      }
    });

    test('accepts scope and controller identifiers exactly at their limits',
        () {
      final scopeId = 's'.padRight(1024, 's');
      final controllerId = 'c'.padRight(128, 'c');
      final binding = RemotePlaybackBinding(
        itemId: scopeId,
        mediaSourceId: scopeId,
        playbackId: 'jms-remote-'.padRight(1024, 'p'),
      );
      final message = _encode(
        userId: scopeId,
        sessionId: scopeId,
        binding: binding,
        controllerId: controllerId,
        requestId: controllerId,
      );
      expect(
          _parse(message,
              userId: scopeId, sessionId: scopeId, binding: binding),
          isNotNull);
    });

    test(
        'rejects oversized matching scopes and oversized controller identifiers',
        () {
      final longId = 's'.padRight(1025, 's');
      final scopes = <String, RemotePlaybackBinding>{
        'JmsItemId': RemotePlaybackBinding(
          itemId: longId,
          mediaSourceId: _binding.mediaSourceId,
          playbackId: _binding.playbackId,
        ),
        'JmsMediaSourceId': RemotePlaybackBinding(
          itemId: _binding.itemId,
          mediaSourceId: longId,
          playbackId: _binding.playbackId,
        ),
        'JmsPlaybackId': RemotePlaybackBinding(
          itemId: _binding.itemId,
          mediaSourceId: _binding.mediaSourceId,
          playbackId: 'jms-remote-'.padRight(1025, 'p'),
        ),
      };
      for (final entry in scopes.entries) {
        final value =
            entry.key == 'JmsPlaybackId' ? entry.value.playbackId : longId;
        expect(
            _parse(_message(arguments: {entry.key: value}),
                binding: entry.value),
            isNull,
            reason: entry.key);
        expect(() => _encode(binding: entry.value), throwsArgumentError);
      }
      final wrongSession = _message(arguments: {'JmsTargetSessionId': longId});
      expect(_parse(wrongSession, sessionId: longId), isNull);
      expect(() => _encode(sessionId: longId), throwsArgumentError);
      expect(_parse(_message()..['ControllingUserId'] = longId, userId: longId),
          isNull);
      expect(() => _encode(userId: longId), throwsArgumentError);
      for (final field in ['JmsControllerId', 'JmsRequestId']) {
        expect(_parse(_message(arguments: {field: 'x'.padRight(129, 'x')})),
            isNull);
      }
      expect(() => _encode(controllerId: 'x'.padRight(129, 'x')),
          throwsArgumentError);
      expect(() => _encode(requestId: 'x'.padRight(129, 'x')),
          throwsArgumentError);
    });

    test('rejects unknown, unrelated and oversized command arguments', () {
      for (final arguments in [
        {'Unknown': 'value'},
        {'Index': '-1'},
        {'SeekPositionTicks': '0'},
        {'JmsIssuedAt': 'x'.padRight(4097, 'x')},
        {'One': '1', 'Two': '2'},
      ]) {
        expect(_parse(_message(arguments: arguments)), isNull);
      }
      expect(
          _parse(_message(arguments: {
            'Command': 'Seek',
            'SeekPositionTicks': '0',
            'Index': '-1',
          })),
          isNull);
      for (final arguments in [
        {'Index': '-1', 'Command': 'Pause'},
        {'Index': '-1', 'SeekPositionTicks': '0'},
      ]) {
        expect(
            _parse(
                _message(name: 'SetSubtitleStreamIndex', arguments: arguments)),
            isNull);
      }
    });

    test('bounds wire numbers to integers representable safely on the web', () {
      const maximum = 9007199254740991;
      expect(_parse(_message(arguments: {'JmsSequence': '$maximum'}))?.sequence,
          maximum);
      expect(_parse(_message(arguments: {'JmsSequence': '${maximum + 1}'})),
          isNull);
      expect(
          _parse(_message(
              name: 'SetSubtitleStreamIndex',
              arguments: {'Index': '$maximum'}))?.action,
          const RemoteAction.subtitle(maximum));
      expect(
          _parse(_message(
              name: 'SetSubtitleStreamIndex',
              arguments: {'Index': '${maximum + 1}'})),
          isNull);
      expect(
          _parse(_message(arguments: {
            'Command': 'Seek',
            'SeekPositionTicks': '$maximum',
          }))?.action,
          const RemoteAction.seek(Duration(microseconds: maximum ~/ 10)));
      expect(
          _parse(_message(arguments: {
            'Command': 'Seek',
            'SeekPositionTicks': '${maximum + 1}',
          })),
          isNull);
      expect(_parse(_encode(sequence: maximum))?.sequence, maximum);
      expect(() => _encode(sequence: maximum + 1), throwsArgumentError);
      expect(
          _parse(_encode(action: const RemoteAction.subtitle(maximum)))?.action,
          const RemoteAction.subtitle(maximum));
      expect(() => _encode(action: const RemoteAction.subtitle(maximum + 1)),
          throwsArgumentError);
      expect(
          _parse(_encode(
              action: const RemoteAction.seek(
            Duration(microseconds: maximum ~/ 10),
          )))?.action,
          const RemoteAction.seek(Duration(microseconds: maximum ~/ 10)));
      expect(
          () => _encode(
                  action: const RemoteAction.seek(
                Duration(microseconds: maximum ~/ 10 + 1),
              )),
          throwsArgumentError);
    });

    test('encoder rejects invalid metadata and unsafe action values', () {
      void encode({
        int sequence = 1,
        Duration ttl = const Duration(seconds: 10),
        RemoteAction action = const RemoteAction.pause(),
        String controllerId = 'controller-one',
      }) =>
          RemoteControlProtocol.encode(
            userId: 'user-one',
            sessionId: 'target-session',
            binding: _binding,
            action: action,
            controllerId: controllerId,
            requestId: 'request-one',
            sequence: sequence,
            now: _now,
            ttl: ttl,
          );
      expect(() => encode(sequence: 0), throwsArgumentError);
      expect(() => encode(ttl: Duration.zero), throwsArgumentError);
      expect(
        () => encode(ttl: const Duration(seconds: 16)),
        throwsArgumentError,
      );
      expect(() => encode(controllerId: ''), throwsArgumentError);
      expect(
        () => encode(action: const RemoteAction.subtitle(-2)),
        throwsArgumentError,
      );
      expect(
        () => encode(action: const RemoteAction.seek(Duration(seconds: -1))),
        throwsArgumentError,
      );
    });
  });

  group('remote command guard', () {
    test(
      'deduplicates requests and enforces increasing sequence per controller',
      () {
        final guard = RemoteCommandGuard();
        expect(guard.accept(_guardCommand(sequence: 2)), isTrue);
        expect(guard.accept(_guardCommand(sequence: 3)), isFalse);
        expect(
          guard.accept(_guardCommand(request: 'older', sequence: 1)),
          isFalse,
        );
        expect(
          guard.accept(_guardCommand(request: 'same-sequence', sequence: 2)),
          isFalse,
        );
        expect(
          guard.accept(_guardCommand(request: 'newer', sequence: 3)),
          isTrue,
        );
        expect(
          guard.accept(_guardCommand(controller: 'controller-two')),
          isTrue,
        );
        expect(
          guard.accept(_guardCommand(request: 'zero', sequence: 0)),
          isFalse,
        );
      },
    );

    test('request keys do not collide when identifiers contain separators', () {
      final guard = RemoteCommandGuard();
      expect(
        guard.accept(_guardCommand(controller: 'a:b', request: 'c')),
        isTrue,
      );
      expect(
        guard.accept(_guardCommand(controller: 'a', request: 'b:c')),
        isTrue,
      );
    });

    test('request LRU retains recently accessed entries and evicts at 64', () {
      final guard = RemoteCommandGuard();
      for (var index = 0; index < 64; index++) {
        expect(
          guard.accept(_guardCommand(request: 'r$index', sequence: index + 1)),
          isTrue,
        );
      }
      expect(
        guard.accept(_guardCommand(request: 'r0', sequence: 100)),
        isFalse,
      );
      expect(guard.accept(_guardCommand(request: 'r64', sequence: 65)), isTrue);
      expect(guard.accept(_guardCommand(request: 'r1', sequence: 66)), isTrue);
      expect(guard.accept(_guardCommand(request: 'r0', sequence: 67)), isFalse);
    });

    test(
      'controller LRU is bounded separately and clear resets both caches',
      () {
        final guard = RemoteCommandGuard();
        for (var index = 0; index < 64; index++) {
          expect(guard.accept(_guardCommand(controller: 'c$index')), isTrue);
        }
        expect(
          guard.accept(
            _guardCommand(controller: 'c0', request: 'touch', sequence: 2),
          ),
          isTrue,
        );
        expect(guard.accept(_guardCommand(controller: 'c64')), isTrue);
        expect(
          guard.accept(_guardCommand(controller: 'c1', request: 'again')),
          isTrue,
        );
        expect(
          guard.accept(_guardCommand(controller: 'c0', request: 'stale')),
          isFalse,
        );
        guard.clear();
        expect(guard.accept(_guardCommand(controller: 'c0')), isTrue);
        expect(guard.accept(_guardCommand(controller: 'c0')), isFalse);
      },
    );
  });
}
