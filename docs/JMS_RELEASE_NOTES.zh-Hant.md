# JMS 0.11.1-jms.50

## 繁體中文 / Traditional Chinese

### 修正
- 播放器設定重建時等待最新初始化完成，過期載入與路由不再覆蓋新請求。
- 連續停止會等待同一個底層停止作業，保留取消與睡眠計時器意圖。
- 無法對應影片的原生訊息保留為診斷線索，避免誤判目前播放失敗。

### 已知問題
- SteamOS、實體手把與 GPU 串流播放仍需裝置驗證。
- 跨裝置同步與不同硬體組合尚未完成全面驗證。

### 更新注意事項
- Linux 與 Steam Deck 共用簽章更新來源；安裝更新仍由系統確認。

## English

### Fixed
- Waits for the latest renderer initialization and prevents stale loads or routes from replacing newer requests.
- Shares pending native stop operations while preserving cancellation and sleep timer intent.
- Keeps unattributed native messages as diagnostic context instead of treating them as confirmed current-playback failures.

### Known issues
- SteamOS, physical controllers and GPU network playback still require device validation.
- Cross-device synchronization and all hardware combinations have not been fully verified.

### Update notes
- Linux and Steam Deck share the signed update origin, with installation still confirmed by the system.
