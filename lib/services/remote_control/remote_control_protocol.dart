import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/remote_control/remote_control_models.dart';

class RemoteControlCommand {
  const RemoteControlCommand({
    required this.action,
    required this.binding,
    required this.sessionId,
    required this.controllerId,
    required this.requestId,
    required this.sequence,
    required this.issuedAt,
    required this.expiresAt,
    required this.controllingUserId,
  });

  final RemoteAction action;
  final RemotePlaybackBinding binding;
  final String sessionId;
  final String controllerId;
  final String requestId;
  final int sequence;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String controllingUserId;
}

/// The bounded JMS command subset carried by Jellyfin GeneralCommand.
class RemoteControlProtocol {
  static const _maximumTtl = Duration(seconds: 15);
  static const _clockSkew = Duration(seconds: 5);
  static const _maximumInteger = 9007199254740991;
  static const _metadataKeys = {
    'JmsRemoteVersion',
    'JmsTargetSessionId',
    'JmsItemId',
    'JmsMediaSourceId',
    'JmsPlaybackId',
    'JmsControllerId',
    'JmsRequestId',
    'JmsSequence',
    'JmsIssuedAt',
    'JmsExpiresAt',
  };
  static final _unsignedInteger = RegExp(r'^(0|[1-9][0-9]*)$');
  static final _utcTimestamp = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$',
  );

  static RemoteControlCommand? parse(
    Object? message, {
    required String userId,
    required String sessionId,
    required RemotePlaybackBinding binding,
    required DateTime now,
  }) {
    if (message is! Map ||
        !_validId(userId) ||
        !_validId(sessionId) ||
        !_validBinding(binding)) {
      return null;
    }
    Map command = message;
    if (message.containsKey('MessageType')) {
      if (message['MessageType'] != 'GeneralCommand' ||
          message['Data'] is! Map) {
        return null;
      }
      command = message['Data'] as Map;
    }
    if (command['ControllingUserId'] != userId ||
        command['Arguments'] is! Map) {
      return null;
    }
    final rawArguments = command['Arguments'] as Map;
    if (rawArguments.length > 12 ||
        rawArguments.entries.any(
          (entry) =>
              entry.key is! String ||
              entry.value is! String ||
              (entry.value as String).length > 4096,
        )) {
      return null;
    }
    final arguments = Map<String, String>.from(rawArguments);
    final controllerId = arguments['JmsControllerId'];
    final requestId = arguments['JmsRequestId'];
    if (arguments['JmsRemoteVersion'] != '1' ||
        arguments['JmsTargetSessionId'] != sessionId ||
        arguments['JmsItemId'] != binding.itemId ||
        arguments['JmsMediaSourceId'] != binding.mediaSourceId ||
        arguments['JmsPlaybackId'] != binding.playbackId ||
        !_validId(controllerId, maxLength: 128) ||
        !_validId(requestId, maxLength: 128)) {
      return null;
    }
    final sequence = _nonnegativeInteger(arguments['JmsSequence']);
    final issuedAt = _parseUtc(arguments['JmsIssuedAt']);
    final expiresAt = _parseUtc(arguments['JmsExpiresAt']);
    if (sequence == null ||
        sequence == 0 ||
        issuedAt == null ||
        expiresAt == null) {
      return null;
    }
    final ttl = expiresAt.difference(issuedAt);
    if (ttl <= Duration.zero ||
        ttl > _maximumTtl ||
        issuedAt.isAfter(now.add(_clockSkew)) ||
        !expiresAt.isAfter(now)) {
      return null;
    }

    final RemoteAction action;
    switch (command['Name']) {
      case 'PlayState':
        switch (arguments['Command']) {
          case 'Unpause':
            if (!_hasOnlyArguments(arguments, const {'Command'})) return null;
            action = const RemoteAction.play();
          case 'Pause':
            if (!_hasOnlyArguments(arguments, const {'Command'})) return null;
            action = const RemoteAction.pause();
          case 'Seek':
            if (!_hasOnlyArguments(arguments, const {
              'Command',
              'SeekPositionTicks',
            })) {
              return null;
            }
            final ticks = _nonnegativeInteger(arguments['SeekPositionTicks']);
            if (ticks == null) return null;
            action = RemoteAction.seek(Duration(microseconds: ticks ~/ 10));
          default:
            return null;
        }
      case 'SetSubtitleStreamIndex':
        if (!_hasOnlyArguments(arguments, const {'Index'})) return null;
        final rawIndex = arguments['Index'];
        final index = rawIndex == '-1' ? -1 : _nonnegativeInteger(rawIndex);
        if (index == null) return null;
        action = RemoteAction.subtitle(index);
      default:
        return null;
    }

    return RemoteControlCommand(
      action: action,
      binding: binding,
      sessionId: sessionId,
      controllerId: controllerId!,
      requestId: requestId!,
      sequence: sequence,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      controllingUserId: userId,
    );
  }

  static jellyfin.GeneralCommand encode({
    required String userId,
    required String sessionId,
    required RemotePlaybackBinding binding,
    required RemoteAction action,
    required String controllerId,
    required String requestId,
    required int sequence,
    required DateTime now,
    Duration ttl = const Duration(seconds: 10),
  }) {
    if (!_validId(userId) ||
        !_validId(sessionId) ||
        !_validBinding(binding) ||
        !_validId(controllerId, maxLength: 128) ||
        !_validId(requestId, maxLength: 128) ||
        sequence < 1 ||
        sequence > _maximumInteger ||
        ttl <= Duration.zero ||
        ttl > _maximumTtl) {
      throw ArgumentError('Invalid remote control command metadata.');
    }
    final issuedAt = now.toUtc();
    final arguments = <String, String>{
      'JmsRemoteVersion': '1',
      'JmsTargetSessionId': sessionId,
      'JmsItemId': binding.itemId,
      'JmsMediaSourceId': binding.mediaSourceId,
      'JmsPlaybackId': binding.playbackId,
      'JmsControllerId': controllerId,
      'JmsRequestId': requestId,
      'JmsSequence': sequence.toString(),
      'JmsIssuedAt': issuedAt.toIso8601String(),
      'JmsExpiresAt': issuedAt.add(ttl).toIso8601String(),
    };
    final jellyfin.GeneralCommandType name;
    switch (action.type) {
      case RemoteActionType.play:
        name = jellyfin.GeneralCommandType.playstate;
        arguments['Command'] = 'Unpause';
      case RemoteActionType.pause:
        name = jellyfin.GeneralCommandType.playstate;
        arguments['Command'] = 'Pause';
      case RemoteActionType.seek:
        final position = action.position;
        if (position == null ||
            position.isNegative ||
            position.inMicroseconds > _maximumInteger ~/ 10) {
          throw ArgumentError('Invalid remote seek position.');
        }
        name = jellyfin.GeneralCommandType.playstate;
        arguments['Command'] = 'Seek';
        arguments['SeekPositionTicks'] =
            (position.inMicroseconds * 10).toString();
      case RemoteActionType.subtitle:
        final index = action.subtitleIndex;
        if (index == null || index < -1 || index > _maximumInteger) {
          throw ArgumentError('Invalid remote subtitle index.');
        }
        name = jellyfin.GeneralCommandType.setsubtitlestreamindex;
        arguments['Index'] = index.toString();
    }
    return jellyfin.GeneralCommand(
      name: name,
      controllingUserId: userId,
      arguments: arguments,
    );
  }

  static bool _validId(String? value, {int maxLength = 1024}) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= maxLength &&
      value.trim() == value;

  static bool _validBinding(RemotePlaybackBinding binding) =>
      binding.isComplete &&
      _validId(binding.itemId) &&
      _validId(binding.mediaSourceId) &&
      _validId(binding.playbackId);

  static bool _hasOnlyArguments(
    Map<String, String> arguments,
    Set<String> actionKeys,
  ) =>
      arguments.length == _metadataKeys.length + actionKeys.length &&
      arguments.keys.every(
        (key) => _metadataKeys.contains(key) || actionKeys.contains(key),
      );

  static int? _nonnegativeInteger(String? value) {
    if (value == null || !_unsignedInteger.hasMatch(value)) return null;
    final parsed = int.tryParse(value);
    return parsed != null &&
            parsed >= 0 &&
            parsed <= _maximumInteger &&
            parsed.toString() == value
        ? parsed
        : null;
  }

  static DateTime? _parseUtc(String? value) {
    if (value == null) return null;
    final match = _utcTimestamp.firstMatch(value);
    if (match == null) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !parsed.isUtc) return null;
    // DateTime.parse normalizes out-of-range dates, which are invalid on the wire.
    final components = [
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
    ];
    for (var index = 0; index < components.length; index++) {
      if (components[index] != int.parse(match.group(index + 1)!)) return null;
    }
    return parsed;
  }
}

/// Keeps recent requests and controller sequence numbers within fixed bounds.
class RemoteCommandGuard {
  RemoteCommandGuard({int capacity = 64}) : _capacity = capacity {
    RangeError.checkValueInInterval(capacity, 1, 64, 'capacity');
  }

  final int _capacity;
  final _requests = <(String, String), bool>{};
  final _sequences = <String, int>{};

  bool accept(RemoteControlCommand command) {
    if (command.sequence < 1 ||
        command.sequence > RemoteControlProtocol._maximumInteger) {
      return false;
    }
    final requestKey = (command.controllerId, command.requestId);
    if (_requests.remove(requestKey) != null) {
      _requests[requestKey] = true;
      return false;
    }
    final previous = _sequences.remove(command.controllerId);
    if (previous != null) {
      _sequences[command.controllerId] = previous;
      if (command.sequence <= previous) return false;
    }
    _requests[requestKey] = true;
    _sequences[command.controllerId] = command.sequence;
    if (_requests.length > _capacity) _requests.remove(_requests.keys.first);
    if (_sequences.length > _capacity) _sequences.remove(_sequences.keys.first);
    return true;
  }

  void clear() {
    _requests.clear();
    _sequences.clear();
  }
}
