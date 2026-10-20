# JMS 0.11.1-jms.43

## 繁體中文 / Traditional Chinese

### 新增
- 播放中的字幕時間調整可直接輸入秒數，支援兩位小數，例如 `0.01` 或 `-0.05` 秒。
- 新增字幕偏移滑軌，放開後套用；主字幕與支援的第二字幕可分別調整，範圍為 −60 至 +60 秒。

### 調整
- 字幕偏移與微調按鈕統一以秒顯示，每次提前或延後 0.01 秒，並保留一鍵歸零。

### 修正
- 輸入字幕偏移或用鍵盤操作滑軌時，避免誤觸播放、快轉、音量與截圖快捷鍵。
- 偏移套用失敗時恢復已確認的顯示值；換片或字幕軌不可用時清除未套用的輸入與滑軌預覽。
- 手機顯示鍵盤時，字幕偏移面板會避開鍵盤並可捲動操作。

### 已知問題
- 字幕時間調整需要 MPV；Android TV 與手動選用的原生播放器尚未支援。Android 與 Web 僅支援主要字幕調整。
- ASS／SSA 特效與圖片字幕使用原生單字幕模式；Web 僅支援可載入的文字字幕，不能調整燒錄在影片中的字幕。
- Windows App 與安裝程式尚未提供正式發行者簽章。

### 更新注意事項
- Android、Windows x64 與 EndeavourOS／Arch x86_64 提供測試版更新，請保留既有帳號與設定並使用覆蓋更新。
- Web 由伺服器更新後，使用一般重新整理載入新版。

## English

### Added
- Enter subtitle offsets directly in seconds during playback, with two decimal places such as `0.01` or `-0.05` seconds.
- Adjust subtitle timing with a slider and apply it when released. Primary and supported secondary subtitles can be adjusted separately, from −60 to +60 seconds.

### Changed
- Subtitle offsets and adjustment buttons now use seconds. Move subtitles earlier or later in 0.01-second steps, or reset the offset to zero.

### Fixed
- Typing an offset or using the slider with a keyboard no longer triggers playback, seeking, volume or screenshot shortcuts.
- Failed offset changes restore the last confirmed display value. Switching media or making a subtitle track unavailable clears unapplied input and slider previews.
- On mobile, the subtitle timing panel stays above the keyboard and supports scrolling.

### Known issues
- Subtitle timing controls require MPV. Android TV and the manually selected Native player are not yet supported. Android and Web support primary subtitle timing only.
- ASS/SSA subtitles with effects and bitmap subtitles use native single-subtitle mode. The Web app supports text subtitles that it can load; subtitles burned into the video cannot be adjusted.
- The Windows app and installer do not yet have a publisher code signature.

### Update notes
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Upgrade over the existing installation to retain accounts and settings.
- After the server updates the Web app, use a normal refresh to load the new version.
