# JMS 0.11.1-jms.47

## 繁體中文 / Traditional Chinese

### 新增
- 首頁與側邊導覽新增「一起看」入口，不必先開啟任意影片才能輸入房間碼。
- 新增手把方向導航、可見焦點與掌機布局，保留鍵盤、滑鼠及觸控操作。

### 調整
- Windows 滾輪以連續短動畫累積捲動，反向操作會立即更新方向。
- 一起看依實際媒體緩衝調整預載與恢復，慢速端追趕時會保留清楚的同步狀態。
- Windows 使用安裝程式、Android 使用既有正式套件簽章、Arch 系 Linux 使用原生套件，Steam Deck 使用使用者層級 Flatpak 安裝入口。

### 修正
- 修正 Windows 軟體渲染路徑中 HDR10 影片在 SDR 螢幕上的轉換，SDR 與不適用的影片不重複轉換。

### 已知問題
- 部分帳號與伺服器組合仍可能找不到一起看房間；網路、轉碼與裝置效能會影響跨裝置同步，並非所有情境均已驗收。
- Windows 安裝程式仍未提供發行者程式碼簽章；其他 HDR 格式、實體 Steam Deck 與全部硬體組合尚未完整驗證。

### 更新注意事項
- 舊版若開啟接收測試版而遇到更新資料錯誤，可先關閉該選項，或從對應平台發行頁下載一次正式安裝程式。
- Android 正式套件與先前的 .dev 測試版不同；請使用對應平台的安裝檔更新，保留既有帳號與設定。
- Steam Deck 請在桌面模式透過 Flatpak 支援的軟體中心開啟安裝檔；不需要解除 SteamOS 唯讀保護，獨立安裝包不代表已配置自動更新來源。

## English

### Added
- Open Watch Together from the home screen or side navigation without first playing an arbitrary video.
- Added directional controller navigation, visible focus and handheld layouts while retaining keyboard, mouse and touch input.

### Changed
- Windows mouse-wheel input accumulates into short continuous scrolling animations and responds immediately to direction changes.
- Watch Together adjusts prebuffering and recovery using actual media buffers, with clear synchronization state while a slow participant catches up.
- Windows uses an installer, Android retains the established production package signature, Arch-based Linux uses a native package, and Steam Deck uses a user-scoped Flatpak installation entry.

### Fixed
- Corrected HDR10-to-SDR conversion in the Windows software renderer without applying another conversion to SDR or inapplicable media.

### Known issues
- Some account and server combinations may still be unable to find a Watch Together room; network conditions, transcoding and device performance affect cross-device synchronization, and not every scenario has been accepted.
- The Windows installer still has no publisher code signature; other HDR formats, physical Steam Deck hardware and all hardware combinations have not been fully verified.

### Update notes
- Older clients with test releases enabled may encounter incomplete update data; turn that option off temporarily or download the production installer once from the relevant platform release page.
- The production Android package differs from the previous .dev test app; update with the installer for the relevant platform to retain existing accounts and settings.
- On Steam Deck, open the Flatpak installer in a supporting software center in Desktop Mode; disabling SteamOS read-only protection is unnecessary, and a standalone bundle does not imply a configured automatic-update repository.
