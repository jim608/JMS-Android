# JMS 0.12.1-jms.65

## 繁體中文 / Traditional Chinese

### 調整

- Linux 版改善離線下載狀態。下載失敗後可以重新下載，側欄會移除已結束的任務。

### 修正

- 暫停下載後重新開啟 JMS 會保留續傳檔案。下載準備流程與桌面背景記錄會隱去含有憑證的網址。
- 中途關閉影片會記住停播前的位置。開片途中按取消會停止這次載入，避免稍後自動播放。
- 從首頁加入一起看時，時鐘同步恢復後可以繼續開啟房間影片。房間提示會依帳號的建房權限顯示。

### 已知問題

- 本版為 Linux 預發行，實體裝置上的跨帳號同步播放仍待驗證。

## English

### Changed

- Failed offline downloads can be retried, and finished tasks leave the sidebar download count.

### Fixed

- Restarting JMS preserves partial files for paused downloads. Download setup and desktop worker logs omit authenticated URLs.
- Stopping a video preserves its position before the player resets. Cancelling while a video is opening prevents the pending load from starting playback later.
- Joining Watch Together from Home can open the room video after clock synchronization recovers. Room guidance now reflects the account's permission to create rooms.

### Known issues

- This is a Linux prerelease. Cross-account synchronized playback on physical devices still needs verification.
