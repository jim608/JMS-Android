import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Optional desktop directory namespace inherited by task worker isolates.
///
/// Every value is resolved by the owning isolate. Workers must not infer these
/// paths from executable metadata or the current user's known folders again.
final class DesktopDirectoryPaths {
  DesktopDirectoryPaths({
    required this.temporary,
    required this.applicationSupport,
    required this.documents,
    required this.applicationCache,
    required this.library,
    required this.downloads,
  }) {
    for (final value in toMessage().values) {
      if (!p.isAbsolute(value)) {
        throw ArgumentError('Desktop directory paths must be absolute');
      }
    }
  }

  final String temporary;
  final String applicationSupport;
  final String documents;
  final String applicationCache;
  final String library;
  final String downloads;

  Map<String, String> toMessage() => {
        'temporary': temporary,
        'applicationSupport': applicationSupport,
        'documents': documents,
        'applicationCache': applicationCache,
        'library': library,
        'downloads': downloads,
      };

  factory DesktopDirectoryPaths.fromMessage(Map<String, String> values) =>
      DesktopDirectoryPaths(
        temporary: values['temporary']!,
        applicationSupport: values['applicationSupport']!,
        documents: values['documents']!,
        applicationCache: values['applicationCache']!,
        library: values['library']!,
        downloads: values['downloads']!,
      );

  /// Rejects persisted or explicitly supplied task paths from another profile
  /// before the downloader can inspect, resume, upload, move, or delete them.
  void validateFilePath(String value) {
    final normalized = p.normalize(value);
    if (!p.isAbsolute(normalized) ||
        !toMessage().values.any((directory) =>
            p.equals(directory, normalized) || p.isWithin(directory, normalized))) {
      throw ArgumentError('Task path leaves the configured desktop directories');
    }
  }

  /// Installs only this isolate's supplied namespace; there is no OS fallback.
  void installForCurrentIsolate() {
    desktopDirectoryPaths = this;
    PathProviderPlatform.instance = _DesktopDirectoryPathProvider(this);
  }
}

// Shared by the facade and desktop implementation without constructing the
// downloader (which would initialize its persistent store too early).
DesktopDirectoryPaths? desktopDirectoryPaths;

class _DesktopDirectoryPathProvider extends PathProviderPlatform {
  _DesktopDirectoryPathProvider(this.paths);

  final DesktopDirectoryPaths paths;

  @override
  Future<String?> getTemporaryPath() async => paths.temporary;

  @override
  Future<String?> getApplicationSupportPath() async => paths.applicationSupport;

  @override
  Future<String?> getApplicationDocumentsPath() async => paths.documents;

  @override
  Future<String?> getApplicationCachePath() async => paths.applicationCache;

  @override
  Future<String?> getLibraryPath() async => paths.library;

  @override
  Future<String?> getDownloadsPath() async => paths.downloads;
}
