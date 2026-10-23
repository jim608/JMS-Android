/// Group controls shared by the player wrapper and the SyncPlay coordinator.
/// This interface deliberately has no provider or protocol dependencies.
abstract interface class SyncPlayPlayerCommands {
  bool get active;
  Future<void> pause();
  Future<void> play();
  Future<void> seek(Duration position);
  Future<void> stop();
}
