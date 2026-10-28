# Local Linux renderer capability query

This package is vendored from DonutWare/media-kit commit
`cb56b5a6149f1e51086eba473c7e48041c54ab12`, subdirectory
`media_kit_video` (version 2.0.0). `JMS_VENDOR.json` records all original file
hashes. The MIT license is preserved in `LICENSE`. Example code, its local
dependency override, and build caches are excluded. Android, Apple, Windows and
web native implementation files retain their upstream bytes. The Dart Cupertino
controls file also removes its private, unused
`_theme` helper so strict static analysis passes. This removes no reachable
behavior. Its original upstream hash remains in `baseline_files`;
`local_file_hashes` records the current patched file hash.

The local Linux patch adds a read-only method on the existing channel:

```
VideoOutputManager.GetRenderCapabilities { "handle": "<native player handle>" }
```

Version 1 replies contain `handle`, `apiType`, `pixelFormat` and
`outputTransfer`. `apiType` is recorded only after successful
`mpv_render_context_create` with `MPV_RENDER_API_TYPE_OPENGL` or
`MPV_RENDER_API_TYPE_SW`; it is never inferred from `current-vo`, the user's
decoder preference, a screen's properties, or the presence of a GL pointer.
Creation, lookup, resizing and disposal use the existing platform-thread
manager. A missing, failed or disposed context is `unknown`. Resize does not
recreate the render API in this pinned implementation.

Only successful SW reports `sw` / `rgb0` / `sdr`: its callback renders into
the plugin's existing 8-bit RGB pixel buffer, with no HDR presentation metadata
contract to Flutter/GTK. This does not claim that input HDR is already tone
mapped. The application still requires independently confirmed plain HDR10,
decoded PQ/BT.2020, reliable physical peak metadata, and safe user filters
before applying its labelled conversion.

GL reports `opengl` with unknown pixel format/output transfer. Its color
pipeline remains managed by libmpv; JMS does not apply this software conversion
or claim that the display is HDR-capable. Unavailable/old plugin methods,
incompatible replies and timeouts fail closed in the application.

Rebase this small Linux patch when updating the locked upstream commit, and
verify the actual render API and texture contract again. Linux native
compilation and physical Steam Deck/HDR display acceptance are separate from
the Dart fake-channel and synthetic metadata tests.
