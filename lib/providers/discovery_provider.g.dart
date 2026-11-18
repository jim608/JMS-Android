// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'discovery_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ServerDiscovery)
final serverDiscoveryProvider = ServerDiscoveryProvider._();

final class ServerDiscoveryProvider
    extends $StreamNotifierProvider<ServerDiscovery, List<DiscoveryInfo>> {
  ServerDiscoveryProvider._()
    : super(
        from: null,
        argument: null,
        retry: _retryDiscovery,
        name: r'serverDiscoveryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverDiscoveryHash();

  @$internal
  @override
  ServerDiscovery create() => ServerDiscovery();
}

String _$serverDiscoveryHash() => r'7144228a85bb2cba3ea26cb1e7743a68f3d89b29';

abstract class _$ServerDiscovery extends $StreamNotifier<List<DiscoveryInfo>> {
  Stream<List<DiscoveryInfo>> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<List<DiscoveryInfo>>, List<DiscoveryInfo>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<List<DiscoveryInfo>>, List<DiscoveryInfo>>,
              AsyncValue<List<DiscoveryInfo>>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
