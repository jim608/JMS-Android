# JMS 0.11.1-jms.57

## 繁體中文 / Traditional Chinese

### 修正

- 修正網頁字幕選軌失敗時被誤標為關閉的狀態，啟播時確認字幕套用結果，失敗後可重新選擇。
- 影片與字幕使用相同的媒體來源識別碼及串流索引，避免多來源回應順序不同時選錯字幕。
- 網頁字幕替換先確認新字幕載入成功，再移除原字幕；失敗時保留既有字幕，並防止重複點選、關閉選單或過期播放工作階段回寫。

### 已知問題

- 尚未完成 Tesla 車機與真實雙端 SyncPlay 驗收；最初繁簡字幕不一致的車機根因仍未經實機確認。
- 網頁文字字幕支援 SRT 與 VTT；ASS、SSA、點陣字幕及燒錄字幕與 HLS 限制仍在，原生平台的 ASS 與 SSA 路徑未變。

### 更新注意事項

- 本版更新範圍為網頁版，不包含 Android、Windows 或 Linux 安裝包更新。
- SyncPlay 保留房間同步與重新載入保護，不會在字幕選軌失敗時自行變更群組串流。

## English

### Fixed

- Keep a failed Web subtitle selection distinct from Off, confirm the applied selection at playback startup, and allow another selection after a failure.
- Bind video and subtitles to the same media source identifier and stream index to avoid selecting the wrong subtitle when multiple sources arrive in a different order.
- Confirm a replacement Web subtitle has loaded before removing the previous track, preserve the current subtitle on failure, and guard repeated input, dismissed menus, and stale playback sessions.

### Known issues

- Tesla vehicle and real two-device SyncPlay acceptance remain incomplete; the original Traditional and Simplified Chinese mismatch has not been confirmed on the vehicle.
- Web text subtitles support SRT and VTT; ASS, SSA, bitmap, burned-in subtitle and HLS limitations remain, while native ASS and SSA paths are unchanged.

### Update notes

- This version updates the Web application and does not include Android, Windows, or Linux installation packages.
- SyncPlay retains room synchronization and reload guards without independently changing the group stream after a subtitle selection failure.
