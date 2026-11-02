# Local remote-control browser acceptance

`test/remote_control_web_probe.dart` mounts the production remote provider,
dialog, transport, protocol and receiver. It replaces persisted accounts with
fixed synthetic identities and replaces only `RemotePlaybackPort` with a thin
adapter around a real HTML video and browser TextTrack. It does not validate
the normal app's login/navigation, MediaControlsWrapper, `.57` subtitle
selection adapter, a Tesla browser, or a physical phone. Those require separate
normal-app regression/device evidence.

The probe explicitly uses the already bundled OpenSans font so text renders
without any external font download. The network policy is unchanged.

The probe's `jms-remote-probe-account` event changes only its synthetic User
provider. The harness uses it while the real dialog is open and a real command
preflight is delayed, so account invalidation is exercised without first
closing the controller. The hook cannot dispatch remote commands or access a
real account.

An inert `application/json` DOM element mirrors the probe's read-only status,
so assertions remain available when the real modal correctly hides underlying
Flutter semantics. All UI actions still target the production semantics tree;
video properties and active cues are read directly from the browser elements.

`scripts/remote_control_fixture.mjs` is an owned loopback Jellyfin subset. Its
session ledger associates each progress report with the authenticated device;
the server overwrites `ControllingUserId` before delivering GeneralCommand to
that session's WebSocket. It never treats SyncPlay as remote control. Same-user
receiver and phone identities have separate tokens and device IDs. Foreign,
stale, disabled and own-session entries exercise client-side filtering.

`scripts/test_remote_control_web.mjs` creates two real Chromium browser contexts,
checks independent localStorage, then drives Flutter semantics with actual CDP
mouse input. Acceptance compares controller state, receiver HTML video and
TextTrack active cues, and the fixture's commands/progress ledger. A successful
HTTP 204 remains accepted until a fresh matching session report confirms it.

The scenarios cover opt-in, discovery/selection, play/pause/seek, subtitle
A/Off/B, equal subtitle indexes on different media sources, rapid seeks, slow
command delivery and progress, duplicate/expired/foreign commands, account
switch, disconnect and stale session removal. All assets, fonts, renderer,
media, API and WebSocket traffic must use the owned `127.0.0.1` origin. An owned
local proxy rejects every other destination. Chromium's WebSocket CONNECT is
allowed only to this run's exact captured numeric loopback host and port, with
a bounded lifetime; every other CONNECT is rejected. The proxy performs no
external DNS lookup or forwarding. Denied browser background noise
is recorded, while uncaught application exceptions fail acceptance.

## Pure checks (no browser or listener)

```powershell
& $existingNode --check scripts/remote_control_fixture.mjs
& $existingNode --check scripts/test_remote_control_web.mjs
& $existingNode scripts/test_remote_control_web.mjs --check
```

Importing either JavaScript module does not start a service. The fixture's unit
checks validate bounded WebSocket framing and exact string-valued envelopes.

## Freeze and run

Build only after the source owner freezes the normal app and probe; use the
pinned Flutter 3.35.7 SDK/lockfile, offline dependencies, and
`--no-web-resources-cdn` so renderer resources stay local. The probe target is
`test/remote_control_web_probe.dart`. The harness does not build or download.
Before freezing either bundle, run the repository's existing finalizer:

```powershell
& $existingDart scripts/prepare_jms_web_bootstrap.dart $generatedWebDirectory
```

This validates and binds bootstrap/Service Worker entries to the real main JS
hash. The harness rejects unfinalized or mismatched bootstrap files before
starting any listener or browser; do not remove the production startup guard.
Supply an original, locally generated H264/AAC MP4; the default metadata is 30
seconds (`--duration-seconds` supports 12–120 seconds). For example, an existing
FFmpeg can create a synthetic test pattern and tone:

```powershell
& $ffmpegPath -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24' -f lavfi -i 'sine=frequency=330:sample_rate=48000' -t 30 -c:v libx264 -pix_fmt yuv420p -preset veryfast -c:a aac -b:a 64k -movflags +faststart -n $newOriginalClip
```

After the root coordinator explicitly authorizes the frozen bundle run:

```powershell
& $existingNode scripts/test_remote_control_web.mjs --go --chrome $existingChromium --bundle $frozenProbeBundle --media $newOriginalClip --expected-main-sha256 $frozenMainSha256 --out $newRemoteControlEvidenceRun
```

`--out` must be a new child of the workspace's
`release-checks/remote-control57`; an existing evidence directory is rejected.
`--chrome` is required and must identify an existing absolute executable path;
there is no user-specific path, environment lookup, browser download or default.
The cached Chromium executable is selected explicitly, with a fresh owned Temp
profile and two disposable browser contexts. No existing browser/user profile,
production config, login, device, SSH or remote canary transport is used.
The runner records input SHA-256 values and per-scenario evidence in
`result.json`, and saves screenshots/semantics on failure. Finally it closes its
own browser, proxy and fixture; profile removal is restricted to its validated
owned Temp path after browser exit. Old `.57` release evidence is untouched.
