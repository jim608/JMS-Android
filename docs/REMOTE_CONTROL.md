# Phone remote control (Web .58)

This version adds controls for an already-playing JMS video on another
device. It is separate from SyncPlay and does not launch library items remotely.
Both devices need a JMS build supporting this protocol and the same Jellyfin account/server.
Older JMS builds do not implement its bound command protocol.

1. On the playback browser, open a video, open **Remote control**, and enable
   **Allow this account to control this device**. Keep that JMS tab open.
2. On the phone, open **Remote control** and choose the playback device.
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
is never reported as Off. Playback uses the normal primary-subtitle path, so
existing Web format and burn-in limitations still apply. Secondary subtitles
are not exposed as remote controls.

The server must forward Jellyfin GeneralCommand and echo PlaylistItemId and
playback progress. Devices lacking the required capabilities or binding
metadata remain unavailable for control. This feature cannot wake a suspended
browser, bypass autoplay restrictions, or keep a vehicle browser running.

Local validation uses synthetic accounts/media and two isolated Chromium
contexts, plus player/provider tests. See REMOTE_CONTROL_BROWSER_TEST.md for
the exact probe boundary. It does not constitute Tesla, physical-phone, or
production Jellyfin acceptance. See the release verification record for deployment status.
