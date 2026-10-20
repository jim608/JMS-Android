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
