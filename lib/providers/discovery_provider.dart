import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/services/local_network_permission.dart';

part 'discovery_provider.g.dart';
part 'discovery_provider.mapper.dart';

@riverpod
class ServerDiscovery extends _$ServerDiscovery {
  ServerDiscovery({
    Future<RawDatagramSocket> Function()? bindSocket,
    Future<LocalNetworkPermissionStatus> Function()? checkPermission,
  }) : _bindSocket =
           bindSocket ??
           (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)),
       _checkPermission = checkPermission ?? checkLocalNetworkPermission;

  final Future<RawDatagramSocket> Function() _bindSocket;
  final Future<LocalNetworkPermissionStatus> Function() _checkPermission;
  final String discoveryMessage = 'Who is JellyfinServer?';
  final int discoveryPort = 7359;
  final int maxServerCount = 25;
  final Duration timeOut = const Duration(seconds: 5);
  late final JellyService api = JellyService(ref, JellyfinOpenApi.create());

  @override
  Stream<List<DiscoveryInfo>> build() async* {
    final discoveredServers = <DiscoveryInfo>[];
    final controller = StreamController<List<DiscoveryInfo>>();
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    Timer? timer;
    var closed = false;

    void finish({bool emitEmpty = false}) {
      if (closed) return;
      closed = true;
      timer?.cancel();
      if (emitEmpty && discoveredServers.isEmpty) controller.add([]);
      unawaited(subscription?.cancel());
      socket?.close();
      unawaited(controller.close());
    }

    // Disposal can happen while permission or socket binding is still pending.
    ref.onDispose(finish);
    try {
      final permission = await _checkPermission();
      if (closed) return;
      if (permission == LocalNetworkPermissionStatus.denied) {
        throw LocalNetworkPermissionDeniedException();
      }

      try {
        final boundSocket = await _bindSocket();
        if (closed) {
          boundSocket.close();
          return;
        }
        socket = boundSocket;
        boundSocket.broadcastEnabled = true;
        subscription = boundSocket.listen(
          (event) {
            if (closed || event != RawSocketEvent.read) return;
            final datagram = boundSocket.receive();
            if (datagram == null) return;
            final response = utf8.decode(datagram.data);
            final jsonResponse = jsonDecode(response) as Map<String, dynamic>;
            discoveredServers.add(DiscoveryInfo.fromMap(jsonResponse));
            controller.add(List<DiscoveryInfo>.from(discoveredServers));
            if (discoveredServers.length >= maxServerCount) {
              log('Max servers found, closing socket.');
              finish();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (closed) return;
            if (error is! SocketException) {
              controller.addError(error, stackTrace);
            }
            finish(emitEmpty: error is SocketException);
          },
          onDone: () => finish(emitEmpty: true),
        );

        boundSocket.send(
          utf8.encode(discoveryMessage),
          InternetAddress('255.255.255.255'),
          discoveryPort,
        );
        timer = Timer(timeOut, () => finish(emitEmpty: true));
      } on SocketException {
        // An unavailable local network is an empty discovery, not a startup error.
        finish(emitEmpty: true);
      }
      yield* controller.stream;
    } finally {
      finish();
    }
  }
}

@MappableClass(generateMethods: GenerateMethods.encode | GenerateMethods.decode)
class DiscoveryInfo with DiscoveryInfoMappable {
  @MappableField(key: 'Id')
  final String id;
  @MappableField(key: 'Name')
  final String name;
  @MappableField(key: 'Address')
  final String address;
  @MappableField(key: "EndpointAddress")
  final String? endPointAddress;

  const DiscoveryInfo({
    required this.id,
    required this.name,
    required this.address,
    required this.endPointAddress,
  });

  factory DiscoveryInfo.fromMap(Map<String, dynamic> map) =>
      DiscoveryInfoMapper.fromMap(map);
  factory DiscoveryInfo.fromJson(String json) =>
      DiscoveryInfoMapper.fromJson(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is DiscoveryInfo && other.id == id && other.address == address;
  }

  @override
  int get hashCode => id.hashCode ^ address.hashCode;
}
