/// Facts supplied by a future Flatpak origin/portal adapter, never inferred from
/// the presence of FLATPAK_ID or from the runtime's Flathub repository.
enum FlatpakAppRemoteState { unverified, missing, configured }

enum FlatpakUpdatePortalState { notIntegrated, available }

enum FlatpakUpdateCapabilityCode {
  remoteUnverified,
  remoteMissing,
  portalNotIntegrated,
  portalCheckAvailable,
}

class FlatpakUpdateCapability {
  const FlatpakUpdateCapability({
    this.appRemote = FlatpakAppRemoteState.unverified,
    this.portal = FlatpakUpdatePortalState.notIntegrated,
  });

  final FlatpakAppRemoteState appRemote;
  final FlatpakUpdatePortalState portal;

  /// Capability to ask the portal, not evidence of an update or permission to
  /// install one. The current bridge has no origin probe or portal adapter.
  bool get canRequestPortalCheck =>
      appRemote == FlatpakAppRemoteState.configured &&
      portal == FlatpakUpdatePortalState.available;

  /// A Flatpak must never fall through to the native pacman installer.
  bool get canUseStandaloneInstaller => false;

  FlatpakUpdateCapabilityCode get code => switch (appRemote) {
        FlatpakAppRemoteState.unverified =>
          FlatpakUpdateCapabilityCode.remoteUnverified,
        FlatpakAppRemoteState.missing =>
          FlatpakUpdateCapabilityCode.remoteMissing,
        FlatpakAppRemoteState.configured => canRequestPortalCheck
            ? FlatpakUpdateCapabilityCode.portalCheckAvailable
            : FlatpakUpdateCapabilityCode.portalNotIntegrated,
      };

  static final manualDownloads =
      Uri.parse('https://github.com/jim608/JMS-Linux/releases');
}
