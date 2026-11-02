# JMS 0.11.1-jms.58

## 繁體中文 / Traditional Chinese

### 新增

- 新增同帳號 JMS 裝置遙控，可在手機選擇播放裝置，操作播放、暫停、進度及主字幕。
- 播放端預設不接收遙控，需明確啟用；關閉遙控面板後仍保留本次啟用狀態，重新啟動應用程式後恢復關閉。

### 調整

- 遙控命令綁定裝置、影片、媒體來源與播放階段，拒絕過期、重複、其他帳號或失效裝置的操作。
- 分開顯示已送出與播放端確認狀態，逾時保留結果未知，不自動重送可能已執行的操作。

### 修正

- 避免換帳號、換片、停止播放或關閉接收後，舊的非同步操作與進度回報覆蓋新狀態。

### 已知問題

- 真實 Jellyfin、實體手機與 Tesla 車機的遙控驗收尚未完成，雙瀏覽器驗證不代表實車驗收。
- 兩端都需要支援此遙控協定的 JMS，目前只控制已開始播放的影片及主字幕，播放端須保持開啟。
- 既有 Web ASS、SSA、點陣、燒錄及 HLS 字幕限制仍適用，遙控不會新增格式支援或喚醒休眠瀏覽器。

### 更新注意事項

- 本次僅更新 Web，不包含 Android、Windows 或 Linux 安裝套件發布。
- SyncPlay 期間暫停接收遙控，房間同步與遙控維持獨立；帳號設定及既有字幕修正予以保留。

## English

### Added

- Add same-account JMS device control from a phone, including device selection, play, pause, seeking and primary subtitles.
- Receiving is off by default and requires explicit opt-in; closing the panel preserves the current opt-in, while restarting the application turns it off.

### Changed

- Bind remote commands to the device, item, media source and playback occurrence, rejecting expired, duplicate, foreign-account and stale-device input.
- Distinguish sent commands from receiver confirmation, keeping timed-out results unknown without automatically replaying a possibly completed action.

### Fixed

- Prevent old asynchronous operations and progress reports from overwriting new state after account changes, replacement playback, stopping or disabling receiving.

### Known issues

- Remote control acceptance on real Jellyfin, a physical phone and a Tesla browser remains incomplete; two-browser verification is not vehicle acceptance.
- Both clients need a JMS build supporting this remote protocol; only already-playing video and primary subtitles are controlled, and the receiver must remain open.
- Existing Web ASS, SSA, bitmap, burned-in and HLS subtitle limitations still apply; remote control does not add format support or wake a suspended browser.

### Update notes

- This release updates Web only and does not publish Android, Windows or Linux installation packages.
- Receiving pauses during SyncPlay so room synchronization and remote control remain separate; account settings and existing subtitle fixes are preserved.
