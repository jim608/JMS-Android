# JMS 0.11.1-jms.45

## 繁體中文 / Traditional Chinese

### 新增
- 新增「一起看」：朋友各自登入同一台 Jellyfin，在播放器建立房間或輸入 6 位房間碼加入，同步播放、暫停及跳轉。
- 房間顯示參與者與連線狀態，支援緩衝協調、重新連線確認及離開房間。

### 調整
- 一起看期間使用正常倍速，由 Jellyfin 的房間佇列管理影片；音軌、字幕與音量仍可各自選擇。
- 切換帳號或伺服器時結束原同步連線，避免過期指令影響新帳號的播放。

### 已知問題
- 一起看需要同一台 Jellyfin 的個別帳號、影片觀看權限及 SyncPlay 權限；不支援跨伺服器、匿名觀眾、離線影片、音樂、直播、Android TV 或手動 Native 播放器。
- 同步精度受網路延遲、轉碼與裝置效能影響；Windows App 與安裝程式尚未提供正式發行者簽章。

### 更新注意事項
- 6 位房間碼用來尋找 Jellyfin 房間，不是密碼或私人房間保護；同伺服器有權限的其他客戶端仍可能列出房間。每人各自向 Jellyfin 取得影片，不需分享登入憑證。
- 先開啟線上影片，再按播放器的「一起看」。關閉房間視窗會保留連線，選擇「離開房間」或結束播放器才離開。
- Android、Windows x64 與 EndeavourOS／Arch x86_64 提供測試版更新，請保留既有帳號與設定並使用覆蓋更新。私人 Web 更新後，使用一般重新整理載入新版。

## English

### Added
- Watch together with separate accounts on the same Jellyfin server. Create a room in the video player or enter its six-digit code to synchronize playback, pause and seeking.
- View participants and connection status, coordinate buffering, reconnect to confirm room state, and leave a room.

### Changed
- Watch Together uses normal playback speed and the Jellyfin room queue. Each participant can choose their own audio track, subtitles and volume.
- Switching accounts or servers ends the previous synchronization connection so stale commands cannot affect playback under the new account.

### Known issues
- Watch Together requires separate accounts on the same Jellyfin server, access to the video and SyncPlay permission. Cross-server rooms, anonymous viewers, offline videos, music, live TV, Android TV and the manually selected Native player are not supported.
- Synchronization depends on network latency, transcoding and device performance. The Windows app and installer do not yet have a publisher code signature.

### Update notes
- The six-digit code locates a Jellyfin room; it is not a password or private-room protection. Other authorized clients on the server may still list the room. Each participant streams directly from Jellyfin without sharing login credentials.
- Open an online video before selecting Watch Together in the player. Closing the room dialog keeps the connection; select Leave room or close the player to leave.
- Prerelease updates are available for Android, Windows x64 and EndeavourOS/Arch x86_64. Upgrade over the existing installation to retain accounts and settings. After the private Web app updates, use a normal refresh to load the new version.
