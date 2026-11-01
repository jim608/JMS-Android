/// A requested subtitle could not be applied. Explicit Off remains index -1.
enum SubtitleSelectionFailureReason { requiresServerReload, unavailable }

class SubtitleSelectionFailure implements Exception {
  const SubtitleSelectionFailure(this.reason);

  final SubtitleSelectionFailureReason reason;

  @override
  String toString() => 'SubtitleSelectionFailure: ${reason.name}';
}

int requireSubtitleSelectionIndex(int? requestedIndex, int appliedIndex) {
  if (requestedIndex != null &&
      (requestedIndex < -1 || appliedIndex != requestedIndex)) {
    throw const SubtitleSelectionFailure(
        SubtitleSelectionFailureReason.unavailable);
  }
  return appliedIndex;
}
