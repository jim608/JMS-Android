# JMS 0.11.1-jms.49

## Changes

- Simplify room controls and collapse advanced diagnostics by default.

## Fixes

- Leave releases local sync control immediately while server confirmation finishes within a bounded background operation.
- Late join and media-load replies no longer take control after cancellation.
- Coordinate player initialization, cancellation and rebuilds, and retain the position and delivery label after paused reloads.

## Known issues

- Android is offered as a prerelease; phone and cross-device room acceptance remains unverified.
- Web playback capabilities depend on the browser. Windows-specific acceptance does not establish equivalent Android or Web acceptance.

## Update notes

- The Android ARM64 package retains the production com.jim608.jms identity and existing upgrade signer; keep application data when updating.
- The .dev test application is separate; its data is not automatically migrated to the production application.

# JMS 0.11.1-jms.48-syncplay-recovery-test.20261025

## Changes

- One Leave action returns Windows TEST to solo controls; advanced diagnostics start collapsed.

## Fixes

- Room creation retains the current position and the user's paused intent.
- Accept the empty success response used by older Jellyfin room creation.
- Cancellation, leave and late room commands no longer retake solo playback control.
- Restore the displayed position and delivery label after a paused reload.

## Known issues

- This is an unsigned Windows x64 TEST installer using the existing TEST application identity.

## Update notes

- Retain the existing TEST installation directory and settings without new desktop shortcuts or automatic installation, launch or restart.

# JMS 0.11.1-jms.47

## Added
- Open Watch Together from the home screen or side navigation without first playing an arbitrary video.
- Added directional controller navigation, visible focus and handheld layouts while retaining keyboard, mouse and touch input.

## Changed
- Windows mouse-wheel input accumulates into short continuous scrolling animations and responds immediately to direction changes.
- Watch Together adjusts prebuffering and recovery using actual media buffers, with clear synchronization state while a slow participant catches up.
- Windows uses an installer, Android retains the established production package signature, Arch-based Linux uses a native package, and Steam Deck uses a user-scoped Flatpak installation entry.

## Fixed
- Failed or missing movie details now offer retry and back instead of a blank page; retry waits for the bounded connection check.
- When Linux cannot read system network status, use a bounded server reachability check instead of forcing media detail requests into offline caches.
- Corrected HDR10-to-SDR conversion in the Windows software renderer without applying another conversion to SDR or inapplicable media.

## Known issues
- Controllers on Linux and Steam Deck currently require Steam Input keyboard mappings for directions, confirm and back; native analog axes are not implemented.
- Some account and server combinations may still be unable to find a Watch Together room; network conditions, transcoding and device performance affect cross-device synchronization, and not every scenario has been accepted.
- The Windows installer still has no publisher code signature; other HDR formats, physical Steam Deck hardware and all hardware combinations have not been fully verified.

## Update notes
- Older clients with test releases enabled may encounter incomplete update data; turn that option off temporarily or download the production installer once from the relevant platform release page.
- The production Android package differs from the previous .dev test app; update with the installer for the relevant platform to retain existing accounts and settings.
- On Steam Deck, open the Flatpak installer in a supporting software center in Desktop Mode; disabling SteamOS read-only protection is unnecessary, and a standalone bundle does not imply a configured automatic-update repository.

# JMS 0.11.1-jms.45

## Added
- Watch together with separate accounts on the same Jellyfin server. Create a room in the video player or enter its six-digit code to synchronize playback, pause and seeking.
- View participants and connection status, coordinate buffering, reconnect to confirm room state, and leave a room.

## Changed
- Watch Together uses normal playback speed and the Jellyfin room queue. Each participant can choose their own audio track, subtitles and volume.
- Switching accounts or servers ends the previous synchronization connection so stale commands cannot affect playback under the new account.

## Fixed
- Improved Watch Together connection compatibility with Jellyfin servers that do not enable legacy authentication.

## Known issues
- Watch Together requires separate accounts on the same Jellyfin server, access to the video and SyncPlay permission. Cross-server rooms, anonymous viewers, offline videos, music, live TV, Android TV and the manually selected Native player are not supported.
- Synchronization depends on network latency, transcoding and device performance. The Windows app and installer do not yet have a publisher code signature.

