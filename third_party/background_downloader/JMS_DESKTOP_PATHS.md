# Explicit desktop directory namespaces

The optional `DesktopDirectoryPaths` configuration carries already resolved
absolute paths from the owning isolate into desktop task worker isolates.
Call `FileDownloader.setDesktopDirectoryPaths(paths)` before constructing any
`FileDownloader`. Setting it after the singleton exists is rejected.

The worker installs the supplied path provider immediately after its binary
messenger is initialized, before callbacks, task filename resolution, or local
storage. This covers download and upload paths, suggested filename checks,
parallel chunk assembly and cleanup, and callback-created local stores. A null
configuration retains the upstream platform path behavior.

The application must install the corresponding main-isolate path provider
before creating its own stores. This API does not inspect or migrate another
profile. Its path payload contains directory strings only.

While a namespace is configured, resolved task paths and persisted resume
filenames are checked before file operations. Relative paths and references to
another profile are rejected; they never fall back to platform directories.

`test/windows_downloader_namespace_test.dart` in the JMS application exercises
the adapter in real worker isolates using newly created synthetic fixture
directories and fake task/local-store values. It performs no HTTP requests.
