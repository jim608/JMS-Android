# Same-account remote control (.58)

This version adds controls for an already-playing JMS video on another
device. It is separate from SyncPlay and does not launch library items remotely.
Both devices need a JMS build supporting this protocol and the same Jellyfin account/server.
Older JMS builds do not implement its bound command protocol.

The original .58 release updated Web only. Native Android, Windows and Linux
catch-up preparation on 2026-11-03 keeps version 0.11.1-jms.58+67. Those native
candidates have not been published by this preparation, and Web is not redeployed.
Check each platform's release record for package availability and validation.

1. On the playback device, open a video in the JMS app or browser, open
   **Remote control**, and enable **Allow this account to control this device**.
   Keep the receiving app or tab open and active in the foreground.
2. On the phone or another JMS client, open **Remote control** and choose the playback device.
3. Use Play, Pause, Playback position, or Subtitles. The displayed result becomes
   confirmed only after a fresh server report matches the requested change.
4. Disable receiving on the playback device to stop accepting commands. The
   opt-in is not persisted across application restarts. Closing the panel alone
   leaves an explicitly enabled receiver running.

Device discovery is scoped to the current account, excludes this device, and
rejects stale or ambiguous sessions. Each command binds the selected session,
item, media source and playback occurrence, with an expiry and replay guard.
Changing account, video or source invalidates pending control. A transport
timeout means the result is unknown; it does not automatically resend a mutation.
SyncPlay temporarily blocks remote input and removes the receiver's advertised
control capability so room seek/leadership rules cannot be bypassed.

Subtitle choices retain the selected media source's actual track indexes and
server labels. Off is an explicit selection; a failed or unconfirmed selection
is never reported as Off. Playback uses the normal primary-subtitle path:
native playback retains its existing supported subtitle formats, including its
ASS/SSA path, while existing Web format and burn-in limitations still apply.
Remote control adds no subtitle format support. Secondary subtitles are not
exposed as remote controls.

The server must forward Jellyfin GeneralCommand and echo PlaylistItemId and
playback progress. Devices lacking the required capabilities or binding
metadata remain unavailable for control. This feature does not add a native
background service or wake a suspended app or browser. It cannot bypass browser
autoplay restrictions or keep a vehicle browser running.

Receiving on Android requires the integrated MPV player. The legacy Native
activity does not expose a reliable subtitle-control bridge, so it is not
advertised as a remote receiver. The Android controller can still control a
supported playback device such as JMS Web. Windows and Linux use their normal
integrated MPV path.

Native package plans retain their separate release boundaries: Android is a
test-key prerelease, not an upgrade signed with the existing production key;
Windows Setup is unsigned; Linux is planned as a signed TEST candidate, with signing and
publication subject to the exact candidate's records. The formal Flatpak origin
and automatic-update feed remain unchanged. Linux retains one visible JMS
launcher, Auto/Desktop/Handheld selection and the hidden legacy handheld launcher.

Physical native-device remote control, Steam Deck Gaming Mode, controller,
GPU/audio and real-media acceptance remain incomplete. Flatpak Portal and
previous-version upgrades need separate acceptance; a launcher or isolated
sandbox check does not establish those results.

Local validation uses synthetic accounts/media and two isolated Chromium
contexts, plus player/provider tests. See REMOTE_CONTROL_BROWSER_TEST.md for
the exact probe boundary. It does not constitute Tesla, physical-phone, or
production Jellyfin acceptance. See the release verification record for deployment status.
