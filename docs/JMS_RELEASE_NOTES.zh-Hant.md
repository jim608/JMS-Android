# JMS 0.11.1-jms.42

## 繁體中文 / Traditional Chinese

### 新增
- 播放途中可開啟字幕時間調整面板，每次提前或延後 100 毫秒，範圍為正負 60 秒，支援歸零並於換片時重設。
- 原生 MPV 支援同時顯示兩條文字字幕，第二字幕以較小字體排列在主要字幕下方；支援的播放器可分別調整兩軌時間。
- Linux 的 Discord 播放狀態支援作品公開封面分享，啟用前須分別同意狀態、作品名稱與封面分享。

### 調整
- Web 直接使用網站部署的服務設定，不再顯示伺服器網址輸入、探索伺服器或網站入口編輯介面；保留帳密與快速登入。
- 網站服務設定暫時無法讀取時顯示重試提示，保留既有帳號及設定。

### 修正
- 修正 Web 文字字幕以 SRT 格式提供時的載入，支援播放中即時調整主要字幕時間。

### 已知問題
- 字幕時間調整需要使用 MPV；Android TV 或手動選用的原生播放器尚未支援。Android 的既有 MPV 僅支援主要字幕時間調整。
- ASS／SSA 特效與圖片字幕使用原生單字幕模式；Web 僅支援可載入的文字字幕，不能調整燒錄在影片中的字幕。
- Windows App 與安裝程式尚未提供正式發行者簽章。

### 更新注意事項
- Android、Windows x64 與 EndeavourOS／Arch x86_64 提供測試版更新。請保留既有帳號與設定，勿解除安裝或清除資料。
- Web 由伺服器更新後，使用一般重新整理載入新版。
- Discord 分享預設關閉，未另外同意時不會分享作品名稱或封面。

## English

### Added
- Open the subtitle timing panel during playback to move subtitles earlier or later in 100 ms steps, within a range of ±60 seconds. Offsets can be reset to zero and reset automatically when switching media.
- Native MPV can display two text subtitle tracks at once, with the secondary subtitles shown in a smaller font below the primary subtitles. Players with the required support can adjust the timing of each track independently.
- Discord playback presence on Linux supports sharing public cover artwork. Sharing playback status, media titles and cover artwork each requires separate consent.

### Changed
- The Web app uses the service configuration supplied by the website deployment. Server URL input, server discovery and the website entry configuration editor are hidden. Username/password login and Quick Connect remain available.
- If the website's service configuration is temporarily unavailable, the app shows a retry prompt and retains existing accounts and settings.

### Fixed
- Fixed loading of SRT text subtitles in the Web app, with primary subtitle timing adjustments applied immediately during playback.

### Known issues
- Subtitle timing controls require the MPV player option. Android TV and the manually selected Native player are not yet supported. The bundled MPV backend on Android supports primary subtitle timing only.
- ASS/SSA subtitles with effects and bitmap subtitles use native single-subtitle mode. The Web app supports text subtitles that it can load; subtitles burned into the video cannot be adjusted.
- The Windows app and installer do not yet have a publisher code signature.

### Update notes
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Keep existing accounts and settings; do not uninstall the app or clear its data.
- After the server updates the Web app, use a normal refresh to load the new version.
- Discord sharing is off by default. Media titles and cover artwork are not shared without separate consent.
