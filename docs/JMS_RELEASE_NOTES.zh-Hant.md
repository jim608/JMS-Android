# JMS 0.12.1-jms.63

## 繁體中文 / Traditional Chinese

### 調整

- 整合 Fladder 0.12.1 的翻譯與 MPV 循環播放更新。

### 修正

- 斷網時直接從已下載的本機檔案播放。Jellyfin 連線失敗並取得本機副本後，播放器不會再要求伺服器開始串流。
- 離線影集與單季播放會選擇已下載的集數，排除尚未完成或待刪除的檔案。切換到不可用的影片後，播放器會結束緩衝狀態。
- Android 原生播放器可開啟檔名含 `#`、`%` 等字元的本機影片和外掛字幕。

### 已知問題

- Windows 若無法透過程式內更新檢查取得新版，請從發布頁下載安裝檔。
- 本版為預發行。Android 飛航模式實機播放及覆蓋升級仍待驗收。

## English

### Changed

- Integrated Fladder 0.12.1 translations and MPV looping updates.

### Fixed

- Play downloaded files directly when offline. If a Jellyfin request fails and finds a local copy, the player opens it without asking the server to start a stream.
- Offline TV playback chooses downloaded episodes and skips pending or deleted files. Switching to an unavailable video clears the buffering state.
- Android's native player opens downloaded videos and external subtitles whose filenames include characters such as `#` and `%`.

### Known issues

- Windows users can download the installer from the release page if the in-app update check fails.
- This is a prerelease. Playback in airplane mode and upgrades on physical Android devices still need device testing.