## Update notes
- The six-digit code locates a Jellyfin room; it is not a password or private-room protection. Other authorized clients on the server may still list the room. Each participant streams directly from Jellyfin without sharing login credentials.
- Open an online video before selecting Watch Together in the player. Closing the room dialog keeps the connection; select Leave room or close the player to leave.
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Upgrade over the existing installation to retain accounts and settings. After the private Web app updates, use a normal refresh to load the new version.

# JMS 0.11.1-jms.44

## Changed
- The Traditional Chinese interface now uses bundled Noto Sans TC with consistent heading, body and button weights across platforms.
- Refined line height and letter spacing make Chinese and English content easier to scan while preserving system text scaling.

## Fixed
- Details and playback screens retain the current language's typeface when colors are derived from movie or music artwork.

## Known issues
- The Windows app and installer do not yet have a publisher code signature.

## Update notes
- Fonts are included with the app and require no separate installation or online download. These changes apply to the interface; subtitles continue to use their existing settings.
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Upgrade over the existing installation to retain accounts and settings. After the server updates the Web app, use a normal refresh to load the new version.

# JMS 0.11.1-jms.43

## Added
- Enter subtitle offsets directly in seconds during playback, with two decimal places such as `0.01` or `-0.05` seconds.
- Adjust subtitle timing with a slider and apply it when released. Primary and supported secondary subtitles can be adjusted separately, from −60 to +60 seconds.

## Changed
- Subtitle offsets and adjustment buttons now use seconds. Move subtitles earlier or later in 0.01-second steps, or reset the offset to zero.

## Fixed
- Typing an offset or using the slider with a keyboard no longer triggers playback, seeking, volume or screenshot shortcuts.
- Failed offset changes restore the last confirmed display value. Switching media or making a subtitle track unavailable clears unapplied input and slider previews.
- On mobile, the subtitle timing panel stays above the keyboard and supports scrolling.

## Known issues
- Subtitle timing controls require MPV. Android TV and the manually selected Native player are not yet supported. Android and Web support primary subtitle timing only.
- ASS/SSA subtitles with effects and bitmap subtitles use native single-subtitle mode. The Web app supports text subtitles that it can load; subtitles burned into the video cannot be adjusted.
- The Windows app and installer do not yet have a publisher code signature.

## Update notes
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Upgrade over the existing installation to retain accounts and settings.
- After the server updates the Web app, use a normal refresh to load the new version.

# JMS 0.11.1-jms.42

## Added
- Open the subtitle timing panel during playback to move subtitles earlier or later in 100 ms steps, within a range of ±60 seconds. Offsets can be reset to zero and reset automatically when switching media.
- Native MPV can display two text subtitle tracks at once, with the secondary subtitles shown in a smaller font below the primary subtitles. Players with the required support can adjust the timing of each track independently.
- Discord playback presence on Linux supports sharing public cover artwork. Sharing playback status, media titles and cover artwork each requires separate consent.

## Changed
- The Web app uses the service configuration supplied by the website deployment. Server URL input, server discovery and the website entry configuration editor are hidden. Username/password login and Quick Connect remain available.
- If the website's service configuration is temporarily unavailable, the app shows a retry prompt and retains existing accounts and settings.

## Fixed
- Fixed loading of SRT text subtitles in the Web app, with primary subtitle timing adjustments applied immediately during playback.

## Known issues
- Subtitle timing controls require the MPV player option. Android TV and the manually selected Native player are not yet supported. The bundled MPV backend on Android supports primary subtitle timing only.
- ASS/SSA subtitles with effects and bitmap subtitles use native single-subtitle mode. The Web app supports text subtitles that it can load; subtitles burned into the video cannot be adjusted.
- The Windows app and installer do not yet have a publisher code signature.

## Update notes
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Keep existing accounts and settings; do not uninstall the app or clear its data.
- After the server updates the Web app, use a normal refresh to load the new version.
- Discord sharing is off by default. Media titles and cover artwork are not shared without separate consent.
