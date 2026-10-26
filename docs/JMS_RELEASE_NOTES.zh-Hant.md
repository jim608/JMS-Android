# JMS 0.11.1-jms.51

## 繁體中文 / Traditional Chinese

### 修正
- Flatpak Portal 成功開啟監看後，暫無通知時仍顯示等待更新資訊，直到收到有意義的更新或目前狀態證據。
- 只有 Portal 開啟失敗才顯示錯誤並保留重試，不會把尚未回報的狀態誤判為已是最新版本。

### 已知問題
- 實體 Steam Deck、SteamOS 遊戲模式與真實硬體組合仍需驗證。

### 更新注意事項
- Linux 與 Steam Deck 沿用已簽署的 Flatpak 更新來源；安裝仍須由系統確認。

## English

### Fixed
- Keeps a successfully opened Flatpak Portal monitor waiting for meaningful update or current-state evidence when no notification has arrived.
- Shows an error and keeps retry available after an actual Portal opening failure, without treating an unreported state as up to date.

### Known issues
- Physical Steam Deck devices, SteamOS Gaming Mode and real hardware combinations still require validation.

### Update notes
- Linux and Steam Deck continue using the signed Flatpak update origin, with installation confirmed by the system.
